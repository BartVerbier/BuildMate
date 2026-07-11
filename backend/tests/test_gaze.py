"""Gaze resolver tests — synthetic poses against the synthetic room.

Fixture walls (see synthetic_room_5x3.json):
  w1: 5.0 x 2.5 at z=-1.5, normal +z   w2: 5.0 x 2.5 at z=+1.5
  w3: 3.0 x 2.5 at x=-2.5              w4: 3.0 x 2.5 at x=+2.5
A camera at the room centre looking along -Z faces w1; rotated 180° it
faces w2. All deterministic geometry — no AI anywhere.
"""

import json
from pathlib import Path

import pytest

from buildpilot.pipelines.gaze import (
    annotate_segments,
    annotated_transcript,
    resolve_pose,
    score_reference_frames,
    wall_rects,
)

FIXTURE = Path(__file__).parent / "fixtures" / "synthetic_room_5x3.json"


@pytest.fixture()
def walls():
    return json.loads(FIXTURE.read_text())["walls"]


def pose_facing_w1(t=0.0, position=(0.0, 1.25, 0.0), **extra):
    """Identity rotation: ARKit cameras look along -Z → toward w1."""
    x, y, z = position
    return {"t": t, "transform": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1], **extra}


def pose_facing_w2(t=0.0):
    """Rotated 180° about Y: forward is +Z → toward w2."""
    return {"t": t, "transform": [-1, 0, 0, 0, 0, 1, 0, 0, 0, 0, -1, 0, 0, 1.25, 0, 1]}


def test_resolve_pose_picks_the_faced_wall(walls):
    rects = wall_rects(walls)
    assert resolve_pose(pose_facing_w1(), rects) == "w1"
    assert resolve_pose(pose_facing_w2(), rects) == "w2"


def test_segments_annotated_with_dominant_wall(walls):
    segments = [
        {"start": 0.0, "end": 4.0, "text": "Look at this wall."},
        {"start": 10.0, "end": 12.0, "text": "No poses here."},
    ]
    poses = [pose_facing_w1(t) for t in (0.5, 1.5, 2.5, 3.5)]
    annotated = annotate_segments(segments, poses, walls)

    assert annotated[0]["wall_id"] == "w1"
    assert annotated[0]["confidence"] == 1.0
    assert annotated[1]["wall_id"] is None
    assert "[facing w1] Look at this wall." in annotated_transcript(annotated)


def test_divided_gaze_resolves_to_nothing(walls):
    """Below the dominance threshold the resolver says 'unsure', never guesses."""
    segments = [{"start": 0.0, "end": 4.0, "text": "somewhere between walls"}]
    poses = [pose_facing_w1(1.0), pose_facing_w1(1.5), pose_facing_w2(2.0), pose_facing_w2(2.5)]
    annotated = annotate_segments(segments, poses, walls)
    assert annotated[0]["wall_id"] is None


def test_reference_frame_prefers_full_wall_coverage(walls):
    """A frame taken from further back that fits the whole wall beats a
    close-up where the wall corners fall outside the field of view."""
    intrinsics = {"fx": 1000.0, "fy": 1000.0, "cx": 960.0, "cy": 540.0, "w": 1920, "h": 1080}
    close = pose_facing_w1(t=1.0, position=(0.0, 1.25, 0.0), **intrinsics)   # 1.5 m from w1
    far = pose_facing_w1(t=5.0, position=(0.0, 1.25, 2.8), **intrinsics)     # 4.3 m from w1

    scores = score_reference_frames(
        {"before-01.jpg": 1.0, "before-02.jpg": 5.0},
        [close, far], walls, target_wall_ids=["w1"],
    )
    assert scores["before-02.jpg"] > scores["before-01.jpg"]


def test_reference_scoring_degrades_without_poses(walls):
    assert score_reference_frames({"before-01.jpg": 1.0}, [], walls, []) == {}
