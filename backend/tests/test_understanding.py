"""End-to-end wall understanding: poses + timed segments in, gaze-annotated
extraction and a wall-selected estimate out. AI stages are faked; the gaze
resolver, measurement, and estimator run real."""

import json

from buildpilot.models.session import PaintScope, RequirementExtraction

from tests.test_server_e2e import FIXTURE, make_client


class SegmentTranscriber:
    """Fake transcriber that provides Whisper-style timed segments."""

    def transcribe(self, audio_path):
        return "Look at this wall. We are only painting this one."

    def transcribe_segments(self, audio_path):
        return self.transcribe(audio_path), [
            {"start": 0.0, "end": 4.0, "text": "Look at this wall."},
            {"start": 4.0, "end": 8.0, "text": "We are only painting this one."},
        ]


class CapturingExtractor:
    """Records what the pipeline hands it; selects w1 like the real model
    would when the gaze annotation is present."""

    def __init__(self):
        self.transcript = None
        self.room_context = None

    def extract(self, transcript, room_context=None):
        self.transcript = transcript
        self.room_context = room_context
        painted = ["w1"] if "[facing w1]" in transcript else []
        return RequirementExtraction(
            scope_of_work=["Paint this wall"],
            painted_wall_ids=painted + ["w99"],  # w99 must be dropped by the pipeline
            paint_scope=PaintScope(walls=True, ceiling=False),
        )


def poses_facing_w1():
    """Camera at the room centre looking along -Z (toward w1) for 8 seconds."""
    return [
        {"t": t, "transform": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 1.25, 0, 1]}
        for t in (0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5)
    ]


def upload_with_poses(client):
    return client.post("/sessions", files={
        "room_scan": ("room.json", FIXTURE.read_bytes(), "application/json"),
        "audio": ("visit.m4a", b"fake-m4a-bytes", "audio/mp4"),
        "poses": ("poses.json", json.dumps(poses_facing_w1()).encode(), "application/json"),
    })


def test_gaze_grounded_wall_selection_end_to_end(tmp_path):
    extractor = CapturingExtractor()
    client, store = make_client(
        tmp_path, transcriber=SegmentTranscriber(), extractor=extractor
    )
    response = upload_with_poses(client)
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "completed"

    # The extractor received the gaze-annotated transcript + wall inventory
    assert "[facing w1] Look at this wall." in extractor.transcript
    assert "w1: 5.00 m wide x 2.50 m high" in extractor.room_context

    # Unknown wall ids are dropped; the real one survives
    assert body["requirements"]["painted_wall_ids"] == ["w1"]

    # The estimate priced ONLY w1 (net 11.3 m2), not the room's 37 m2
    assert any(
        "Painting 1 of 4 walls" in a and "11.30 m2" in a
        for a in body["estimate"]["assumptions"]
    )

    # Artifacts for replay/debugging
    session_dir = store.session_dir(body["session_id"])
    assert (session_dir / "poses.json").exists()
    assert (session_dir / "segments.json").exists()
    assert (session_dir / "gaze.json").exists()
    assert body["raw_metadata"]["gaze_resolved_segments"] == "2/2"


def test_visit_without_poses_keeps_room_level_behavior(tmp_path):
    extractor = CapturingExtractor()
    client, _ = make_client(
        tmp_path, transcriber=SegmentTranscriber(), extractor=extractor
    )
    response = client.post("/sessions", files={
        "room_scan": ("room.json", FIXTURE.read_bytes(), "application/json"),
        "audio": ("visit.m4a", b"fake-m4a-bytes", "audio/mp4"),
    })
    body = response.json()
    assert body["status"] == "completed"
    # No gaze annotation → extractor saw the plain transcript, no selection
    assert "[facing" not in extractor.transcript
    assert body["requirements"]["painted_wall_ids"] == []
    assert any("net wall area 37.00" in a for a in body["estimate"]["assumptions"])


def test_photo_capture_time_is_recorded(tmp_path):
    client, store = make_client(tmp_path)
    session_id = upload_with_poses(client).json()["session_id"]
    response = client.post(
        f"/sessions/{session_id}/photos",
        files={"photo": ("p.jpg", b"\xff\xd8\xff\xe0" + b"x" * 100, "image/jpeg")},
        data={"kind": "before", "t": "3.5"},
    )
    assert response.status_code == 200
    times = json.loads(
        (store.session_dir(session_id) / "photos" / "photo-times.json").read_text()
    )
    assert times["before-01.jpg"] == 3.5
