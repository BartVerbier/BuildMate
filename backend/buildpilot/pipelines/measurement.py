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

from buildpilot.models.session import RoomMeasurement, WallDetail

# Area-weighted confidence values per RoomPlan confidence level.
CONFIDENCE_WEIGHTS = {"high": 1.0, "medium": 0.65, "low": 0.3}
UNKNOWN_CONFIDENCE = 0.5
# A parsed floor smaller than this is treated as a degenerate scan artefact.
MIN_PLAUSIBLE_FLOOR_M2 = 0.5

# Painter knowledge: RoomPlan object categories that are FIXED — built in,
# not moved for painting, so the wall behind them is not paintable.
FIXED_OBJECT_CATEGORIES = {
    "storage", "refrigerator", "oven", "dishwasher", "sink", "bathtub",
    "toilet", "stove", "washerdryer", "fireplace", "stairs",
}
# Everything else (sofa, table, chair, television, bed, ...) is MOVABLE:
# a professional moves and protects it before painting — no deduction.
# An object counts as wall-adjacent within this clearance of a wall line.
WALL_CONTACT_CLEARANCE_M = 0.30
# RoomPlan has no "bench"/"sideboard" category — it reports them as
# "storage", same as a built-in wardrobe. Height is the deterministic
# discriminator: benches/sideboards/dressers are low and get moved;
# genuine built-ins (wardrobes, fitted cabinetry) are tall. Low storage
# is therefore movable. Erring movable slightly over-counts paintable
# area, which is the safe direction for the painter.
BUILT_IN_STORAGE_MIN_HEIGHT_M = 1.4
# Room-closure check: a closed room's wall widths should cover its floor
# perimeter. Real scans (often blocked by furniture) sometimes reconstruct
# only some walls — quoting from those alone silently halves the job.
# Below this coverage ratio the engine completes the missing wall area
# deterministically (missing perimeter x median wall height) and says so.
WALL_CLOSURE_RATIO = 0.9


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


def _object_category(obj: Dict[str, Any]) -> str:
    raw = obj.get("category")
    if isinstance(raw, str):
        return raw.lower()
    if isinstance(raw, dict) and raw:
        return next(iter(raw)).lower()
    return ""


def _wall_segments(walls: List[Dict[str, Any]]) -> List[tuple]:
    """(start, end, height) per wall on the ground plane (world x/z)."""
    segments = []
    for wall in walls:
        cols = _transform_columns(wall)
        dims = wall.get("dimensions") or []
        if cols is None or len(dims) < 2:
            continue
        half = float(dims[0]) / 2.0
        x_axis, t = cols[0], cols[3]
        start = (t[0] - half * x_axis[0], t[2] - half * x_axis[2])
        end = (t[0] + half * x_axis[0], t[2] + half * x_axis[2])
        segments.append((start, end, float(dims[1])))
    return segments


def _distance_to_segment(point: tuple, start: tuple, end: tuple) -> float:
    px, pz = point
    sx, sz = start
    ex, ez = end
    dx, dz = ex - sx, ez - sz
    length_sq = dx * dx + dz * dz
    if length_sq == 0:
        return ((px - sx) ** 2 + (pz - sz) ** 2) ** 0.5
    t = max(0.0, min(1.0, ((px - sx) * dx + (pz - sz) * dz) / length_sq))
    cx, cz = sx + t * dx, sz + t * dz
    return ((px - cx) ** 2 + (pz - cz) ** 2) ** 0.5


def _fixed_object_wall_deduction(
    objects: List[Dict[str, Any]], walls: List[Dict[str, Any]]
) -> tuple[float, int, int, Dict[int, float]]:
    """Wall area hidden behind built-in (fixed) objects, in m².

    A fixed object touching a wall (within clearance) blocks a wall patch of
    its width × its height. Movable furniture is assumed moved before
    painting and never deducted — that's what a professional does.
    Returns (deduction_m2, fixed_count, movable_count, per_wall_deduction)
    where per_wall_deduction maps wall index → deducted m².
    """
    segments = _wall_segments(walls)
    deduction = 0.0
    fixed = movable = 0
    per_wall: Dict[int, float] = {}
    for obj in objects:
        category = _object_category(obj)
        dims = obj.get("dimensions") or []
        cols = _transform_columns(obj)
        if not category or len(dims) < 3 or cols is None:
            continue
        width, height, depth = float(dims[0]), float(dims[1]), float(dims[2])
        is_fixed = category in FIXED_OBJECT_CATEGORIES
        if category == "storage" and height < BUILT_IN_STORAGE_MIN_HEIGHT_M:
            is_fixed = False  # bench/sideboard height — moved, not built in
        if not is_fixed:
            movable += 1
            continue
        fixed += 1
        center = (cols[3][0], cols[3][2])
        reach = depth / 2.0 + WALL_CONTACT_CLEARANCE_M
        best = None
        best_wall = None
        for index, (start, end, wall_height) in enumerate(segments):
            distance = _distance_to_segment(center, start, end)
            if distance <= reach:
                patch = max(width, 0.0) * max(min(height, wall_height), 0.0)
                if best is None or patch > best:
                    best, best_wall = patch, index
        if best:
            deduction += best
            per_wall[best_wall] = per_wall.get(best_wall, 0.0) + best
    return deduction, fixed, movable, per_wall


