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

from buildpilot.models.session import (
    MeasurementCompleteness,
    OpeningDetail,
    OpenWallEdge,
    RoomMeasurement,
    WallDetail,
)

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
# only some walls. Below this coverage ratio the scan is flagged INCOMPLETE
# with the open wall edges located — no area is ever fabricated for the
# missing walls (Decision 34, superseding the Decision 26 completion).
WALL_CLOSURE_RATIO = 0.9
# An opening (door/window) without a parentIdentifier is assigned to the
# nearest wall line, but only within this distance — beyond it (e.g. a door
# from an adjacent room in a multi-room scan) it matches no wall and is not
# subtracted from anything.
MAX_OPENING_WALL_DISTANCE_M = 0.5
# Two wall endpoints within this distance count as a joined corner; an
# endpoint with no partner is an open edge of the wall loop.
CORNER_JOIN_TOLERANCE_M = 0.30
# Duplicate-wall guard: a wall whose ground segment lies on another wall's
# line (within the distance below), overlaps ≥ the ratio of its own extent,
# and matches height (within the tolerance) is a split/duplicate surface of
# the same physical wall. Counting both would silently double wall area.
DUPLICATE_LINE_DISTANCE_M = 0.20
DUPLICATE_OVERLAP_RATIO = 0.8
DUPLICATE_HEIGHT_TOLERANCE_M = 0.30
# Walls of one room share a ceiling; a larger height spread is worth a flag.
WALL_HEIGHT_SPREAD_TOLERANCE_M = 0.25
# Positional opening ids per kind: d1..., win1..., op1...
OPENING_ID_PREFIX = {"door": "d", "window": "win", "opening": "op"}


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
    """(start, end, height) per wall on the ground plane (world x/z).

    Compacts unparseable walls out — positions do NOT align with wall index.
    Kept for wall_projection.py; measurement itself uses _aligned_segments so
    every index maps to the wall's positional id ("w{i+1}").
    """
    return [s for s in _aligned_segments(walls) if s is not None]


def _aligned_segments(walls: List[Dict[str, Any]]) -> List[tuple | None]:
    """(start, end, height) per wall, aligned to wall index; None when a wall
    has no usable transform/dimensions."""
    segments: List[tuple | None] = []
    for wall in walls:
        cols = _transform_columns(wall)
        dims = wall.get("dimensions") or []
        if cols is None or len(dims) < 2:
            segments.append(None)
            continue
        half = float(dims[0]) / 2.0
        x_axis, t = cols[0], cols[3]
        start = (t[0] - half * x_axis[0], t[2] - half * x_axis[2])
        end = (t[0] + half * x_axis[0], t[2] + half * x_axis[2])
        segments.append((start, end, float(dims[1])))
    return segments


def _segment_length_m(segment: tuple) -> float:
    (sx, sz), (ex, ez), _height = segment
    return ((ex - sx) ** 2 + (ez - sz) ** 2) ** 0.5


def _point_to_line_distance(point: tuple, start: tuple, end: tuple) -> float:
    """Distance from a point to the INFINITE line through start-end (unlike
    _distance_to_segment, which clamps to the segment)."""
    px, pz = point
    sx, sz = start
    dx, dz = end[0] - sx, end[1] - sz
    length = (dx * dx + dz * dz) ** 0.5
    if length == 0:
        return ((px - sx) ** 2 + (pz - sz) ** 2) ** 0.5
    return abs(dx * (pz - sz) - dz * (px - sx)) / length


