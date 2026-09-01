"""Stage 0 — wall→pixel projection validation tests.

Analytic geometry (hand-computable projections) + the conservative confidence
rules. No real image or model is involved; these test the math and the banding,
which is where correctness lives. HTTP/mock tests here make no claim about the
camera or on-device behaviour.
"""

import json
from pathlib import Path

from buildpilot.pipelines.wall_projection import (
    BAND_HIGH,
    BAND_LOW,
    BAND_MEDIUM,
    confidence_band,
    project_walls,
    read_jpeg_size,
    resolve_orientation,
    transform_point,
)

FIX = Path(__file__).parent / "fixtures"


def _load(name):
    return json.loads((FIX / name).read_text())


# --- orientation / scaling ---------------------------------------------------


def test_orientation_identity_and_scale():
    assert resolve_orientation((1920, 1080), (1920, 1080)) == ("scale", 1.0, True)
    mode, scale, ok = resolve_orientation((1920, 1080), (960, 540))
    assert (mode, ok) == ("scale", True) and abs(scale - 0.5) < 1e-9


def test_orientation_rotate90_matches_ios_right_bake():
    # Landscape sensor, portrait JPEG (the phone's `.right`/EXIF-6 bake).
    mode, scale, ok = resolve_orientation((1920, 1080), (1080, 1920))
    assert mode == "rotate90_cw" and ok and abs(scale - 1.0) < 1e-9


def test_orientation_unresolved_is_not_guessed():
    # Square sensor → rotation direction ambiguous → must NOT guess.
    assert resolve_orientation((1000, 1000), (1000, 1000)) == ("unresolved", 0.0, False)
    # Dimensions match neither relationship → unresolved.
    assert resolve_orientation((1920, 1080), (1000, 1000)) == ("unresolved", 0.0, False)


def test_transform_point_rotate90_cw():
    # Sensor centre → JPEG centre; sensor origin → JPEG top-right.
    assert transform_point(960, 540, (1920, 1080), "rotate90_cw", 1.0) == (540, 960)
    assert transform_point(0, 0, (1920, 1080), "rotate90_cw", 1.0) == (1080, 0)
    assert transform_point(100, 50, (1920, 1080), "scale", 2.0) == (200, 100)


# --- JPEG size without a dependency ------------------------------------------


def test_read_jpeg_size_parses_sof_marker():
    # Minimal JPEG: SOI + SOF0 with height=1920, width=1080, then padding.
    data = b"\xff\xd8\xff\xc0\x00\x11\x08\x07\x80\x04\x38" + b"\x00" * 12
    assert read_jpeg_size(data) == (1080, 1920)
    assert read_jpeg_size(b"not a jpeg at all") is None


# --- confidence banding (conservative) ---------------------------------------


def test_high_requires_everything_good():
    conf, band = confidence_band(
        orientation_resolved=True, n_in_front=4, time_gap_s=0.0,
        n_in_frame=4, view_angle_deg=0.0,
    )
    assert band == BAND_HIGH and conf >= 0.75


def test_unresolved_orientation_is_low_even_if_geometry_is_perfect():
    _, band = confidence_band(
        orientation_resolved=False, n_in_front=4, time_gap_s=0.0,
        n_in_frame=4, view_angle_deg=0.0,
    )
    assert band == BAND_LOW


def test_corner_behind_camera_or_stale_pose_is_low():
    _, b1 = confidence_band(
        orientation_resolved=True, n_in_front=3, time_gap_s=0.0,
        n_in_frame=3, view_angle_deg=0.0,
    )
    _, b2 = confidence_band(
        orientation_resolved=True, n_in_front=4, time_gap_s=2.0,
        n_in_frame=4, view_angle_deg=0.0,
    )
    assert b1 == BAND_LOW and b2 == BAND_LOW


def test_partial_frame_or_oblique_can_never_be_high():
    # Fully in frame, head-on, but only 3/4 corners visible → not HIGH.
    _, partial = confidence_band(
        orientation_resolved=True, n_in_front=4, time_gap_s=0.0,
        n_in_frame=3, view_angle_deg=0.0,
    )
    # Fully in frame but oblique (35°) → not HIGH.
    _, oblique = confidence_band(
        orientation_resolved=True, n_in_front=4, time_gap_s=0.0,
        n_in_frame=4, view_angle_deg=35.0,
    )
    assert partial != BAND_HIGH and oblique != BAND_HIGH


