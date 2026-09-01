"""Measurement engine tests against the synthetic CapturedRoom fixture.

Fixture geometry (hand-computable): 5m x 3m room, 2.5m walls.
  gross wall = 2x(5x2.5) + 2x(3x2.5) = 40.0 m2
  door 0.9x2.0 = 1.8 m2, window 1.2x1.0 = 1.2 m2
  net wall = 40.0 - 1.8 - 1.2 = 37.0 m2
  floor polygon = 15.0 m2, ceiling = floor
  paintable = 37.0 + 15.0 = 52.0 m2
"""

import json
from pathlib import Path

import pytest

from buildpilot.pipelines.measurement import (
    MeasurementError,
    RoomPlanMeasurementEngine,
    _confidence_weight,
    _polygon_area_m2,
    _transform_columns,
)

FIXTURE = Path(__file__).parent / "fixtures" / "synthetic_room_5x3.json"


@pytest.fixture()
def captured_room() -> dict:
    return json.loads(FIXTURE.read_text())


def test_measures_synthetic_room_exactly(captured_room):
    result = RoomPlanMeasurementEngine().measure(captured_room)

    assert result.gross_wall_area_m2 == 40.0
    assert result.door_area_m2 == 1.8
    assert result.window_area_m2 == 1.2
    assert result.net_wall_area_m2 == 37.0
    assert result.floor_area_m2 == 15.0
    assert result.ceiling_area_m2 == 15.0
    assert result.paintable_surface_area_m2 == 52.0


def test_confidence_is_area_weighted(captured_room):
    # (12.5x1.0 + 12.5x0.65 + 7.5 + 7.5 + 15.0) / 55.0 = 0.9204 -> 0.92
    result = RoomPlanMeasurementEngine().measure(captured_room)
    assert result.confidence_score == 0.92


def test_missing_floor_falls_back_to_wall_footprint(captured_room):
    captured_room["floors"] = []
    result = RoomPlanMeasurementEngine().measure(captured_room)

    # bounding box of the four wall footprints is exactly 5 x 3
    assert result.floor_area_m2 == 15.0
    assert result.confidence_score <= 0.5
    assert any("bounding box" in note for note in result.notes)


def test_scan_without_walls_raises(captured_room):
    captured_room["walls"] = []
    with pytest.raises(MeasurementError):
        RoomPlanMeasurementEngine().measure(captured_room)


def test_openings_are_subtracted_and_noted(captured_room):
    captured_room["openings"] = [
        {
            "identifier": "opening-1",
            "confidence": {"high": {}},
            "dimensions": [1.0, 2.0, 0.0],
            "transform": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 1.0, 1.5, 1]],
        }
    ]
    result = RoomPlanMeasurementEngine().measure(captured_room)
    assert result.net_wall_area_m2 == 35.0
    assert any("open doorways" in note for note in result.notes)


def test_measurement_is_deterministic(captured_room):
    engine = RoomPlanMeasurementEngine()
    assert engine.measure(captured_room).model_dump() == engine.measure(captured_room).model_dump()


# --- parsing helpers ---------------------------------------------------------


def test_confidence_accepts_both_encodings():
    assert _confidence_weight({"confidence": {"high": {}}}) == 1.0
    assert _confidence_weight({"confidence": "medium"}) == 0.65
    assert _confidence_weight({"confidence": "LOW"}) == 0.3
    assert _confidence_weight({}) == 0.5


def test_transform_accepts_nested_and_flat_encodings():
    nested = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [1, 2, 3, 1]]
    flat = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 2, 3, 1]
    assert _transform_columns({"transform": nested}) == _transform_columns({"transform": flat})
    assert _transform_columns({"transform": flat})[3][:3] == [1.0, 2.0, 3.0]


def test_fixed_objects_deduct_wall_area_movable_do_not(captured_room):
    """Painter logic: built-ins block the wall behind them; movable
    furniture is moved before painting and costs nothing."""
    captured_room["objects"] = [
        {   # built-in wardrobe against the north wall (z=-1.5): FIXED
            "category": {"storage": {}},
            "dimensions": [2.0, 2.2, 0.6],
            "transform": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0.0, 1.1, -1.15, 1]],
        },
        {   # sofa near the south wall: MOVABLE — no deduction
            "category": {"sofa": {}},
            "dimensions": [2.2, 0.9, 0.9],
            "transform": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0.0, 0.45, 1.0, 1]],
        },
    ]
    result = RoomPlanMeasurementEngine().measure(captured_room)

    # base net 37.0 − wardrobe 2.0 x 2.2 = 32.6
    assert result.net_wall_area_m2 == 32.6
    assert result.paintable_surface_area_m2 == 47.6
    assert any("built-in" in note for note in result.notes)
    assert any("movable furniture" in note for note in result.notes)


