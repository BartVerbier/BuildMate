"""Stage 0 — wall→pixel projection validation (internal, debug-only).

Proves the load-bearing assumption of the per-wall visualization redesign:
that each RoomPlan wall (and its door/window openings) can be mapped onto the
correct pixels of a real captured Before frame, using only data BuildPilot
already stores (camera poses + intrinsics + per-wall geometry).

This module is pure geometry. It generates NO visualization and NEVER touches
the production `/visualize` path, the estimator, or pricing. It only reads the
saved artifacts and reports where each wall projects, how the sensor frame maps
to the archived JPEG, and a deliberately CONSERVATIVE confidence band.

Confidence philosophy (founder directive): HIGH must be genuinely trustworthy;
prefer LOW over false confidence. A wall is never HIGH unless it is fully in
frame, close to head-on, temporally aligned, and its sensor→JPEG orientation is
unambiguously resolved. When orientation cannot be resolved, the wall is LOW.
"""

from __future__ import annotations

import math
from typing import Any, Dict, List, Optional, Tuple

from buildpilot.pipelines.gaze import (
    _pose_ray,
    _project,
    _WallRect,
    wall_coverage,
    wall_rects,
)
from buildpilot.pipelines.measurement import (
    _nearest_wall_index,
    _object_category,
    _transform_columns,
    _wall_segments,
)

# --- confidence tuning (Stage 0 calibrates these on real rooms) --------------

MAX_TIME_GAP_S = 1.5        # reject a frame whose nearest pose is this far off
HIGH_TIME_GAP_S = 0.4       # HIGH requires the pose within this of the photo
ANGLE_ZERO_DEG = 45.0       # view angle at/above which the angle term is 0
HIGH_ANGLE_DEG = 25.0       # HIGH requires the camera within this of head-on
HIGH_CONF = 0.75            # HIGH requires the blended score at/above this
MEDIUM_CONF = 0.40          # MEDIUM floor; below this is LOW
ORIENT_TOL = 0.02           # sensor↔JPEG scale-agreement tolerance (2%)

BAND_HIGH = "high"
BAND_MEDIUM = "medium"
BAND_LOW = "low"


# --- JPEG dimensions without an image dependency -----------------------------


def read_jpeg_size(data: bytes) -> Optional[Tuple[int, int]]:
    """(width, height) of a JPEG by parsing its SOF marker — no Pillow/numpy.

    Returns None if the bytes are not a parseable JPEG.
    """
    if len(data) < 4 or data[0] != 0xFF or data[1] != 0xD8:
        return None
    i = 2
    n = len(data)
    sof = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}
    while i + 9 < n:
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in sof:
            height = (data[i + 5] << 8) | data[i + 6]
            width = (data[i + 7] << 8) | data[i + 8]
            if width > 0 and height > 0:
                return (width, height)
            return None
        if marker == 0xD8 or marker == 0xD9 or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        if i + 3 >= n:
            break
        seg_len = (data[i + 2] << 8) | data[i + 3]
        if seg_len < 2:
            break
        i += 2 + seg_len
    return None


# --- sensor → JPEG orientation/scaling ---------------------------------------


def resolve_orientation(
    sensor_wh: Tuple[float, float], jpeg_wh: Tuple[float, float], tol: float = ORIENT_TOL
) -> Tuple[str, float, bool]:
    """Map the sensor pixel frame (where intrinsics live) onto the archived
    JPEG's pixels. Returns (mode, scale, resolved).

    The phone bakes the Before JPEG from the landscape sensor buffer with a 90°
    clockwise rotation (RoomCaptureController: `UIImage(orientation: .right)`,
    EXIF-6). So the two legitimate relationships are:
      - "scale":        JPEG is the sensor frame, uniformly scaled (same orient).
      - "rotate90_cw":  JPEG is the sensor frame rotated 90° CW, then scaled.
    The correct one is chosen by which relationship makes the two axis scales
    agree. If both agree (a square-ish sensor → direction is ambiguous) or
    neither does, orientation is UNRESOLVED and the caller must treat the wall
    as LOW rather than guess (founder directive).
    """
    (w, h), (jw, jh) = sensor_wh, jpeg_wh
    if min(w, h, jw, jh) <= 0:
        return ("unresolved", 0.0, False)

    def agree(a: float, b: float) -> bool:
        return abs(a - b) / max(a, b) <= tol

    same_ok = agree(jw / w, jh / h)          # JPEG in the sensor's orientation
    rot_ok = agree(jw / h, jh / w)           # JPEG rotated 90° from the sensor
    if same_ok and rot_ok:
        return ("unresolved", 0.0, False)    # ambiguous (square-ish) — don't guess
    if same_ok:
        return ("scale", (jw / w + jh / h) / 2.0, True)
    if rot_ok:
        return ("rotate90_cw", (jw / h + jh / w) / 2.0, True)
    return ("unresolved", 0.0, False)


