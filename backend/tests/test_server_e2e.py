"""End-to-end tests: multipart upload → pipeline → draft estimate.

AI stages (transcription, extraction) are faked so the tests are fast and
deterministic; measurement and estimation run for real. The real Whisper path
is exercised by the integration test in test_transcription.py.
"""

import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from buildpilot.config import DEFAULT_COMPANY_PROFILE
from buildpilot.models.session import PaintScope, RequirementExtraction
from buildpilot.pipeline import VisitPipeline
from buildpilot.pipelines.estimator import DeterministicEstimator
from buildpilot.pipelines.extraction import ExtractionError
from buildpilot.pipelines.measurement import RoomPlanMeasurementEngine
from buildpilot.pipelines.transcription import TranscriptionError
from buildpilot.server import create_app
from buildpilot.session_store import SessionStore

FIXTURE = Path(__file__).parent / "fixtures" / "synthetic_room_5x3.json"


class FakeTranscriber:
    def __init__(self, text="Paint the walls, leave the ceiling, fill the cracks."):
        self.text = text

    def transcribe(self, audio_path: Path) -> str:
        return self.text


class FailingTranscriber:
    def transcribe(self, audio_path: Path) -> str:
        raise TranscriptionError("whisper unavailable")


class FakeExtractor:
    def extract(self, transcript: str) -> RequirementExtraction:
        return RequirementExtraction(
            scope_of_work=["Paint the walls"],
            exclusions=["Ceiling"],
            preparation_required=["Fill the cracks"],
            paint_scope=PaintScope(walls=True, ceiling=False),
        )


class FailingExtractor:
    def extract(self, transcript: str) -> RequirementExtraction:
        raise ExtractionError("no API credentials")


def make_client(tmp_path, transcriber=None, extractor=None):
    pipeline = VisitPipeline(
        measurement_engine=RoomPlanMeasurementEngine(),
        transcriber=transcriber or FakeTranscriber(),
        extractor=extractor or FakeExtractor(),
        estimator=DeterministicEstimator(),
        company_profile=DEFAULT_COMPANY_PROFILE,
    )
    store = SessionStore(tmp_path / "sessions")
    return TestClient(create_app(pipeline=pipeline, store=store)), store


def upload(client, with_audio=True):
    files = {"room_scan": ("room.json", FIXTURE.read_bytes(), "application/json")}
    if with_audio:
        files["audio"] = ("visit.m4a", b"fake-m4a-bytes", "audio/mp4")
    return client.post("/sessions", files=files)


def test_health(tmp_path):
    client, _ = make_client(tmp_path)
    body = client.get("/health").json()
    assert body["status"] == "ok"


def test_full_visit_produces_estimate(tmp_path):
    client, store = make_client(tmp_path)
    response = upload(client)

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "completed"

    # Measurement (from the synthetic 5x3 fixture)
    assert body["measurements"]["net_wall_area_m2"] == 37.0
    assert body["measurements"]["ceiling_area_m2"] == 15.0

    # Requirements (ceiling excluded by the fake extractor)
    assert body["requirements"]["paint_scope"] == {"walls": True, "ceiling": False}

    # Estimate: walls only = 37 m2
    #   paint  = 37 x 2 / 12 x 1.10 = 6.783 -> 7.0 L
    #   primer = 37 / 10 x 1.10     = 4.07  -> 4.5 L
    estimate = body["estimate"]
    assert estimate["paint_quantity_litres"] == 7.0
    assert estimate["primer_quantity_litres"] == 4.5
    assert estimate["currency"] == "EUR"
    assert estimate["suggested_quotation_eur"] > 0
    assert any("Ceiling excluded" in a for a in estimate["assumptions"])

    # Session directory has every artifact
    session_dir = store.session_dir(body["session_id"])
    for artifact in ("session.json", "room.json", "audio.m4a", "transcript.txt", "estimate.json"):
        assert (session_dir / artifact).exists(), artifact

    # And the session is re-fetchable
    refetch = client.get(f"/sessions/{body['session_id']}")
    assert refetch.status_code == 200
    assert refetch.json() == body