def test_medium_band_is_reachable():
    _, band = confidence_band(
        orientation_resolved=True, n_in_front=4, time_gap_s=0.0,
        n_in_frame=3, view_angle_deg=0.0,
    )
    assert band == BAND_MEDIUM


# --- end-to-end analytic projection ------------------------------------------


def test_project_walls_head_on_wall_is_high_and_centred():
    room = _load("projection_room.json")
    poses = _load("projection_poses.json")
    times = _load("projection_photo_times.json")
    # The archived JPEG is the landscape sensor rotated to portrait.
    jpeg_sizes = {"before-01.jpg": (1080, 1920)}

    results = project_walls(room, poses, times, jpeg_sizes)
    assert len(results) == 1
    w = results[0]
    assert w["wall_id"] == "w1"
    assert w["selected_frame"] == "before-01.jpg"
    assert w["fallback_used"] is False
    assert w["orientation"]["mode"] == "rotate90_cw"
    assert w["orientation"]["resolved"] is True
    assert w["corners_in_front"] == 4 and w["corners_in_frame"] == 4
    assert w["view_angle_deg"] < 0.5
    assert w["band"] == BAND_HIGH

    # The wall centre must land on the JPEG centre (1080x1920 → 540, 960).
    pts = w["wall_corners_jpeg_px"]
    cx = sum(p[0] for p in pts) / 4
    cy = sum(p[1] for p in pts) / 4
    assert abs(cx - 540) < 1.0 and abs(cy - 960) < 1.0

    # The window opening is found, assigned to this wall, and projected.
    assert len(w["openings"]) == 1
    assert w["openings"][0]["kind"] == "window"
    assert all(p is not None for p in w["openings"][0]["corners_jpeg_px"])
    # Raw sensor coords are preserved alongside transformed ones (diagnostics).
    assert "wall_corners_sensor_px" in w


def test_project_walls_falls_back_when_no_pose():
    room = _load("projection_room.json")
    times = _load("projection_photo_times.json")
    results = project_walls(room, [], times, {"before-01.jpg": (1080, 1920)})
    assert results[0]["fallback_used"] is True
    assert results[0]["band"] == BAND_LOW


def test_project_walls_rejects_stale_frame():
    room = _load("projection_room.json")
    poses = _load("projection_poses.json")  # pose at t=1.0
    times = {"before-01.jpg": 9.0}          # photo 8 s away → beyond the gap
    results = project_walls(room, poses, times, {"before-01.jpg": (1080, 1920)})
    assert results[0]["fallback_used"] is True
    assert results[0]["band"] == BAND_LOW


# --- gated route behaviour ---------------------------------------------------


def test_debug_route_is_404_when_flag_off(tmp_path, monkeypatch):
    from tests.test_server_e2e import make_client, upload

    monkeypatch.delenv("BUILDPILOT_DEBUG_PROJECTION", raising=False)
    client, _ = make_client(tmp_path)
    sid = upload(client).json()["session_id"]
    assert client.get(f"/sessions/{sid}/debug/wall-projection").status_code == 404


def test_debug_route_serves_html_and_json_when_flag_on(tmp_path, monkeypatch):
    from tests.test_server_e2e import make_client, upload

    monkeypatch.setenv("BUILDPILOT_DEBUG_PROJECTION", "1")
    client, _ = make_client(tmp_path)
    sid = upload(client).json()["session_id"]

    html = client.get(f"/sessions/{sid}/debug/wall-projection")
    assert html.status_code == 200 and "Stage 0" in html.text

    js = client.get(f"/sessions/{sid}/debug/wall-projection?format=json")
    assert js.status_code == 200
    body = js.json()
    assert "walls" in body and "bands" in body

    # Even flag-on, an unknown session is a normal 404 (not a leak).
    missing = client.get("/sessions/visit-00000000-000000-000000/debug/wall-projection")
    assert missing.status_code == 404
