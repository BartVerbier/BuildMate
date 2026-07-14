"""Reproduction + regression guard for the Before -> After visualize pipeline.

Traces the exact request sequence the phone makes and asserts each gate, so a
regression in the visualization path fails a test instead of silently producing
no After image.
"""

from pathlib import Path

from fastapi.testclient import TestClient

from buildpilot.config import DEFAULT_COMPANY_PROFILE
from buildpilot.identity import CONTRACTOR_HEADER
from buildpilot.models.session import PaintScope, RequirementExtraction
from buildpilot.pipeline import VisitPipeline
from buildpilot.pipelines.estimator import DeterministicEstimator
from buildpilot.pipelines.measurement import RoomPlanMeasurementEngine
from buildpilot.server import create_app
from buildpilot.session_store import SessionStore

FIXTURE = Path(__file__).parent / "fixtures" / "synthetic_room_5x3.json"
JPEG = b"\xff\xd8\xff\xe0" + b"x" * 200


class FakeTranscriber:
    def transcribe(self, audio_path):
        return "Paint the walls sage green, leave the ceiling."


class FakeExtractor:
    # Returns a real extraction → transcript_available stays True.
    def extract(self, transcript, room_context=None):
        return RequirementExtraction(
            scope_of_work=["Paint the walls sage green"],
            paint_scope=PaintScope(walls=True, ceiling=False),
        )


class FakeVisualizer:
    def __init__(self):
        self.calls = []

    def render(self, image_bytes, requirements, stage):
        self.calls.append(stage)
        return b"\xff\xd8\xff\xe0" + b"render" * 20

    @staticmethod
    def is_available():
        return True


def make_client(tmp_path, extractor=None, visualizer=None):
    pipeline = VisitPipeline(
        measurement_engine=RoomPlanMeasurementEngine(),
        transcriber=FakeTranscriber(),
        extractor=extractor or FakeExtractor(),
        estimator=DeterministicEstimator(),
        company_profile=DEFAULT_COMPANY_PROFILE,
    )
    store = SessionStore(tmp_path / "sessions")
    viz = visualizer or FakeVisualizer()
    return TestClient(create_app(pipeline=pipeline, store=store, visualizer=viz)), viz


def _create(client, contractor="acme"):
    files = {
        "room_scan": ("room.json", FIXTURE.read_bytes(), "application/json"),
        "audio": ("visit.m4a", b"fake-audio", "audio/mp4"),
    }
    return client.post("/sessions", files=files, headers={CONTRACTOR_HEADER: contractor})


def _archive_before(client, sid, contractor="acme"):
    return client.post(
        f"/sessions/{sid}/photos",
        files={"photo": ("b.jpg", JPEG, "image/jpeg")},
        data={"kind": "before"},
        headers={CONTRACTOR_HEADER: contractor},
    )


def test_full_before_to_after_pipeline_succeeds(tmp_path):
    """The happy path: same contractor throughout, good transcript, Before
    archived → /visualize returns the After image."""
    client, viz = make_client(tmp_path)
    created = _create(client)
    assert created.status_code == 200
    sid = created.json()["session_id"]
    assert created.json()["requirements"]["transcript_available"] is True

    assert _archive_before(client, sid).status_code == 200

    r = client.post(
        f"/sessions/{sid}/visualize?stage=finished",
        headers={CONTRACTOR_HEADER: "acme"},
    )
    assert r.status_code == 200, r.text
    assert r.headers["content-type"] == "image/jpeg"
    assert viz.calls == ["finished"]


def test_visualize_blocked_when_contractor_mismatch(tmp_path):
    """Regression guard for M1 ownership: a DIFFERENT contractor (or the
    header-less default when the session is owned by someone else) gets 404,
    NOT a render. Confirms ownership can silently blank the After if the phone
    ever sent an inconsistent contractor id."""
    client, _ = make_client(tmp_path)
    sid = _create(client, contractor="acme").json()["session_id"]
    _archive_before(client, sid, contractor="acme")

    assert client.post(
        f"/sessions/{sid}/visualize", headers={CONTRACTOR_HEADER: "rival"}
    ).status_code == 404
    assert client.post(f"/sessions/{sid}/visualize").status_code == 404


def test_visualize_409_when_before_not_archived(tmp_path):
    """If the Before photo never reached the backend, /visualize refuses —
    even though the phone shows its local copy."""
    client, _ = make_client(tmp_path)
    sid = _create(client).json()["session_id"]
    r = client.post(
        f"/sessions/{sid}/visualize", headers={CONTRACTOR_HEADER: "acme"}
    )
    assert r.status_code == 409
    assert "before" in r.text.lower()


def test_visualize_409_when_transcript_unavailable(tmp_path):
    """The agreement guard: degraded requirements (no real transcript) refuse
    to render. This is the most likely 'inconsistent' cause in the field."""
    class DegradingExtractor:
        def extract(self, transcript, room_context=None):
            from buildpilot.pipelines.extraction import ExtractionError
            raise ExtractionError("no API key")

    client, _ = make_client(tmp_path, extractor=DegradingExtractor())
    sid = _create(client).json()["session_id"]
    _archive_before(client, sid)
    r = client.post(
        f"/sessions/{sid}/visualize", headers={CONTRACTOR_HEADER: "acme"}
    )
    assert r.status_code == 409
    assert "conversation" in r.text.lower()