def test_visit_without_audio_degrades_to_default_scope(tmp_path):
    client, _ = make_client(tmp_path)
    body = upload(client, with_audio=False).json()

    assert body["status"] == "completed"
    assert body["requirements"]["transcript_available"] is False
    # default scope: walls + ceiling both painted
    assert body["requirements"]["paint_scope"] == {"walls": True, "ceiling": True}
    assert body["estimate"]["suggested_quotation_eur"] > 0


def test_transcription_failure_still_produces_estimate(tmp_path):
    client, _ = make_client(tmp_path, transcriber=FailingTranscriber())
    body = upload(client).json()

    assert body["status"] == "completed"
    assert body["requirements"]["transcript_available"] is False


def test_extraction_failure_still_produces_estimate(tmp_path):
    client, _ = make_client(tmp_path, extractor=FailingExtractor())
    body = upload(client).json()

    assert body["status"] == "completed"
    assert any(
        "extraction unavailable" in note.lower()
        for note in body["requirements"]["special_notes"]
    )
    assert body["estimate"]["suggested_quotation_eur"] > 0


def test_invalid_room_scan_is_rejected(tmp_path):
    client, _ = make_client(tmp_path)
    response = client.post(
        "/sessions", files={"room_scan": ("room.json", b"not json", "application/json")}
    )
    assert response.status_code == 400


def test_scan_with_no_walls_fails_session(tmp_path):
    client, _ = make_client(tmp_path)
    empty = json.dumps({"walls": [], "floors": []}).encode()
    body = client.post(
        "/sessions", files={"room_scan": ("room.json", empty, "application/json")}
    ).json()
    assert body["status"] == "failed"
    assert "error" in body["raw_metadata"]


def test_unknown_session_404(tmp_path):
    client, _ = make_client(tmp_path)
    assert client.get("/sessions/visit-00000000-000000-000000").status_code == 404


def test_path_traversal_session_id_rejected(tmp_path):
    client, _ = make_client(tmp_path)
    assert client.get("/sessions/..%2F..%2Fetc").status_code in (400, 404)


# --- console endpoints -------------------------------------------------------


def test_console_page_served(tmp_path):
    client, _ = make_client(tmp_path)
    response = client.get("/")
    assert response.status_code == 200
    assert "Build Pilot" in response.text
    assert "Processing pipeline" in response.text


def test_session_list_newest_first(tmp_path):
    client, _ = make_client(tmp_path)
    first = upload(client).json()["session_id"]
    second = upload(client).json()["session_id"]

    listed = client.get("/sessions").json()
    ids = [s["session_id"] for s in listed]
    assert set(ids) == {first, second}
    assert listed[0]["created_at"] >= listed[1]["created_at"]


def test_room_and_transcript_endpoints(tmp_path):
    client, _ = make_client(tmp_path)
    session_id = upload(client).json()["session_id"]

    room = client.get(f"/sessions/{session_id}/room")
    assert room.status_code == 200
    assert len(room.json()["walls"]) == 4

    transcript = client.get(f"/sessions/{session_id}/transcript")
    assert transcript.status_code == 200
    assert "Paint" in transcript.text


def test_photo_archive(tmp_path):
    client, store = make_client(tmp_path)
    session_id = upload(client).json()["session_id"]

    fake_jpeg = b"\xff\xd8\xff\xe0" + b"x" * 100
    for kind in ("before", "before", "after"):
        response = client.post(
            f"/sessions/{session_id}/photos",
            files={"photo": ("p.jpg", fake_jpeg, "image/jpeg")},
            data={"kind": kind},
        )
        assert response.status_code == 200

    photos_dir = store.session_dir(session_id) / "photos"
    assert sorted(p.name for p in photos_dir.iterdir()) == [
        "after-01.jpg",
        "before-01.jpg",
        "before-02.jpg",
    ]


def test_photo_invalid_kind_rejected(tmp_path):
    client, _ = make_client(tmp_path)
    session_id = upload(client).json()["session_id"]
    response = client.post(
        f"/sessions/{session_id}/photos",
        files={"photo": ("p.jpg", b"\xff\xd8data", "image/jpeg")},
        data={"kind": "during"},
    )
    assert response.status_code == 400


def test_transcript_404_when_no_audio(tmp_path):
    client, _ = make_client(tmp_path)
    session_id = upload(client, with_audio=False).json()["session_id"]
    assert client.get(f"/sessions/{session_id}/transcript").status_code == 404