def test_low_storage_is_movable_furniture(captured_room):
    """The bench issue (Sprint 6): RoomPlan reports benches and sideboards
    as "storage". Low storage gets moved like any furniture — the wall
    behind it stays paintable. Only tall storage is treated as built in."""
    captured_room["objects"] = [
        {   # bench against the north wall — real scan reported 1.5 x 0.66 x 0.51
            "category": {"storage": {}},
            "dimensions": [1.5, 0.66, 0.51],
            "transform": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0.45, 0.33, -1.2, 1]],
        }
    ]
    result = RoomPlanMeasurementEngine().measure(captured_room)
    assert result.net_wall_area_m2 == 37.0  # no deduction
    assert result.movable_objects == 1
    assert result.fixed_objects == 0


def test_object_counts_reported(captured_room):
    captured_room["objects"] = [
        {   # tall built-in wardrobe: fixed
            "category": {"storage": {}},
            "dimensions": [2.0, 2.2, 0.6],
            "transform": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0.0, 1.1, -1.15, 1]],
        },
        {   # sofa: movable
            "category": {"sofa": {}},
            "dimensions": [2.2, 0.9, 0.9],
            "transform": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0.0, 0.45, 1.0, 1]],
        },
    ]
    result = RoomPlanMeasurementEngine().measure(captured_room)
    assert result.fixed_objects == 1
    assert result.movable_objects == 1


def test_fixed_object_away_from_walls_costs_nothing(captured_room):
    captured_room["objects"] = [
        {   # kitchen island in the middle of the room: fixed but not on a wall
            "category": {"storage": {}},
            "dimensions": [1.5, 0.9, 0.8],
            "transform": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0.0, 0.45, 0.0, 1]],
        }
    ]
    result = RoomPlanMeasurementEngine().measure(captured_room)
    assert result.net_wall_area_m2 == 37.0


def test_incomplete_scan_is_flagged_not_completed(captured_room):
    """Room-closure check (Decision 34): a scan that reconstructs only some
    walls is flagged INCOMPLETE with the gaps located — the engine reports
    exactly the measured area and never invents the rest."""
    captured_room["walls"] = captured_room["walls"][:2]  # the two 5 m walls
    result = RoomPlanMeasurementEngine().measure(captured_room)

    # Exactly the measured area: 2 x (5 x 2.5) = 25; net 25 − 1.8 − 1.2 = 22.
    assert result.gross_wall_area_m2 == 25.0
    assert result.net_wall_area_m2 == 22.0
    assert result.completeness.status == "incomplete"
    assert "wall_loop_open" in result.completeness.flags
    assert result.confidence_score <= 0.55  # below the app's "Good" threshold
    assert any("no area added" in note for note in result.notes)

    # The gap is located: both remaining walls are open at both ends, and
    # every open edge names the wall, the end, and where it is.
    edges = result.completeness.open_edges
    assert {(e.wall_id, e.end) for e in edges} == {
        ("w1", "start"), ("w1", "end"), ("w2", "start"), ("w2", "end"),
    }
    for edge in edges:
        assert len(edge.position_m) == 2
        assert edge.nearest_wall_id in {"w1", "w2"}
        assert edge.gap_m == 3.0  # the missing 3 m side walls
        assert edge.wall_id in edge.description

    # Reserved for the correction screen; the engine never sets it.
    assert result.completeness.human_confirmed is False


def test_closed_room_is_complete(captured_room):
    """The full fixture closes its perimeter exactly — complete, no open
    edges, and nothing about uncaptured walls in the notes."""
    result = RoomPlanMeasurementEngine().measure(captured_room)
    assert result.completeness.status == "complete"
    assert result.completeness.flags == []
    assert result.completeness.open_edges == []
    assert not any("uncaptured" in note for note in result.notes)


def test_totals_always_reconcile_with_wall_breakdown(captured_room):
    """One canonical number (Decision 34): room totals are exactly the sum
    of the per-wall breakdown, complete or not."""
    for variant in (captured_room, {**captured_room, "walls": captured_room["walls"][:2]}):
        result = RoomPlanMeasurementEngine().measure(variant)
        included = [w for w in result.walls if w.duplicate_of is None]
        assert result.gross_wall_area_m2 == round(sum(w.gross_area_m2 for w in included), 2)
        assert result.net_wall_area_m2 == round(sum(w.net_area_m2 for w in included), 2)


def test_openings_carry_parent_wall_and_ids(captured_room):
    """Openings are first-class: positional ids, parent wall, and the wall's
    opening_ids back-reference (window on w1, door on w2)."""
    result = RoomPlanMeasurementEngine().measure(captured_room)
    by_id = {o.opening_id: o for o in result.openings}
    assert by_id["d1"].kind == "door"
    assert by_id["d1"].parent_wall_id == "w2"
    assert by_id["d1"].area_m2 == 1.8
    assert by_id["win1"].kind == "window"
    assert by_id["win1"].parent_wall_id == "w1"
    assert by_id["win1"].area_m2 == 1.2
    # No parentIdentifier in this fixture → the nearest-wall fallback.
    assert by_id["d1"].parent_source == "nearest_wall"
    walls = {w.wall_id: w for w in result.walls}
    assert walls["w1"].opening_ids == ["win1"]
    assert walls["w2"].opening_ids == ["d1"]


