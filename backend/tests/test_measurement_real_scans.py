"""The measurement engine against every real device scan we have.

These fixtures are verbatim CapturedRoom JSON from the July 2026 field
sessions (geometry only — no audio, photos, or customer data). They exist
because the synthetic rectangle hid the field reality: 13 of these 14 scans
do not close their wall loop, and the engine once fabricated 44% of the
total wall area to compensate (the Decision 26 completion, removed by
Decision 34). This suite pins the honest behaviour to the data that
exposed the dishonest one.

`visit-20260710-124630` is the synthetic 5x3 fixture uploaded through the
curl example — the only closed room in the set, kept as the complete-scan
baseline. Every other scan is a genuine capture with an open wall loop.
"""

import json
from pathlib import Path

import pytest

from buildpilot.pipelines.measurement import (
    RoomPlanMeasurementEngine,
    _polygon_area_m2,
    _surface_area_m2,
    RoomMeasurement,  # noqa: F401  (re-exported for type context)
)

FIXTURE_DIR = Path(__file__).parent / "fixtures" / "real_scans"
SCANS = sorted(FIXTURE_DIR.glob("visit-*.json"))
SCAN_IDS = [p.stem for p in SCANS]

# The synthetic upload — the one closed room; every real capture is open.
CLOSED_BASELINE = "visit-20260710-124630-60c503"


@pytest.fixture(params=SCANS, ids=SCAN_IDS)
def scan(request):
    return request.param.stem, json.loads(request.param.read_text())


def _measure(room: dict):
    return RoomPlanMeasurementEngine().measure(room)


def test_fixture_set_is_complete():
    # A deletion guard, not a cap: the corpus GROWS as tools/pull_scan.py
    # archives new field visits (14 was the July 2026 baseline). Shrinking
    # below the baseline means real evidence went missing.
    assert len(SCANS) >= 14


def test_no_fabricated_wall_area(scan):
    """Gross wall area is exactly the sum of captured wall surfaces —
    nothing added for walls the scan did not reconstruct."""
    name, room = scan
    result = _measure(room)
    included = {w.wall_id for w in result.walls if w.duplicate_of is None}
    measured = sum(
        _surface_area_m2(w)
        for index, w in enumerate(room["walls"])
        if f"w{index + 1}" in included
    )
    assert result.gross_wall_area_m2 == pytest.approx(measured, abs=0.05)


def test_totals_reconcile_with_wall_breakdown(scan):
    """One canonical number: room totals == sum of the per-wall breakdown.
    (The old engine diverged 28-65% here on these same scans.)"""
    name, room = scan
    result = _measure(room)
    included = [w for w in result.walls if w.duplicate_of is None]
    assert result.gross_wall_area_m2 == round(sum(w.gross_area_m2 for w in included), 2)
    assert result.net_wall_area_m2 == round(sum(w.net_area_m2 for w in included), 2)


def test_net_wall_is_gross_minus_openings(scan):
    """Per wall: net = gross − openings assigned to that wall (no built-ins
    deducted in these scans' fixtures where objects exist, deductions are
    also per-wall and included in the identity)."""
    name, room = scan
    result = _measure(room)
    assigned = {o.opening_id: o for o in result.openings if o.parent_wall_id}
    for wall in result.walls:
        opening_sum = sum(assigned[i].area_m2 for i in wall.opening_ids)
        # net never exceeds gross minus its openings (built-in deductions
        # may lower it further) and openings are clamped to the wall.
        assert wall.opening_area_m2 == pytest.approx(
            min(opening_sum, wall.gross_area_m2), abs=0.01
        )
        assert wall.net_area_m2 <= wall.gross_area_m2 - wall.opening_area_m2 + 0.01


def test_floor_area_is_the_polygon_area(scan):
    """Floor comes from the scanned polygon (shoelace), never bbox width x
    length, whenever a usable polygon exists — it does in all 14 scans."""
    name, room = scan
    result = _measure(room)
    polygon = sum(_polygon_area_m2(f.get("polygonCorners") or []) for f in room["floors"])
    assert polygon >= 0.5, "fixture unexpectedly lost its floor polygon"
    assert result.floor_area_m2 == round(polygon, 2)
    assert result.ceiling_area_m2 == result.floor_area_m2
    assert result.flat_ceiling_assumed is True


def test_open_loop_scans_are_flagged_incomplete_with_located_gaps(scan):
    """Every genuine device scan has an open wall loop: flagged incomplete,
    gaps located, confidence capped — and never silently completed."""
    name, room = scan
    result = _measure(room)
    completeness = result.completeness
    assert completeness is not None
    assert completeness.human_confirmed is False

    if name == CLOSED_BASELINE:
        assert completeness.status == "complete"
        assert completeness.open_edges == []
        return

    assert completeness.status == "incomplete"
    assert "wall_loop_open" in completeness.flags
    assert completeness.open_edges, "an open loop must locate its gaps"
    for edge in completeness.open_edges:
        assert edge.wall_id in {w.wall_id for w in result.walls}
        assert edge.end in {"start", "end"}
        assert len(edge.position_m) == 2
        assert edge.description
    assert result.confidence_score <= 0.55
    assert any("no area added" in note for note in result.notes)
    assert not any("added" in note and "estimated wall area" in note for note in result.notes)


def test_parent_references_are_used_where_present(scan):
    """RoomPlan's parentIdentifier is authoritative: every opening whose
    parentIdentifier names a wall in the scan resolves through it (3 of the
    5 openings across the set carry one)."""
    name, room = scan
    result = _measure(room)
    wall_idents = {
        w.get("identifier"): f"w{i + 1}" for i, w in enumerate(room["walls"])
    }
    referenced = [
        (kind, s) for kind in ("doors", "windows", "openings")
        for s in room.get(kind) or []
        if s.get("parentIdentifier") in wall_idents
    ]
    by_kind_order = {}
    for parent_detail in result.openings:
        by_kind_order.setdefault(parent_detail.kind, []).append(parent_detail)
    for kind, surface in referenced:
        index = (room[kind] or []).index(surface)
        detail = by_kind_order[kind.rstrip("s")][index]
        assert detail.parent_source == "parent_reference"
        assert detail.parent_wall_id == wall_idents[surface["parentIdentifier"]]


def test_parent_reference_coverage_across_the_set():
    """The set genuinely exercises the parent-reference path."""
    count = 0
    for path in SCANS:
        room = json.loads(path.read_text())
        wall_idents = {w.get("identifier") for w in room["walls"]}
        for kind in ("doors", "windows", "openings"):
            for s in room.get(kind) or []:
                if s.get("parentIdentifier") in wall_idents:
                    count += 1
    assert count >= 3


def test_measurement_is_deterministic_on_real_scans(scan):
    """Same scan in, same numbers out — byte-identical output."""
    name, room = scan
    engine = RoomPlanMeasurementEngine()
    assert engine.measure(room).model_dump() == engine.measure(room).model_dump()