def _nearest_wall_index(
    surface: Dict[str, Any], segments: List[tuple]
) -> int | None:
    """The wall a door/window/opening belongs to: nearest wall line to its
    centre on the ground plane."""
    cols = _transform_columns(surface)
    if cols is None or not segments:
        return None
    center = (cols[3][0], cols[3][2])
    best = None
    best_index = None
    for index, (start, end, _height) in enumerate(segments):
        distance = _distance_to_segment(center, start, end)
        if best is None or distance < best:
            best, best_index = distance, index
    return best_index


def _wall_details(
    walls: List[Dict[str, Any]],
    openings_all: List[Dict[str, Any]],
    per_wall_fixed_deduction: Dict[int, float],
) -> List[WallDetail]:
    """Per-wall breakdown with doors/windows/openings and built-in
    deductions assigned to their nearest wall. Ids are positional ("w1"...),
    stable because the CapturedRoom JSON is stored verbatim and immutable."""
    segments = _wall_segments(walls)
    opening_by_wall: Dict[int, float] = {}
    for surface in openings_all:
        index = _nearest_wall_index(surface, segments)
        if index is not None:
            opening_by_wall[index] = opening_by_wall.get(index, 0.0) + _surface_area_m2(surface)

    details: List[WallDetail] = []
    for index, wall in enumerate(walls):
        dims = wall.get("dimensions") or []
        width = max(float(dims[0]), 0.0) if len(dims) > 0 else 0.0
        height = max(float(dims[1]), 0.0) if len(dims) > 1 else 0.0
        gross = width * height
        opening = min(opening_by_wall.get(index, 0.0), gross)
        fixed_ded = per_wall_fixed_deduction.get(index, 0.0)
        net = max(gross - opening - fixed_ded, 0.0)
        details.append(WallDetail(
            wall_id=f"w{index + 1}",
            width_m=round(width, 2),
            height_m=round(height, 2),
            gross_area_m2=round(gross, 2),
            opening_area_m2=round(opening, 2),
            net_area_m2=round(net, 2),
        ))
    return details


def _floor_perimeter_m(floors: List[Dict[str, Any]]) -> float:
    """Perimeter of the scanned floor polygon(s) in metres.

    polygonCorners are 3D points in the floor's local frame; perimeter is
    invariant under the rigid transform, so local coordinates suffice.
    """
    total = 0.0
    for floor in floors:
        corners = floor.get("polygonCorners") or []
        if len(corners) < 3:
            continue
        points = [
            [float(c[0]), float(c[1]), float(c[2]) if len(c) > 2 else 0.0]
            for c in corners
        ]
        for i, p in enumerate(points):
            q = points[(i + 1) % len(points)]
            total += sum((a - b) ** 2 for a, b in zip(p, q)) ** 0.5
    return total


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

        # Room-closure check: complete walls the scan failed to reconstruct.
        # A closed room's wall widths cover its floor perimeter; a large gap
        # means missing walls, and quoting only the captured ones would
        # silently under-measure the job (the real cause of the "furniture
        # loses wall area" field reports — walls blocked by furniture never
        # make it into the scan).
        walls_incomplete = False
        perimeter = _floor_perimeter_m(floors)
        wall_width_total = sum(
            max(float((w.get("dimensions") or [0.0])[0]), 0.0) for w in walls
        )
        if perimeter > 0 and wall_width_total < WALL_CLOSURE_RATIO * perimeter:
            heights = sorted(
                float(w["dimensions"][1])
                for w in walls
                if len(w.get("dimensions") or []) > 1
            )
            median_height = heights[len(heights) // 2] if heights else 0.0
            missing = (perimeter - wall_width_total) * median_height
            if missing > 0:
                gross_wall += missing
                net_wall += missing
                walls_incomplete = True
                notes.append(
                    f"Scan captured {wall_width_total:.1f} m of the {perimeter:.1f} m "
                    f"room perimeter; added {missing:.2f} m2 of estimated wall area "
                    "for the uncaptured walls — verify on site"
                )

        # Painter knowledge: walls behind built-ins aren't paintable;
        # movable furniture is moved and protected, so it costs no area.
        objects = captured_room.get("objects") or []
        fixed_deduction, fixed_count, movable_count, per_wall_fixed = (
            _fixed_object_wall_deduction(objects, walls)
        )
        if fixed_deduction > 0:
            net_wall = max(net_wall - fixed_deduction, 0.0)
            notes.append(
                f"Deducted {fixed_deduction:.2f} m2 of wall behind {fixed_count} built-in unit(s)"
            )
        if movable_count > 0:
            notes.append(
                f"{movable_count} movable furniture item(s) assumed moved and protected before painting"
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
        notes.append(
            "Ceiling area assumed equal to floor area; flat ceiling assumed — "
            "exposed beams are not detectable from the scan and need manual review"
        )

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
        if walls_incomplete:
            # Below the app's "Good" threshold (0.6): estimated walls always
            # surface as "check the room", never as a confident measurement.
            confidence = min(confidence, 0.55)

        return RoomMeasurement(
            gross_wall_area_m2=round(gross_wall, 2),
            net_wall_area_m2=round(net_wall, 2),
            ceiling_area_m2=round(ceiling_area, 2),
            floor_area_m2=round(floor_area, 2),
            door_area_m2=round(door_area, 2),
            window_area_m2=round(window_area, 2),
            paintable_surface_area_m2=round(net_wall + ceiling_area, 2),
            confidence_score=round(min(max(confidence, 0.0), 1.0), 2),
            fixed_objects=fixed_count,
            movable_objects=movable_count,
            walls=_wall_details(walls, doors + windows + openings, per_wall_fixed),
            notes=notes,
        )
