"""Does Build Pilot measure the room correctly?

Two suites in one file:

1. Comparator self-tests — prove the arithmetic in `ground_truth.py` is right
   using the worked EXAMPLE record. These run today, with no field data.
2. Field assertions — run once laser-measured rooms land in
   fixtures/ground_truth/ (docs/GROUND_TRUTH_PROTOCOL.md). They skip, loudly,
   until then.

The load-bearing assertion is COMPLETE_SCAN_TOLERANCE: when the engine calls a
scan complete, it is claiming the number is trustworthy. That claim is what
gets tested here. An incomplete scan is allowed to be wrong — it is required
to SAY so, which is the separate assertion below.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from buildpilot.pipelines.measurement import RoomPlanMeasurementEngine
from tests.ground_truth import (
    Error,
    TRUTH_DIR,
    ceiling_is_level,
    compare,
    completeness_status,
    load_records,
    load_scan,
    truth_ceiling_height_m,
    truth_gross_wall_area_m2,
    truth_net_wall_area_m2,
    truth_opening_area_m2,
    truth_perimeter_m,
    worst_relative_error,
)

# A scan the engine calls COMPLETE must be within this of the laser. Start
# honest-but-loose; tighten as the corpus grows. The published tolerance
# (docs/GROUND_TRUTH_PROTOCOL.md) can only ever be as tight as this number.
COMPLETE_SCAN_TOLERANCE = 0.10

EXAMPLE = TRUTH_DIR / "EXAMPLE-room.json"


# --- 1. comparator self-tests (run today) -----------------------------------


@pytest.fixture
def example():
    return json.loads(EXAMPLE.read_text())["laser"]


def test_example_record_matches_the_documented_shape():
    """The EXAMPLE is the spec for what Bart records on site. If this breaks,
    the protocol doc and the loader have drifted apart."""
    record = json.loads(EXAMPLE.read_text())
    assert record["scan_pattern"] in {"A", "B", "C"}
    for key in ("visit_id", "laser", "conditions", "painter_estimate"):
        assert key in record, f"EXAMPLE lost its {key} block"
    for key in ("walls_m", "ceiling_height_m", "openings", "built_ins"):
        assert key in record["laser"]


def test_truth_perimeter_sums_the_laser_walls(example):
    assert truth_perimeter_m(example) == pytest.approx(4.62 + 3.15 + 4.62 + 3.15)


def test_truth_ceiling_height_averages_the_corner_readings(example):
    assert truth_ceiling_height_m(example) == pytest.approx(2.45)


def test_uneven_ceiling_is_detected():
    """Two corners disagreeing by >2 cm means the engine's flat-ceiling
    assumption is wrong in that room — the whole reason we read two corners."""
    assert ceiling_is_level({"ceiling_height_m": [2.44, 2.46]})
    assert not ceiling_is_level({"ceiling_height_m": [2.40, 2.55]})
    assert ceiling_is_level({"ceiling_height_m": [2.44]})  # one reading: silent


def test_truth_gross_wall_area(example):
    assert truth_gross_wall_area_m2(example) == pytest.approx(15.54 * 2.45, rel=1e-3)


def test_truth_net_subtracts_openings_and_built_ins(example):
    openings = 0.83 * 2.03 + 1.42 * 1.28
    built_ins = 1.80 * 2.30
    assert truth_opening_area_m2(example) == pytest.approx(openings)
    assert truth_net_wall_area_m2(example) == pytest.approx(
        truth_gross_wall_area_m2(example) - openings - built_ins
    )


def test_error_reports_signed_relative_error():
    over = Error("x", truth=100.0, measured=110.0)
    assert over.absolute == pytest.approx(10.0)
    assert over.relative == pytest.approx(0.10)
    under = Error("x", truth=100.0, measured=50.0)
    assert under.relative == pytest.approx(-0.50)
    assert Error("x", truth=0.0, measured=1.0).relative is None


def test_worst_relative_error_ignores_undefined():
    errors = [
        Error("a", 100.0, 105.0),   # +5%
        Error("b", 0.0, 3.0),       # undefined, must not crash
        Error("c", 100.0, 80.0),    # -20%
    ]
    assert worst_relative_error(errors) == pytest.approx(0.20)


# --- 2. field assertions (skip until real rooms land) ------------------------

RECORDS = load_records()
RECORD_IDS = [r["visit_id"] for r in RECORDS]


@pytest.mark.skipif(not RECORDS, reason="no laser-measured rooms yet — see docs/GROUND_TRUTH_PROTOCOL.md")
@pytest.mark.parametrize("record", RECORDS, ids=RECORD_IDS)
def test_complete_scans_are_accurate(record):
    """The promise: if the engine says complete, the number is trustworthy."""
    measurement = RoomPlanMeasurementEngine().measure(load_scan(record))
    if completeness_status(measurement) != "complete":
        pytest.skip("engine flagged this scan incomplete; accuracy not promised")
    errors = compare(record, measurement)
    worst = worst_relative_error(errors)
    assert worst <= COMPLETE_SCAN_TOLERANCE, (
        f"{record['visit_id']} was called COMPLETE but is off by {worst:.1%}:\n  "
        + "\n  ".join(str(e) for e in errors)
    )


@pytest.mark.skipif(not RECORDS, reason="no laser-measured rooms yet — see docs/GROUND_TRUTH_PROTOCOL.md")
@pytest.mark.parametrize("record", RECORDS, ids=RECORD_IDS)
def test_inaccurate_scans_admit_it(record):
    """The other half of the promise, and the more important one: a scan that
    is materially wrong must never present itself as complete. Silent error is
    the failure mode that puts a wrong price in front of a customer."""
    measurement = RoomPlanMeasurementEngine().measure(load_scan(record))
    errors = compare(record, measurement)
    worst = worst_relative_error(errors)
    if worst > COMPLETE_SCAN_TOLERANCE:
        assert completeness_status(measurement) == "incomplete", (
            f"{record['visit_id']} is off by {worst:.1%} but the engine did NOT "
            f"flag it — this is the silent-error case:\n  "
            + "\n  ".join(str(e) for e in errors)
        )
