"""HTTP-level tests: contractor ownership, health signals, confidence report."""

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


class FakeTranscriber:
    def transcribe(self, audio_path):
        return "Paint the walls."


class FakeExtractor:
    def extract(self, transcript, room_context=None):
        return RequirementExtraction(
            scope_of_work=["Paint the walls"],
            paint_scope=PaintScope(walls=True, ceiling=True),
        )


def make_client(tmp_path):
    pipeline = VisitPipeline(
        measurement_engine=RoomPlanMeasurementEngine(),
        transcriber=FakeTranscriber(),
        extractor=FakeExtractor(),
        estimator=DeterministicEstimator(),
        company_profile=DEFAULT_COMPANY_PROFILE,
    )
    store = SessionStore(tmp_path / "sessions")
    return TestClient(create_app(pipeline=pipeline, store=store))


def _upload(client, contractor=None):
    headers = {CONTRACTOR_HEADER: contractor} if contractor else {}
    files = {"room_scan": ("room.json", FIXTURE.read_bytes(), "application/json")}
    return client.post("/sessions", files=files, headers=headers)


def test_upload_tags_the_owning_contractor(tmp_path):
    client = make_client(tmp_path)
    body = _upload(client, contractor="acme").json()
    assert body["contractor_id"] == "acme"


def test_a_contractor_cannot_read_anothers_session(tmp_path):
    client = make_client(tmp_path)
    session_id = _upload(client, contractor="acme").json()["session_id"]

    assert client.get(
        f"/sessions/{session_id}", headers={CONTRACTOR_HEADER: "acme"}
    ).status_code == 200
    # a different contractor — and the header-less console-less default — get 404
    assert client.get(
        f"/sessions/{session_id}", headers={CONTRACTOR_HEADER: "rival"}
    ).status_code == 404
    assert client.get(f"/sessions/{session_id}").status_code == 404


def test_session_list_is_scoped_to_the_contractor(tmp_path):
    client = make_client(tmp_path)
    _upload(client, contractor="acme")
    _upload(client, contractor="rival")

    acme = client.get("/sessions", headers={CONTRACTOR_HEADER: "acme"}).json()
    rival = client.get("/sessions", headers={CONTRACTOR_HEADER: "rival"}).json()
    assert len(acme) == 1
    assert len(rival) == 1
    assert acme[0]["contractor_id"] == "acme"


def test_health_reports_visualizer_availability(tmp_path):
    client = make_client(tmp_path)
    body = client.get("/health").json()
    assert "visualizer_available" in body
    assert isinstance(body["visualizer_available"], bool)


def test_health_reports_version(tmp_path):
    client = make_client(tmp_path)
    body = client.get("/health").json()
    assert "version" in body
    assert body["version"]["commit"]  # non-empty commit identifier


def test_completed_session_carries_a_confidence_report(tmp_path):
    client = make_client(tmp_path)
    body = _upload(client, contractor="acme").json()
    assert body["status"] == "completed"

    report = body["confidence"]
    assert 0 <= report["score"] <= 100
    assert report["band"] in ("high", "medium", "low")
    assert report["signals"], "expected at least one confidence signal"
    # signals render generically: each has the display contract
    for signal in report["signals"]:
        assert {"key", "label", "score", "weight", "detail"} <= signal.keys()
