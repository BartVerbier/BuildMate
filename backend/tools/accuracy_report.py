#!/usr/bin/env python3
"""The milestone-A accuracy report: laser truth vs the measurement engine.

Run any time; grows with the corpus (docs/GROUND_TRUTH_PROTOCOL.md):

    ../.venv/bin/python tools/accuracy_report.py        (from backend/)

For every laser-measured room it prints the signed error per dimension, the
engine's completeness verdict, and whether that verdict was HONEST — a verdict
is honest when COMPLETE scans sit inside tolerance and out-of-tolerance scans
flagged themselves. The silent-error column is the one that matters: a wrong
number that admits it is a rescan prompt; a wrong number that looks confident
is a bad price in front of a customer.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # backend/ on path

from buildpilot.pipelines.measurement import RoomPlanMeasurementEngine
from tests.ground_truth import (
    ceiling_is_level,
    compare,
    completeness_status,
    load_records,
    load_scan,
    worst_relative_error,
)

TOLERANCE = 0.10  # keep in lockstep with tests/test_ground_truth.py


def main() -> int:
    records = load_records()
    if not records:
        print("No laser-measured rooms yet.")
        print("Scan on site, then:  python tools/pull_scan.py pull <visit-id>")
        print("and fill in the laser numbers (docs/GROUND_TRUTH_PROTOCOL.md).")
        return 0

    engine = RoomPlanMeasurementEngine()
    print(f"{'visit':32} {'pat':3} {'verdict':10} {'worst':>7} {'honest':7}")
    print("-" * 64)
    silent = 0
    for record in records:
        measurement = engine.measure(load_scan(record))
        errors = compare(record, measurement)
        worst = worst_relative_error(errors)
        verdict = completeness_status(measurement)
        ok = worst <= TOLERANCE
        honest = ok or verdict == "incomplete"
        if not honest:
            silent += 1
        print(f"{record['visit_id']:32} {record.get('scan_pattern', '?'):3} "
              f"{verdict:10} {worst:6.1%} {'yes' if honest else 'SILENT!':7}")
        for error in errors:
            print(f"    {error}")
        if not ceiling_is_level(record["laser"]):
            heights = record["laser"]["ceiling_height_m"]
            print(f"    NOTE: ceiling not level ({heights}) — the flat-ceiling "
                  "assumption is wrong in this room")
        painter = record.get("painter_estimate") or {}
        if painter.get("paintable_area_m2"):
            print(f"    painter's paintable area: {painter['paintable_area_m2']:.1f} m2 "
                  f"vs engine {measurement.paintable_surface_area_m2:.1f} m2 "
                  "(scopes may differ — informational)")
    print("-" * 64)
    print(f"{len(records)} room(s); tolerance {TOLERANCE:.0%}; "
          f"silent errors: {silent} {'← FIX BEFORE DEPLOY' if silent else '(none — verdicts are honest)'}")
    return 1 if silent else 0


if __name__ == "__main__":
    sys.exit(main())