def transform_point(
    u_s: float, v_s: float, sensor_wh: Tuple[float, float], mode: str, scale: float
) -> Optional[Tuple[float, float]]:
    """Sensor pixel (u_s, v_s) → JPEG pixel, per the resolved orientation."""
    _, h = sensor_wh
    if mode == "scale":
        return (u_s * scale, v_s * scale)
    if mode == "rotate90_cw":
        # 90° CW: sensor top-left (0,0) → JPEG top-right; sensor (W×H) → (H×W).
        return ((h - v_s) * scale, u_s * scale)
    return None


# --- geometry helpers --------------------------------------------------------


def _unit(v: List[float]) -> List[float]:
    n = math.sqrt(sum(c * c for c in v)) or 1.0
    return [c / n for c in v]


def _view_angle_deg(forward: List[float], normal: List[float]) -> float:
    """Acute angle between the camera's viewing direction and the wall's normal
    line. 0° = perfectly head-on; 90° = grazing. Sign of the normal is ignored."""
    f, nrm = _unit(forward), _unit(normal)
    cos = abs(sum(a * b for a, b in zip(f, nrm)))
    return math.degrees(math.acos(max(0.0, min(1.0, cos))))


def _corner_loop(rect: _WallRect) -> List[List[float]]:
    """rect.corners() returns Z-order [(-,-),(-,+),(+,-),(+,+)]; reorder to a
    proper quad winding so it draws as a closed outline."""
    c = rect.corners()
    return [c[0], c[1], c[3], c[2]]


def _nearest_pose(poses: List[Dict[str, Any]], t: float) -> Tuple[Optional[Dict[str, Any]], float]:
    if not poses:
        return None, float("inf")
    pose = min(poses, key=lambda p: abs(float(p.get("t", 1e9)) - t))
    return pose, abs(float(pose.get("t", 1e9)) - t)


def _project_quad(
    pose: Dict[str, Any], corners: List[List[float]],
    sensor_wh: Tuple[float, float], mode: str, scale: float,
) -> Tuple[List[Optional[List[float]]], List[Optional[List[float]]], int, int]:
    """Project world corners to raw sensor pixels and transformed JPEG pixels.
    Returns (sensor_pts, jpeg_pts, n_in_front, n_in_frame)."""
    jw = (sensor_wh[0] * scale) if mode == "scale" else (sensor_wh[1] * scale)
    jh = (sensor_wh[1] * scale) if mode == "scale" else (sensor_wh[0] * scale)
    sensor_pts: List[Optional[List[float]]] = []
    jpeg_pts: List[Optional[List[float]]] = []
    n_front = 0
    n_in = 0
    for corner in corners:
        s = _project(pose, corner)
        if s is None:
            sensor_pts.append(None)
            jpeg_pts.append(None)
            continue
        n_front += 1
        sensor_pts.append([round(s[0], 1), round(s[1], 1)])
        j = transform_point(s[0], s[1], sensor_wh, mode, scale)
        if j is None:
            jpeg_pts.append(None)
            continue
        jpeg_pts.append([round(j[0], 1), round(j[1], 1)])
        if 0 <= j[0] <= jw and 0 <= j[1] <= jh:
            n_in += 1
    return sensor_pts, jpeg_pts, n_front, n_in


# --- confidence --------------------------------------------------------------


def confidence_band(
    *, orientation_resolved: bool, n_in_front: int, time_gap_s: float,
    n_in_frame: int, view_angle_deg: float,
) -> Tuple[float, str]:
    """The exact Stage 0 confidence score + band.

    Hard rejects → LOW: orientation unresolved, any wall corner behind the
    camera, or no pose within MAX_TIME_GAP_S. Otherwise a multiplicative blend
    (all factors must be good for a high score), with explicit HIGH gates so a
    partial-frame, oblique, or temporally-loose wall can NEVER read HIGH.
    """
    if not orientation_resolved or n_in_front < 4 or time_gap_s > MAX_TIME_GAP_S:
        return 0.0, BAND_LOW
    frame_term = n_in_frame / 4.0
    angle_term = max(0.0, 1.0 - view_angle_deg / ANGLE_ZERO_DEG)
    time_term = max(0.0, 1.0 - time_gap_s / (MAX_TIME_GAP_S / 2.0))
    conf = frame_term * angle_term * time_term
    if (
        conf >= HIGH_CONF and n_in_frame == 4
        and view_angle_deg <= HIGH_ANGLE_DEG and time_gap_s <= HIGH_TIME_GAP_S
    ):
        return round(conf, 3), BAND_HIGH
    if conf >= MEDIUM_CONF:
        return round(conf, 3), BAND_MEDIUM
    return round(conf, 3), BAND_LOW


