"""Gaze resolution: which wall was the camera facing while words were said.

Pure deterministic geometry — never AI. ARKit camera poses (recorded by the
phone during the scan, same world frame as the RoomPlan geometry) are
ray-cast against the CapturedRoom wall rectangles. Each transcript segment
is annotated with the wall the camera dwelled on, so the requirements
extractor can ground phrases like "this wall" in actual geometry.

The same projection math scores how completely a wall fits inside a sampled
frame, which drives reference-photo selection for the visualization.

Conventions (ARKit / RoomPlan, both metric, shared world frame):
- transforms are 4x4 column-major, columns = [right, up, backward, position]
- the camera looks along its local -Z axis
- a wall's local X spans its width, Y its height, Z is its normal
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from buildpilot.pipelines.measurement import _transform_columns

# A hit slightly outside the wall rectangle still counts — RoomPlan wall
# extents and camera poses each carry a few centimetres of error.
EDGE_TOLERANCE = 1.15
# Ray hits closer than this are the painter's hand, further are noise.
MIN_HIT_DISTANCE_M = 0.3
MAX_HIT_DISTANCE_M = 15.0
# Deixis lag: "this wall" is often said just after (or while) turning, so a
# segment's gaze window opens early.
SEGMENT_LEAD_S = 1.0
# A wall must dominate this fraction of a segment's resolved poses to be
# reported with confidence.
DOMINANCE_THRESHOLD = 0.6


def _vec_sub(a, b):
    return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


class _WallRect:
    """A wall as an oriented rectangle in world space."""

    def __init__(self, wall_id: str, wall: Dict[str, Any]) -> None:
        cols = _transform_columns(wall)
        dims = wall.get("dimensions") or []
        if cols is None or len(dims) < 2:
            raise ValueError(f"wall {wall_id} has no usable transform/dimensions")
        self.wall_id = wall_id
        self.x_axis = cols[0][:3]
        self.y_axis = cols[1][:3]
        self.normal = cols[2][:3]
        self.center = cols[3][:3]
        self.half_width = float(dims[0]) / 2.0
        self.half_height = float(dims[1]) / 2.0

    def ray_hit(self, origin, direction) -> Optional[float]:
        """Distance along the ray to a hit on this wall, or None."""
        denom = _dot(direction, self.normal)
        if abs(denom) < 1e-6:
            return None
        t = _dot(_vec_sub(self.center, origin), self.normal) / denom
        if not (MIN_HIT_DISTANCE_M <= t <= MAX_HIT_DISTANCE_M):
            return None
        hit = [origin[i] + t * direction[i] for i in range(3)]
        local = _vec_sub(hit, self.center)
        u = _dot(local, self.x_axis)
        v = _dot(local, self.y_axis)
        if abs(u) <= self.half_width * EDGE_TOLERANCE and abs(v) <= self.half_height * EDGE_TOLERANCE:
            return t
        return None

    def corners(self) -> List[List[float]]:
        result = []
        for su in (-1.0, 1.0):
            for sv in (-1.0, 1.0):
                result.append([
                    self.center[i]
                    + su * self.half_width * self.x_axis[i]
                    + sv * self.half_height * self.y_axis[i]
                    for i in range(3)
                ])
        return result


def wall_rects(walls_json: List[Dict[str, Any]]) -> List[_WallRect]:
    """Wall rectangles with the same positional ids ("w1"...) the
    measurement engine assigns — the shared vocabulary of the pipeline."""
    rects = []
    for index, wall in enumerate(walls_json):
        try:
            rects.append(_WallRect(f"w{index + 1}", wall))
        except ValueError:
            continue
    return rects


def _pose_ray(pose: Dict[str, Any]):
    """(origin, forward) of a camera pose entry, or None if malformed."""
    cols = _transform_columns(pose)
    if cols is None:
        return None
    origin = cols[3][:3]
    forward = [-cols[2][0], -cols[2][1], -cols[2][2]]  # camera looks along -Z
    return origin, forward


def resolve_pose(pose: Dict[str, Any], rects: List[_WallRect]) -> Optional[str]:
    """The wall this pose is looking at (nearest ray hit), or None."""
    ray = _pose_ray(pose)
    if ray is None:
        return None
    origin, forward = ray
    best_t = None
    best_id = None
    for rect in rects:
        t = rect.ray_hit(origin, forward)
        if t is not None and (best_t is None or t < best_t):
            best_t, best_id = t, rect.wall_id
    return best_id


def annotate_segments(
    segments: List[Dict[str, Any]],
    poses: List[Dict[str, Any]],
    walls_json: List[Dict[str, Any]],
) -> List[Dict[str, Any]]:
    """Per transcript segment: the dominant gazed wall and its dominance.

    Returns [{start, end, text, wall_id | None, confidence}]. Deterministic;
    with no poses or no walls every segment resolves to None.
    """
    rects = wall_rects(walls_json)
    annotated = []
    for segment in segments:
        start = float(segment.get("start", 0.0)) - SEGMENT_LEAD_S
        end = float(segment.get("end", 0.0))
        window = [p for p in poses if start <= float(p.get("t", -1)) <= end]
        hits: Dict[str, int] = {}
        for pose in window:
            wall_id = resolve_pose(pose, rects)
            if wall_id:
                hits[wall_id] = hits.get(wall_id, 0) + 1
        wall_id = None
        confidence = 0.0
        if hits:
            wall_id, count = max(hits.items(), key=lambda kv: kv[1])
            confidence = count / max(len(window), 1)
            if confidence < DOMINANCE_THRESHOLD:
                wall_id, confidence = None, confidence
        annotated.append({
            "start": round(float(segment.get("start", 0.0)), 2),
            "end": round(end, 2),
            "text": (segment.get("text") or "").strip(),
            "wall_id": wall_id,
            "confidence": round(confidence, 2),
        })
    return annotated


def annotated_transcript(annotations: List[Dict[str, Any]]) -> str:
    """The transcript with gaze annotations inline, for the extractor."""
    lines = []
    for a in annotations:
        prefix = f"[facing {a['wall_id']}] " if a.get("wall_id") else ""
        lines.append(prefix + a["text"])
    return "\n".join(lines)


# --- reference-photo scoring --------------------------------------------------


def _project(pose: Dict[str, Any], point: List[float]):
    """Project a world point into the pose's sensor pixel space.

    Returns (u, v) or None if the point is behind the camera. Requires the
    pose entry to carry intrinsics (fx, fy, cx, cy) — sensor-space, matching
    ARKit's camera.intrinsics for the native landscape sensor frame.
    """
    cols = _transform_columns(pose)
    if cols is None:
        return None
    origin = cols[3][:3]
    rel = _vec_sub(point, origin)
    # Camera-space coordinates: rows of the rotation (columns are orthonormal).
    x = _dot(rel, cols[0][:3])
    y = _dot(rel, cols[1][:3])
    z = _dot(rel, cols[2][:3])  # camera looks along -Z: visible means z < 0
    if z >= -1e-6:
        return None
    fx, fy = float(pose.get("fx", 0)), float(pose.get("fy", 0))
    cx, cy = float(pose.get("cx", 0)), float(pose.get("cy", 0))
    if fx <= 0 or fy <= 0:
        return None
    u = fx * (x / -z) + cx
    v = fy * (-y / -z) + cy  # image v grows downward; camera y grows upward
    return (u, v)


def wall_coverage(pose: Dict[str, Any], rect: _WallRect) -> float:
    """How completely this wall fits inside the pose's frame: the fraction
    of its corners that project inside the image (0.0–1.0), with a small
    bonus for frames that keep a margin around the wall (slightly wider
    than the work area — what the customer should see)."""
    width = float(pose.get("w", 0))
    height = float(pose.get("h", 0))
    if width <= 0 or height <= 0:
        return 0.0
    inside = 0
    inside_with_margin = 0
    margin_x, margin_y = width * 0.04, height * 0.04
    for corner in rect.corners():
        projected = _project(pose, corner)
        if projected is None:
            continue
        u, v = projected
        if 0 <= u <= width and 0 <= v <= height:
            inside += 1
            if margin_x <= u <= width - margin_x and margin_y <= v <= height - margin_y:
                inside_with_margin += 1
    return inside / 4.0 + 0.1 * (inside_with_margin / 4.0)


def score_reference_frames(
    frame_times: Dict[str, float],
    poses: List[Dict[str, Any]],
    walls_json: List[Dict[str, Any]],
    target_wall_ids: List[str],
) -> Dict[str, float]:
    """Score archived Before photos by how completely they show the walls
    being painted. `frame_times` maps photo file name → capture time (s,
    audio clock); each photo is matched to its nearest pose. Photos without
    a matching pose score 0."""
    rects = [r for r in wall_rects(walls_json) if not target_wall_ids or r.wall_id in target_wall_ids]
    scores: Dict[str, float] = {}
    if not rects or not poses:
        return scores
    for name, t in frame_times.items():
        pose = min(poses, key=lambda p: abs(float(p.get("t", 1e9)) - float(t)))
        if abs(float(pose.get("t", 1e9)) - float(t)) > 1.5:
            scores[name] = 0.0
            continue
        scores[name] = sum(wall_coverage(pose, rect) for rect in rects) / len(rects)
    return scores
