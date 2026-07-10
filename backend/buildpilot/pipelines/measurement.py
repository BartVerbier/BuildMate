"""Deterministic measurement engine over Apple CapturedRoom JSON. Never AI.

Input is the verbatim JSONEncoder output of RoomPlan's CapturedRoom
(docs/DECISIONS.md, Decision 10). All values are metres / square metres —
RoomPlan is natively metric and nothing here converts units (Decision 9).

Parsing is deliberately defensive: Apple owns this schema, and the exact
encoding of enums (confidence) and simd matrices has varied between OS
releases, so both known encodings are accepted. Every non-obvious choice the
engine makes is recorded in the measurement's `notes`.
"""

from __future__ import annotations

from typing import Any, Dict, List, Sequence

from buildpilot.models.session import RoomMeasurement

# Area-weighted confidence values per RoomPlan confidence level.
CONFIDENCE_WEIGHTS = {"high": 1.0, "medium": 0.65, "low": 0.3}
UNKNOWN_CONFIDENCE = 0.5
# A parsed floor smaller than this is treated as a degenerate scan artefact.
MIN_PLAUSIBLE_FLOOR_M2 = 0.5


class MeasurementError(ValueError):
    """Raised when a scan cannot yield meaningful measurements."""


def _surface_area_m2(surface: Dict[str, Any]) -> float:
    """Width x height from a surface's `dimensions` [x, y, z]."""
    dims = surface.get("dimensions") or []
    if len(dims) < 2:
        return 0.0
    return max(float(dims[0]), 0.0) * max(float(dims[1]), 0.0)


def _confidence_weight(surface: Dict[str, Any]) -> float:
    """Accepts both `"confidence": "high"` and `"confidence": {"high": {}}`."""
    raw = surface.get("confidence")
    if isinstance(raw, str):
        return CONFIDENCE_WEIGHTS.get(raw.lower(), UNKNOWN_CONFIDENCE)
    if isinstance(raw, dict) and raw:
        key = next(iter(raw)).lower()
        return CONFIDENCE_WEIGHTS.get(key, UNKNOWN_CONFIDENCE)
    return UNKNOWN_CONFIDENCE


def _transform_columns(surface: Dict[str, Any]) -> List[List[float]] | None:
    """Return the 4 columns of the surface's 4x4 transform.

    Accepts both the nested ([[4],[4],[4],[4]]) and flat ([16]) encodings,
    column-major either way (simd convention).
    """
    raw = surface.get("transform")
    if not raw:
        return None
    if isinstance(raw[0], (list, tuple)):
        cols = [[float(v) for v in col] for col in raw]
        return cols if len(cols) == 4 and all(len(c) == 4 for c in cols) else None
    flat = [float(v) for v in raw]
    if len(flat) != 16:
        return None
    return [flat[i : i + 4] for i in range(0, 16, 4)]


def _polygon_area_m2(corners: Sequence[Sequence[float]]) -> float:
    """Planar polygon area via the shoelace formula.

    Corners are 3D points in the surface's local frame; the polygon is planar,
    so we drop the axis with the smallest spread and apply the shoelace over
    the remaining two. This is convention-independent.
    """
    if len(corners) < 3:
        return 0.0
    points = [[float(c[0]), float(c[1]), float(c[2]) if len(c) > 2 else 0.0] for c in corners]
    ranges = [max(p[i] for p in points) - min(p[i] for p in points) for i in range(3)]
    drop = ranges.index(min(ranges))
    keep = [i for i in range(3) if i != drop]
    area = 0.0
    for i, p in enumerate(points):
        q = points[(i + 1) % len(points)]
        area += p[keep[0]] * q[keep[1]] - q[keep[0]] * p[keep[1]]
    return abs(area) / 2.0


def _wall_footprint_bbox_area_m2(walls: List[Dict[str, Any]]) -> float:
    """Fallback floor estimate: bounding box of wall endpoints on the ground plane.

    Wall endpoints are centre +/- (width/2) along the wall's local x axis,
    projected onto world (x, z). Over-estimates non-rectangular rooms; the
    engine says so in its notes.
    """
    xs: List[float] = []
    zs: List[float] = []
    for wall in walls:
        cols = _transform_columns(wall)
        dims = wall.get("dimensions") or []
        if cols is None or len(dims) < 1:
            continue
        half_w = float(dims[0]) / 2.0
        x_axis, translation = cols[0], cols[3]
        for sign in (-1.0, 1.0):
            xs.append(translation[0] + sign * half_w * x_axis[0])
            zs.append(translation[2] + sign * half_w * x_axis[2])
    if not xs:
        return 0.0
    return (max(xs) - min(xs)) * (max(zs) - min(zs))


class RoomPlanMeasurementEngine:
    def measure(self, captured_room: Dict[str, Any]) -> RoomMeasurement:
        walls = captured_room.get("walls") or []
        doors = captured_room.get("doors") or []
        windows = captured_room.get("windows") or []
        openings = captured_room.get("openings") or []
        floors = captured_room.get("floors") or []
        notes: List[str] = []

        if not walls:
            raise MeasurementError("Scan contains no walls; capture likely failed.")

        gross_wall = sum(_surface_area_m2(w) for w in walls)
        door_area = sum(_surface_area_m2(d) for d in doors)
        window_area = sum(_surface_area_m2(w) for w in windows)
        opening_area = sum(_surface_area_m2(o) for o in openings)
        net_wall = max(gross_wall - door_area - window_area - opening_area, 0.0)
        if opening_area > 0:
            notes.append(
                f"Subtracted {opening_area:.2f} m2 of open doorways from wall area"
            )

        # Floor: prefer the scanned floor polygon, fall back to dimensions,
        # then to the wall footprint.
        floor_area = sum(_polygon_area_m2(f.get("polygonCorners") or []) for f in floors)
        if floor_area >= MIN_PLAUSIBLE_FLOOR_M2:
            notes.append("Floor area from scanned floor polygon")
        else:
            floor_area = sum(_surface_area_m2(f) for f in floors)
            if floor_area >= MIN_PLAUSIBLE_FLOOR_M2:
                notes.append("Floor area from floor surface dimensions (no usable polygon)")
            else:
                floor_area = _wall_footprint_bbox_area_m2(walls)
                notes.append(
                    "Floor area estimated from wall footprint bounding box "
                    "(no floor surface in scan); may over-estimate non-rectangular rooms"
                )

        ceiling_area = floor_area
        notes.append("Ceiling area assumed equal to floor area (V1 assumption)")

        # Area-weighted confidence over the surfaces that drive the estimate.
        surfaces = walls + floors
        total_area = sum(_surface_area_m2(s) for s in surfaces)
        if total_area > 0:
            confidence = sum(
                _confidence_weight(s) * _surface_area_m2(s) for s in surfaces
            ) / total_area
        else:
            confidence = UNKNOWN_CONFIDENCE
        if not floors:
            confidence = min(confidence, 0.5)

        return RoomMeasurement(
            gross_wall_area_m2=round(gross_wall, 2),
            net_wall_area_m2=round(net_wall, 2),
            ceiling_area_m2=round(ceiling_area, 2),
            floor_area_m2=round(floor_area, 2),
            door_area_m2=round(door_area, 2),
            window_area_m2=round(window_area, 2),
            paintable_surface_area_m2=round(net_wall + ceiling_area, 2),
            confidence_score=round(min(max(confidence, 0.0), 1.0), 2),
            notes=notes,
        )