def _duplicate_wall_map(segments: List[tuple | None]) -> Dict[int, int]:
    """wall index -> index of the wall it duplicates.

    A wall is a duplicate when its ground segment lies on another wall's line
    (within DUPLICATE_LINE_DISTANCE_M), at least DUPLICATE_OVERLAP_RATIO of
    its own extent overlaps the other's, and heights agree within tolerance.
    The longer wall (lower index on a tie) is kept. This guards against
    RoomPlan emitting split/duplicate surfaces for one physical wall; distant
    parallel walls (opposite sides of a room) never trip the line-distance
    gate, and perpendicular walls never satisfy the overlap gate.
    """
    duplicates: Dict[int, int] = {}
    order = sorted(
        (i for i, s in enumerate(segments) if s is not None and _segment_length_m(s) > 0),
        key=lambda i: (-_segment_length_m(segments[i]), i),
    )
    for pos, i in enumerate(order):
        if i in duplicates:
            continue
        a_start, a_end, a_height = segments[i]
        a_len = _segment_length_m(segments[i])
        dx, dz = a_end[0] - a_start[0], a_end[1] - a_start[1]
        for j in order[pos + 1 :]:
            if j in duplicates:
                continue
            b_start, b_end, b_height = segments[j]
            b_len = _segment_length_m(segments[j])
            if abs(a_height - b_height) > DUPLICATE_HEIGHT_TOLERANCE_M:
                continue
            if max(
                _point_to_line_distance(b_start, a_start, a_end),
                _point_to_line_distance(b_end, a_start, a_end),
            ) > DUPLICATE_LINE_DISTANCE_M:
                continue
            # Overlap of b's extent with a's, both projected onto a's line.
            t0 = ((b_start[0] - a_start[0]) * dx + (b_start[1] - a_start[1]) * dz) / (a_len * a_len)
            t1 = ((b_end[0] - a_start[0]) * dx + (b_end[1] - a_start[1]) * dz) / (a_len * a_len)
            lo, hi = min(t0, t1), max(t0, t1)
            overlap_m = max(0.0, (min(hi, 1.0) - max(lo, 0.0))) * a_len
            if overlap_m >= DUPLICATE_OVERLAP_RATIO * b_len:
                duplicates[j] = i
    return duplicates


