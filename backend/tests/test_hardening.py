"""Field-hardening tests: crash protection, diagnostics, and the
cross-device raw_metadata contract."""

import json
from pathlib import Path

from buildpilot.config import DEFAULT_COMPANY_PROFILE
from buildpilot.models.session import Session
from buildpilot.pipeline import VisitPipeline
from buildpilot.pipelines.estimator import DeterministicEstimator
from buildpilot.pipelines.measurement import RoomPlanMeasurementEngine
from buildpilot.server import create_app
from buildpilot.session_store import SessionStore
from fastapi.testclient import TestClient

from tests.test_server_e2e import FakeExtractor, FakeTranscriber, make_client, upload

FIXTURE = Path(__file__).parent / "fixtures" / "synthetic_room_5x3.json"


class ExplodingEstimator:
    def estimate(self, measurements, requirements, company_profile):
        raise RuntimeError("simulated crash inside a pipeline stage")


def test_unexpected_stage_crash_yields_failed_session_not_500(tmp_path):
    """Crash protection: a broken stage must produce a clean `failed`
    session (which the phone renders in painter language), never an HTTP 500."""
    pipeline = VisitPipeline(
        measurement_engine=RoomPlanMeasurementEngine(),
        transcriber=FakeTranscriber(),
        extractor=FakeExtractor(),
        estimator=ExplodingEstimator(),
        company_profile=DEFAULT_COMPANY_PROFILE,
    )
    store = SessionStore(tmp_path / "sessions")
    client = TestClient(create_app(pipeline=pipeline, store=store))

    response = upload(client)
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "failed"
    assert "unexpected error" in body["raw_metadata"]["error"]

    # The session record on disk is intact and reloadable.
    reloaded = store.load(body["session_id"])
    assert reloaded is not None
    assert reloaded.status.value == "failed"


def test_raw_metadata_values_are_always_strings(tmp_path):
    """CROSS-DEVICE CONTRACT: the iPhone decodes raw_metadata as
    [String: String]. A single non-string value would make every session
    undecodable on the phone. This test guards the whole surface."""
    client, store = make_client(tmp_path)
    body = upload(client).json()

    session_file = store.session_dir(body["session_id"]) / "session.json"
    raw_metadata = json.loads(session_file.read_text())["raw_metadata"]
    assert raw_metadata, "expected diagnostics in raw_metadata"
    for key, value in raw_metadata.items():
        assert isinstance(value, str), f"raw_metadata[{key!r}] is {type(value).__name__}, not str"


def test_stage_timings_recorded(tmp_path):
    client, _ = make_client(tmp_path)
    body = upload(client).json()

    metadata = body["raw_metadata"]
    for stage in ("measure", "transcribe", "extract", "estimate"):
        key = f"timing_{stage}_s"
        assert key in metadata, f"missing {key}"
        assert float(metadata[key]) >= 0.0
    assert metadata["transcript_chars"].isdigit()


def test_degraded_stages_record_reasons(tmp_path):
    from tests.test_server_e2e import FailingExtractor, FailingTranscriber

    client, _ = make_client(tmp_path, transcriber=FailingTranscriber())
    body = upload(client).json()
    assert "transcription_error" in body["raw_metadata"]

    client, _ = make_client(tmp_path, extractor=FailingExtractor())
    body = upload(client).json()
    assert "extraction_error" in body["raw_metadata"]


def test_session_save_is_atomic(tmp_path):
    """save() writes via tmp-file + rename; no .tmp remnant, valid JSON."""
    store = SessionStore(tmp_path / "sessions")
    session = store.create_session(FIXTURE.read_bytes(), None)
    session_dir = store.session_dir(session.session_id)

    store.save(session)
    assert not list(session_dir.glob("*.tmp"))
    assert Session.model_validate_json((session_dir / "session.json").read_text())


def test_measurement_survives_malformed_surfaces(tmp_path):
    """Defensive parsing: junk surfaces must not crash the engine."""
    room = json.loads(FIXTURE.read_text())
    room["walls"].append({"identifier": "junk", "dimensions": None, "transform": None})
    room["doors"].append({"identifier": "junk2", "dimensions": [1.0]})
    room["floors"].append({"identifier": "junk3", "polygonCorners": [[0, 0]]})

    result = RoomPlanMeasurementEngine().measure(room)
    assert result.gross_wall_area_m2 == 40.0  # junk wall contributes zero
    assert result.floor_area_m2 == 15.0