def test_parent_reference_beats_proximity(captured_room):
    """A door with a parentIdentifier is assigned to THAT wall even when
    another wall is geometrically closer."""
    captured_room["doors"][0]["parentIdentifier"] = "wall-north"  # sits on south
    result = RoomPlanMeasurementEngine().measure(captured_room)
    door = next(o for o in result.openings if o.opening_id == "d1")
    assert door.parent_source == "parent_reference"
    assert door.parent_wall_id == "w1"  # wall-north is the first wall
    walls = {w.wall_id: w for w in result.walls}
    assert walls["w1"].opening_area_m2 == 3.0  # window 1.2 + door 1.8
    assert walls["w2"].opening_area_m2 == 0.0


def test_far_opening_matches_no_wall(captured_room):
    """An opening beyond the assignment cap (e.g. from an adjacent room in a
    multi-room scan) is not subtracted from anything, and is flagged."""
    captured_room["doors"].append({
        "identifier": "door-far",
        "category": {"door": {"isOpen": True}},
        "confidence": {"high": {}},
        "dimensions": [0.9, 2.0, 0.0],
        # 3 m outside the room — nearest wall is over the 0.5 m cap.
        "transform": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0.0, 1.0, 4.5, 1]],
    })
    result = RoomPlanMeasurementEngine().measure(captured_room)
    far = next(o for o in result.openings if o.opening_id == "d2")
    assert far.parent_wall_id is None
    assert far.parent_source == "none"
    assert "unassigned_opening" in result.completeness.flags
    assert result.net_wall_area_m2 == 37.0  # unchanged — nothing subtracted


def test_duplicate_wall_surface_is_excluded_once(captured_room):
    """A split/duplicate surface of an existing wall is excluded from totals
    (never double-counted), keeps its positional id, and is flagged."""
    captured_room["walls"].append({
        "identifier": "wall-north-duplicate",
        "category": {"wall": {}},
        "confidence": {"medium": {}},
        # Same line as wall-north (z=-1.5), 3 m of its 5 m extent.
        "dimensions": [3.0, 2.5, 0.0],
        "transform": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0.0, 1.25, -1.5, 1]],
    })
    result = RoomPlanMeasurementEngine().measure(captured_room)
    assert result.gross_wall_area_m2 == 40.0  # unchanged — counted once
    assert result.net_wall_area_m2 == 37.0
    walls = {w.wall_id: w for w in result.walls}
    assert walls["w5"].duplicate_of == "w1"
    assert "duplicate_wall_surfaces" in result.completeness.flags
    assert result.completeness.status == "complete"  # a dup doesn't open the loop


def test_room_shape_facts_reported(captured_room):
    result = RoomPlanMeasurementEngine().measure(captured_room)
    assert result.perimeter_m == 16.0
    assert result.ceiling_height_m == 2.5
    assert result.flat_ceiling_assumed is True


def test_wall_details_break_down_per_wall(captured_room):
    """Per-wall areas with the door/window assigned to their nearest wall:
    window (1.2 m2) sits on w1, door (1.8 m2) on w2."""
    result = RoomPlanMeasurementEngine().measure(captured_room)
    assert [w.wall_id for w in result.walls] == ["w1", "w2", "w3", "w4"]
    by_id = {w.wall_id: w for w in result.walls}
    assert by_id["w1"].gross_area_m2 == 12.5
    assert by_id["w1"].opening_area_m2 == 1.2
    assert by_id["w1"].net_area_m2 == 11.3
    assert by_id["w2"].opening_area_m2 == 1.8
    assert by_id["w2"].net_area_m2 == 10.7
    assert by_id["w3"].net_area_m2 == 7.5
    assert by_id["w4"].net_area_m2 == 7.5
    # Per-wall nets reconcile with the room total (no completion here)
    assert round(sum(w.net_area_m2 for w in result.walls), 2) == result.net_wall_area_m2


def test_wall_details_deduct_built_ins_on_their_wall(captured_room):
    captured_room["objects"] = [
        {   # tall built-in wardrobe against w1 (z=-1.5)
            "category": {"storage": {}},
            "dimensions": [2.0, 2.2, 0.6],
            "transform": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0.0, 1.1, -1.15, 1]],
        }
    ]
    result = RoomPlanMeasurementEngine().measure(captured_room)
    by_id = {w.wall_id: w for w in result.walls}
    # w1: 12.5 gross − 1.2 window − 4.4 wardrobe = 6.9
    assert by_id["w1"].net_area_m2 == 6.9
    assert by_id["w2"].net_area_m2 == 10.7


def test_polygon_area_l_shape():
    # L-shape: 4x3 rectangle minus a 2x1 corner = 10 m2, in the x-y plane
    corners = [[0, 0, 0], [4, 0, 0], [4, 2, 0], [2, 2, 0], [2, 3, 0], [0, 3, 0]]
    assert _polygon_area_m2(corners) == 10.0