def _open_wall_edges(
    segments: List[tuple | None], excluded: Dict[int, int]
) -> List[OpenWallEdge]:
    """The wall-loop gaps: endpoints with no joined partner on another wall.

    Gives the app a concrete rescan target — which wall, which end, where on
    the ground plane, and how far the nearest other wall end is.
    """
    endpoints = []
    for index, segment in enumerate(segments):
        if segment is None or index in excluded:
            continue
        endpoints.append((index, "start", segment[0]))
        endpoints.append((index, "end", segment[1]))
    edges: List[OpenWallEdge] = []
    for index, end, point in endpoints:
        best = None
        best_wall = None
        for other, _end, other_point in endpoints:
            if other == index:
                continue
            gap = ((point[0] - other_point[0]) ** 2 + (point[1] - other_point[1]) ** 2) ** 0.5
            if best is None or gap < best:
                best, best_wall = gap, other
        if best is not None and best <= CORNER_JOIN_TOLERANCE_M:
            continue  # joined corner
        wall_id = f"w{index + 1}"
        nearest_id = f"w{best_wall + 1}" if best_wall is not None else None
        if nearest_id is not None:
            description = (
                f"Wall {wall_id} does not connect at its {end} end "
                f"(x={point[0]:.1f} m, z={point[1]:.1f} m); nearest wall end "
                f"is {nearest_id}, {best:.1f} m away"
            )
        else:
            description = (
                f"Wall {wall_id} stands alone; its {end} end at "
                f"(x={point[0]:.1f} m, z={point[1]:.1f} m) connects to nothing"
            )
        edges.append(OpenWallEdge(
            wall_id=wall_id,
            end=end,
            position_m=[round(point[0], 2), round(point[1], 2)],
            nearest_wall_id=nearest_id,
            gap_m=round(best, 2) if best is not None else None,
            description=description,
        ))
    return edges


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
    where per_wall_deduction maps wall index → deducted m². Indexes are
    positional wall indexes (aligned even when a wall is unparseable).
    """
    segments = _aligned_segments(walls)
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
        for index, segment in enumerate(segments):
            if segment is None:
                continue
            start, end, wall_height = segment
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


def _opening_details(
    captured_room: Dict[str, Any],
    walls: List[Dict[str, Any]],
    segments: List[tuple | None],
    duplicates: Dict[int, int],
) -> List[tuple]:
    """Every door/window/opening with its parent wall resolved.

    Returns [(parent_wall_index | None, OpeningDetail), ...]. Assignment
    prefers RoomPlan's own `parentIdentifier` (authoritative when it names a
    wall in this scan); the nearest-wall fallback covers encodings without
    it, capped at MAX_OPENING_WALL_DISTANCE_M so an opening from another
    room matches nothing rather than the wrong wall. A parent that is an
    excluded duplicate redirects to the wall that was kept.
    """
    ident_to_index: Dict[str, int] = {}
    for index, wall in enumerate(walls):
        ident = wall.get("identifier")
        if isinstance(ident, str):
            ident_to_index[ident] = index

    assignments: List[tuple] = []
    for kind, source_key in (("door", "doors"), ("window", "windows"), ("opening", "openings")):
        for n, surface in enumerate(captured_room.get(source_key) or []):
            dims = surface.get("dimensions") or []
            width = max(float(dims[0]), 0.0) if len(dims) > 0 else 0.0
            height = max(float(dims[1]), 0.0) if len(dims) > 1 else 0.0

            parent_index = None
            source = "none"
            parent_ident = surface.get("parentIdentifier")
            if isinstance(parent_ident, str) and parent_ident in ident_to_index:
                parent_index = ident_to_index[parent_ident]
                source = "parent_reference"
            else:
                cols = _transform_columns(surface)
                if cols is not None:
                    center = (cols[3][0], cols[3][2])
                    best = None
                    best_index = None
                    for index, segment in enumerate(segments):
                        if segment is None:
                            continue
                        distance = _distance_to_segment(center, segment[0], segment[1])
                        if best is None or distance < best:
                            best, best_index = distance, index
                    if best is not None and best <= MAX_OPENING_WALL_DISTANCE_M:
                        parent_index = best_index
                        source = "nearest_wall"
            if parent_index is not None and parent_index in duplicates:
                parent_index = duplicates[parent_index]

            assignments.append((parent_index, OpeningDetail(
                opening_id=f"{OPENING_ID_PREFIX[kind]}{n + 1}",
                kind=kind,
                parent_wall_id=f"w{parent_index + 1}" if parent_index is not None else None,
                parent_source=source,
                width_m=round(width, 2),
                height_m=round(height, 2),
                area_m2=round(width * height, 2),
            )))
    return assignments


def _wall_details(
    walls: List[Dict[str, Any]],
    opening_assignments: List[tuple],
    per_wall_fixed_deduction: Dict[int, float],
    duplicates: Dict[int, int],
) -> List[WallDetail]:
    """Per-wall breakdown with openings and built-in deductions on their
    parent wall. Ids are positional ("w1"...), stable because the
    CapturedRoom JSON is stored verbatim and immutable — excluded duplicates
    keep their id so nothing shifts."""
    opening_area_by_wall: Dict[int, float] = {}
    opening_ids_by_wall: Dict[int, List[str]] = {}
    for parent_index, opening in opening_assignments:
        if parent_index is None:
            continue
        opening_area_by_wall[parent_index] = (
            opening_area_by_wall.get(parent_index, 0.0) + opening.area_m2
        )
        opening_ids_by_wall.setdefault(parent_index, []).append(opening.opening_id)

    details: List[WallDetail] = []
    for index, wall in enumerate(walls):
        dims = wall.get("dimensions") or []
        width = max(float(dims[0]), 0.0) if len(dims) > 0 else 0.0
        height = max(float(dims[1]), 0.0) if len(dims) > 1 else 0.0
        gross = width * height
        opening = min(opening_area_by_wall.get(index, 0.0), gross)
        fixed_ded = per_wall_fixed_deduction.get(index, 0.0)
        net = max(gross - opening - fixed_ded, 0.0)
        details.append(WallDetail(
            wall_id=f"w{index + 1}",
            width_m=round(width, 2),
            height_m=round(height, 2),
            gross_area_m2=round(gross, 2),
            opening_area_m2=round(opening, 2),
            net_area_m2=round(net, 2),
            opening_ids=opening_ids_by_wall.get(index, []),
            duplicate_of=(
                f"w{duplicates[index] + 1}" if index in duplicates else None
            ),
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
    """Pure function of the scan geometry (Decision 34): same CapturedRoom
    in, same numbers out, always. Never reads the transcript, requirements,
    or any estimation input. An incomplete scan is flagged with its gaps
    located — area is never fabricated for walls the scan did not capture."""

    def measure(self, captured_room: Dict[str, Any]) -> RoomMeasurement:
        walls = captured_room.get("walls") or []
        doors = captured_room.get("doors") or []
        windows = captured_room.get("windows") or []
        floors = captured_room.get("floors") or []
        notes: List[str] = []
        flags: List[str] = []
        completeness_details: List[str] = []

        if not walls:
            raise MeasurementError("Scan contains no walls; capture likely failed.")

        segments = _aligned_segments(walls)
        duplicates = _duplicate_wall_map(segments)
        opening_assignments = _opening_details(captured_room, walls, segments, duplicates)

        # Painter knowledge: walls behind built-ins aren't paintable;
        # movable furniture is moved and protected, so it costs no area.
        objects = captured_room.get("objects") or []
        fixed_deduction, fixed_count, movable_count, per_wall_fixed = (
            _fixed_object_wall_deduction(objects, walls)
        )

        wall_details = _wall_details(walls, opening_assignments, per_wall_fixed, duplicates)
        included = [w for w in wall_details if w.duplicate_of is None]

        # ONE canonical wall number: room totals are exactly the sum of the
        # per-wall breakdown, so every consumer reconciles by construction.
        gross_wall = round(sum(w.gross_area_m2 for w in included), 2)
        net_wall = round(sum(w.net_area_m2 for w in included), 2)

        # Raw door/window totals stay informational (unchanged semantics).
        door_area = sum(_surface_area_m2(d) for d in doors)
        window_area = sum(_surface_area_m2(w) for w in windows)

        if duplicates:
            dup_ids = ", ".join(
                f"{w.wall_id} (duplicate of {w.duplicate_of})"
                for w in wall_details if w.duplicate_of is not None
            )
            flags.append("duplicate_wall_surfaces")
            completeness_details.append(
                f"Excluded duplicate wall surface(s) from totals: {dup_ids}"
            )
            notes.append(f"Excluded duplicate wall surface(s): {dup_ids}")

        unassigned = [o for parent, o in opening_assignments if parent is None]
        if unassigned:
            ids = ", ".join(o.opening_id for o in unassigned)
            flags.append("unassigned_opening")
            completeness_details.append(
                f"Opening(s) {ids} matched no wall (within "
                f"{MAX_OPENING_WALL_DISTANCE_M} m) and were not subtracted"
            )
            notes.append(f"Opening(s) {ids} matched no wall; not subtracted from wall area")

        doorway_area = sum(
            o.area_m2 for parent, o in opening_assignments
            if parent is not None and o.kind == "opening"
        )
        if doorway_area > 0:
            notes.append(
                f"Subtracted {doorway_area:.2f} m2 of open doorways from wall area"
            )
        if fixed_deduction > 0:
            notes.append(
                f"Deducted {fixed_deduction:.2f} m2 of wall behind {fixed_count} built-in unit(s)"
            )
        if movable_count > 0:
            notes.append(
                f"{movable_count} movable furniture item(s) assumed moved and protected before painting"
            )

        # Floor: the scanned floor polygon is the source of truth. The
        # fallbacks (surface dimensions, wall-footprint bbox) keep the
        # pipeline's degradation policy alive but always flag the scan
        # incomplete — an estimated floor is never passed off as measured.
        floor_area = sum(_polygon_area_m2(f.get("polygonCorners") or []) for f in floors)
        floor_from_scan = True
        if floor_area >= MIN_PLAUSIBLE_FLOOR_M2:
            notes.append("Floor area from scanned floor polygon")
        else:
            flags.append("no_floor_polygon")
            floor_area = sum(_surface_area_m2(f) for f in floors)
            if floor_area >= MIN_PLAUSIBLE_FLOOR_M2:
                completeness_details.append(
                    "No usable floor polygon; floor area from floor surface dimensions"
                )
                notes.append("Floor area from floor surface dimensions (no usable polygon)")
            else:
                floor_area = _wall_footprint_bbox_area_m2(walls)
                floor_from_scan = False
                flags.append("floor_estimated_from_walls")
                completeness_details.append(
                    "No floor surface in scan; floor area estimated from the "
                    "wall footprint bounding box"
                )
                notes.append(
                    "Floor area estimated from wall footprint bounding box "
                    "(no floor surface in scan); may over-estimate non-rectangular rooms"
                )

        ceiling_area = floor_area
        notes.append(
            "Ceiling area assumed equal to floor area; flat ceiling assumed — "
            "exposed beams are not detectable from the scan and need manual review"
        )

        # Wall heights of one room share a ceiling; a spread is worth a flag.
        heights = sorted(
            segment[2] for index, segment in enumerate(segments)
            if segment is not None and index not in duplicates
        )
        ceiling_height = heights[len(heights) // 2] if heights else None
        if heights and heights[-1] - heights[0] > WALL_HEIGHT_SPREAD_TOLERANCE_M:
            flags.append("wall_heights_vary")
            completeness_details.append(
                f"Wall heights vary from {heights[0]:.2f} m to {heights[-1]:.2f} m "
                "— sloped ceiling or scan artefact, verify on site"
            )

        # Room-closure check (Decision 34): a closed room's wall widths cover
        # its floor perimeter. A large gap means the scan missed walls
        # (furniture blocking the sweep is the common field cause). The scan
        # is flagged INCOMPLETE with the open edges located — no wall area is
        # invented. Rescan is the resolution path; the correction screen's
        # human_confirmed is the override for genuinely unscannable walls.
        walls_incomplete = False
        open_edges: List[OpenWallEdge] = []
        perimeter = _floor_perimeter_m(floors)
        wall_width_total = sum(
            max(float((walls[i].get("dimensions") or [0.0])[0]), 0.0)
            for i in range(len(walls))
            if i not in duplicates
        )
        if perimeter > 0 and wall_width_total < WALL_CLOSURE_RATIO * perimeter:
            walls_incomplete = True
            flags.append("wall_loop_open")
            open_edges = _open_wall_edges(segments, duplicates)
            completeness_details.append(
                f"Walls cover {wall_width_total:.1f} m of the {perimeter:.1f} m "
                "floor perimeter; the wall loop does not close"
            )
            notes.append(
                f"Scan captured {wall_width_total:.1f} m of the {perimeter:.1f} m "
                "room perimeter; wall loop open — no area added for the "
                "uncaptured walls, rescan or confirm the room on site"
            )

        status = (
            "incomplete"
            if walls_incomplete or "no_floor_polygon" in flags
            else "complete"
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
            # Below the app's "Good" threshold (0.6): an open wall loop always
            # surfaces as "check the room", never as a confident measurement.
            confidence = min(confidence, 0.55)

        return RoomMeasurement(
            gross_wall_area_m2=gross_wall,
            net_wall_area_m2=net_wall,
            ceiling_area_m2=round(ceiling_area, 2),
            floor_area_m2=round(floor_area, 2),
            door_area_m2=round(door_area, 2),
            window_area_m2=round(window_area, 2),
            paintable_surface_area_m2=round(net_wall + round(ceiling_area, 2), 2),
            confidence_score=round(min(max(confidence, 0.0), 1.0), 2),
            fixed_objects=fixed_count,
            movable_objects=movable_count,
            walls=wall_details,
            openings=[o for _parent, o in opening_assignments],
            notes=notes,
            perimeter_m=round(perimeter, 2) if perimeter > 0 else None,
            ceiling_height_m=round(ceiling_height, 2) if ceiling_height else None,
            flat_ceiling_assumed=True,
            completeness=MeasurementCompleteness(
                status=status,
                flags=flags,
                details=completeness_details,
                open_edges=open_edges,
                human_confirmed=False,  # reserved for the correction screen
            ),
            # Structured capture-quality signals for the confidence engine.
            # perimeter ratio: how much of the room's perimeter was actually
            # captured (None when there's no floor perimeter to compare to).
            wall_perimeter_ratio=(
                round(min(wall_width_total / perimeter, 1.0), 3)
                if perimeter > 0
                else None
            ),
            floor_captured=floor_from_scan,
        )
