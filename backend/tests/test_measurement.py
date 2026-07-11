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


def test_polygon_area_l_shape():
    # L-shape: 4x3 rectangle minus a 2x1 corner = 10 m2, in the x-y plane
    corners = [[0, 0, 0], [4, 0, 0], [4, 2, 0], [2, 2, 0], [2, 3, 0], [0, 3, 0]]
    assert _polygon_area_m2(corners) == 10.0
