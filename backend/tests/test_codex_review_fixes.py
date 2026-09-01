"""Regression pins for the 2026-09-01 Codex review findings.

1-2. A rejected /reestimate or failed /revise must leave NO version file —
     before the fix, validation/transcription errors after the version write
     left a spurious restorable version behind.
3.   BUILDPILOT_KNOWN_CONTRACTORS turns the client-controlled contractor
     header from open routing into an allowlist on public deployments.
"""

from buildpilot.pipelines.transcription import TranscriptionError
from tests.test_revision import RevisingExtractor, make_revision_client
from tests.test_server_e2e import FakeTranscriber, make_client, upload


def versions_on_disk(store, session_id):
    versions_dir = store.session_dir(session_id) / "versions"
    return sorted(p.name for p in versions_dir.glob("v*.json")) if versions_dir.exists() else []


def test_rejected_reestimate_leaves_no_version(tmp_path):
    client, store = make_revision_client(tmp_path)
    session_id = upload(client).json()["session_id"]
    response = client.post(
        f"/sessions/{session_id}/reestimate",
        json={"walls": [{"wall_id": "w99", "width_m": 2.0}]},
    )
    assert response.status_code == 422
    assert versions_on_disk(store, session_id) == []
    # And the next successful edit is version 2, unpolluted.
    ok = client.post(f"/sessions/{session_id}/reestimate",
                     json={"measurements_verified": True})
    assert ok.json()["version"] == 2
    assert versions_on_disk(store, session_id) == ["v01.json"]


class ExplodingTranscriber(FakeTranscriber):
    def transcribe(self, path):
        raise TranscriptionError("microphone gremlins")


def test_failed_revision_leaves_no_version(tmp_path):
    client, store = make_client(
        tmp_path, transcriber=ExplodingTranscriber(), extractor=RevisingExtractor()
    )
    session_id = upload(client).json()["session_id"]
    response = client.post(
        f"/sessions/{session_id}/revise",
        files={"audio": ("c.m4a", b"fake", "audio/mp4")},
    )
    assert response.status_code == 422
    assert versions_on_disk(store, session_id) == []


def test_contractor_allowlist(tmp_path, monkeypatch):
    monkeypatch.setenv("BUILDPILOT_KNOWN_CONTRACTORS", "bart-co")
    client, _ = make_revision_client(tmp_path)
    # Known id and the default both work.
    assert client.get("/sessions", headers={"X-Contractor-Id": "bart-co"}).status_code == 200
    assert client.get("/sessions").status_code == 200
    # Unknown ids are refused, not silently routed.
    denied = client.get("/sessions", headers={"X-Contractor-Id": "somebody-else"})
    assert denied.status_code == 403


def test_allowlist_off_by_default(tmp_path, monkeypatch):
    monkeypatch.delenv("BUILDPILOT_KNOWN_CONTRACTORS", raising=False)
    client, _ = make_revision_client(tmp_path)
    assert client.get("/sessions", headers={"X-Contractor-Id": "anyone"}).status_code == 200