# --- main entry point --------------------------------------------------------


def _openings(room_json: Dict[str, Any]) -> List[Tuple[str, Dict[str, Any], Optional[int]]]:
    """Doors/windows/openings tagged with their kind and nearest wall index."""
    walls = room_json.get("walls") or []
    segments = _wall_segments(walls)
    out: List[Tuple[str, Dict[str, Any], Optional[int]]] = []
    for key in ("doors", "windows", "openings"):
        for surface in room_json.get(key) or []:
            kind = _object_category(surface) or key[:-1]
            out.append((kind, surface, _nearest_wall_index(surface, segments)))
    return out


def project_walls(
    room_json: Dict[str, Any],
    poses: List[Dict[str, Any]],
    frame_times: Dict[str, float],
    jpeg_sizes: Dict[str, Tuple[int, int]],
) -> List[Dict[str, Any]]:
    """For each wall, pick the best archived frame and report where the wall and
    its openings project — with raw sensor and transformed JPEG coordinates, the
    sensor↔JPEG orientation, and a conservative confidence band. No rendering."""
    rects = wall_rects(room_json.get("walls") or [])
    openings = _openings(room_json)
    results: List[Dict[str, Any]] = []

    for index, rect in enumerate(rects):
        # Best frame for THIS wall: highest wall coverage among frames whose
        # nearest pose is within the time gap. Reuses the production scorer.
        best_name: Optional[str] = None
        best_pose: Optional[Dict[str, Any]] = None
        best_gap = float("inf")
        best_cov = -1.0
        for name, t in frame_times.items():
            if name not in jpeg_sizes:
                continue
            pose, gap = _nearest_pose(poses, float(t))
            if pose is None or gap > MAX_TIME_GAP_S:
                continue
            cov = wall_coverage(pose, rect)
            if cov > best_cov:
                best_cov, best_name, best_pose, best_gap = cov, name, pose, gap

        base: Dict[str, Any] = {
            "wall_id": rect.wall_id,
            "selected_frame": best_name,
            "fallback_used": best_name is None,
        }

        if best_name is None or best_pose is None:
            base.update(confidence=0.0, band=BAND_LOW,
                        reason="no frame with a pose within the time gap")
            results.append(base)
            continue

        sensor_wh = (float(best_pose.get("w", 0)), float(best_pose.get("h", 0)))
        jpeg_wh = (float(jpeg_sizes[best_name][0]), float(jpeg_sizes[best_name][1]))
        mode, scale, resolved = resolve_orientation(sensor_wh, jpeg_wh)

        photo_t = float(frame_times[best_name])
        pose_t = float(best_pose.get("t", photo_t))
        forward = _pose_ray(best_pose)
        angle = _view_angle_deg(forward[1], rect.normal) if forward else 90.0

        s_pts, j_pts, n_front, n_in = _project_quad(
            best_pose, _corner_loop(rect), sensor_wh, mode, scale
        )
        conf, band = confidence_band(
            orientation_resolved=resolved, n_in_front=n_front,
            time_gap_s=best_gap, n_in_frame=n_in, view_angle_deg=angle,
        )

        wall_openings: List[Dict[str, Any]] = []
        for kind, surface, wall_idx in openings:
            if wall_idx != index:
                continue
            try:
                orect = _WallRect(f"{kind}", surface)
            except ValueError:
                continue
            os_pts, oj_pts, _, _ = _project_quad(
                best_pose, _corner_loop(orect), sensor_wh, mode, scale
            )
            wall_openings.append(
                {"kind": kind, "corners_sensor_px": os_pts, "corners_jpeg_px": oj_pts}
            )

        base.update(
            photo_t=round(photo_t, 3),
            pose_t=round(pose_t, 3),
            time_gap_s=round(best_gap, 3),
            sensor_wh=[int(sensor_wh[0]), int(sensor_wh[1])],
            jpeg_wh=[int(jpeg_wh[0]), int(jpeg_wh[1])],
            orientation={"mode": mode, "scale": round(scale, 4), "resolved": resolved},
            coverage=round(best_cov, 3),
            view_angle_deg=round(angle, 1),
            corners_in_front=n_front,
            corners_in_frame=n_in,
            wall_corners_sensor_px=s_pts,
            wall_corners_jpeg_px=j_pts,
            openings=wall_openings,
            confidence=conf,
            band=band,
        )
        results.append(base)

    return results
