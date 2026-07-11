"""Visualization endpoint tests (adapter faked; instruction builder real)."""

from pathlib import Path

from fastapi.testclient import TestClient

from buildpilot.config import DEFAULT_COMPANY_PROFILE
from buildpilot.models.session import PaintScope, RequirementExtraction
from buildpilot.pipeline import VisitPipeline
from buildpilot.pipelines.estimator import DeterministicEstimator
from buildpilot.pipelines.measurement import RoomPlanMeasurementEngine
from buildpilot.pipelines.visualization import (
    GeminiVisualizer,
    VisualizationError,
    build_instruction,
)
from buildpilot.server import create_app
from buildpilot.session_store import SessionStore

from tests.test_server_e2e import FakeExtractor, FakeTranscriber, upload

FAKE_RENDER = b"\xff\xd8\xff\xe0RENDERED"


class FakeVisualizer:
    def __init__(self):
        self.stages = []

    def render(self, photo_jpeg, requirements, stage="finished"):
        assert photo_jpeg.startswith(b"\xff\xd8")
        self.stages.append(stage)
        return FAKE_RENDER


class UnavailableVisualizer:
    def render(self, photo_jpeg, requirements, stage="finished"):
        raise VisualizationError("no GEMINI_API_KEY configured")


def make_client(tmp_path, visualizer):
    pipeline = VisitPipeline(
        measurement_engine=RoomPlanMeasurementEngine(),
        transcriber=FakeTranscriber(),
        extractor=FakeExtractor(),
        estimator=DeterministicEstimator(),
        company_profile=DEFAULT_COMPANY_PROFILE,
    )
    store = SessionStore(tmp_path / "sessions")
    return TestClient(create_app(pipeline=pipeline, store=store, visualizer=visualizer)), store


def archive_before_photo(client, session_id):
    return client.post(
        f"/sessions/{session_id}/photos",
        files={"photo": ("p.jpg", b"\xff\xd8\xff\xe0" + b"room" * 50, "image/jpeg")},
        data={"kind": "before"},
    )


def test_visualize_renders_and_archives(tmp_path):
    client, store = make_client(tmp_path, FakeVisualizer())
    session_id = upload(client).json()["session_id"]
    assert archive_before_photo(client, session_id).status_code == 200

    response = client.post(f"/sessions/{session_id}/visualize")
    assert response.status_code == 200
    assert response.headers["content-type"] == "image/jpeg"
    assert response.content == FAKE_RENDER
    # archived alongside the photos as part of the permanent record
    assert (store.session_dir(session_id) / "photos" / "visualization-01.jpg").exists()


def test_visualize_refuses_degraded_requirements(tmp_path):
    """Estimate and visualization must agree: no render from default scope."""
    from tests.test_server_e2e import FailingExtractor, make_client as make_e2e_client

    client, _ = make_e2e_client(tmp_path, extractor=FailingExtractor())
    session_id = upload(client).json()["session_id"]
    archive_before_photo(client, session_id)
    response = client.post(f"/sessions/{session_id}/visualize")
    assert response.status_code == 409
    assert "refusing" in response.json()["detail"]


def test_visualize_preparation_stage(tmp_path):
    """stage=preparation renders the prep view and archives it separately."""
    visualizer = FakeVisualizer()
    client, store = make_client(tmp_path, visualizer)
    session_id = upload(client).json()["session_id"]
    archive_before_photo(client, session_id)

    response = client.post(f"/sessions/{session_id}/visualize?stage=preparation")
    assert response.status_code == 200
    assert visualizer.stages == ["preparation"]
    assert (store.session_dir(session_id) / "photos" / "preparation-01.jpg").exists()

    assert client.post(f"/sessions/{session_id}/visualize?stage=demolition").status_code == 400


def test_visualize_requires_before_photo(tmp_path):
    client, _ = make_client(tmp_path, FakeVisualizer())
    session_id = upload(client).json()["session_id"]
    assert client.post(f"/sessions/{session_id}/visualize").status_code == 409


def test_visualize_degrades_when_unavailable(tmp_path):
    client, _ = make_client(tmp_path, UnavailableVisualizer())
    session_id = upload(client).json()["session_id"]
    archive_before_photo(client, session_id)
    response = client.post(f"/sessions/{session_id}/visualize")
    assert response.status_code == 503
    assert "GEMINI_API_KEY" in response.json()["detail"]


def test_instruction_is_deterministic_and_faithful():
    requirements = RequirementExtraction(
        scope_of_work=["Paint the walls light grey"],
        exclusions=["Ceiling"],
        preparation_required=["Repair the crack above the window"],
        special_notes=["Washable eggshell finish"],
        paint_scope=PaintScope(walls=True, ceiling=False),
    )
    a = build_instruction(requirements)
    b = build_instruction(requirements)
    assert a == b
    assert "Paint the walls light grey" in a
    assert "Do NOT change: Ceiling" in a
    assert "Repair the crack above the window" in a
    assert "same room" in a
    assert "furniture" in a
    # Whole-wall framing rules (Sprint 6): never crop tighter than source.
    assert "full field of view" in a
    assert "architectural photography" in a


def test_preparation_instruction_is_deterministic():
    requirements = RequirementExtraction(scope_of_work=["Paint the walls"])
    a = build_instruction(requirements, "preparation")
    assert a == build_instruction(requirements, "preparation")
    assert "dust sheets" in a
    assert "no new paint" in a.lower()
    assert "full field of view" in a
    # Prep view is scope-independent: the room is protected, not painted.
    assert "Paint the walls" not in a


def test_gemini_visualizer_requires_credentials(monkeypatch):
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.delenv("GOOGLE_CLOUD_PROJECT", raising=False)
    assert GeminiVisualizer.is_available() is False
    try:
        GeminiVisualizer().render(b"\xff\xd8", RequirementExtraction())
        raise AssertionError("expected VisualizationError")
    except VisualizationError as exc:
        assert "GEMINI_API_KEY" in str(exc)


def test_vertex_mode_selected_when_project_set(monkeypatch):
    """With a GCP project configured, the adapter targets Vertex AI and
    reports missing service-account credentials clearly."""
    monkeypatch.setenv("GOOGLE_CLOUD_PROJECT", "test-project")
    monkeypatch.delenv("GOOGLE_APPLICATION_CREDENTIALS", raising=False)
    monkeypatch.setenv("GOOGLE_CLOUD_LOCATION", "global")
    assert GeminiVisualizer.is_available() is True
    GeminiVisualizer._vertex_credentials = None
    try:
        GeminiVisualizer().render(b"\xff\xd8", RequirementExtraction())
        raise AssertionError("expected VisualizationError")
    except VisualizationError as exc:
        assert "Vertex credentials" in str(exc) or "google-auth" in str(exc)
