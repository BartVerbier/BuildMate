"""Revision workflow tests: version → transcribe → merge → re-estimate →
deterministic deltas → restore. LLM merge is faked; estimator runs real."""

from buildpilot.models.session import PaintScope, RequirementExtraction

from tests.test_server_e2e import FakeTranscriber, make_client, upload


class RevisingExtractor:
    """Fake extractor whose revise() adds the ceiling back in."""

    def extract(self, transcript):
        return RequirementExtraction(
            scope_of_work=["Paint the walls"],
            exclusions=["Ceiling"],
            paint_scope=PaintScope(walls=True, ceiling=False),
        )

    def revise(self, current, transcript):
        assert "ceiling" in transcript.lower()
        updated = current.model_copy(
            update={
                "scope_of_work": current.scope_of_work + ["Paint the ceiling"],
                "exclusions": [],
                "paint_scope": PaintScope(walls=True, ceiling=True),
            }
        )
        return updated, ["Ceiling painting added"]


def make_revision_client(tmp_path):
    return make_client(
        tmp_path,
        transcriber=FakeTranscriber(text="I'd like the ceiling painted too."),
        extractor=RevisingExtractor(),
    )


def revise(client, session_id):
    return client.post(
        f"/sessions/{session_id}/revise",
        files={"audio": ("changes.m4a", b"fake-revision-audio", "audio/mp4")},
    )


def test_revision_merges_and_reprices(tmp_path):
    client, store = make_revision_client(tmp_path)
    original = upload(client).json()
    session_id = original["session_id"]

    response = revise(client, session_id)
    assert response.status_code == 200
    body = response.json()

    # LLM change + deterministic price deltas
    assert "Ceiling painting added" in body["changes"]
    assert any(c.startswith("Total +") for c in body["changes"])
    assert body["version"] == 2

    # Ceiling now included: 37 + 15 = 52 m2 → the original walls-only quote grew
    updated = body["session"]
    assert updated["requirements"]["paint_scope"]["ceiling"] is True
    assert (
        updated["estimate"]["suggested_quotation_eur"]
        > original["estimate"]["suggested_quotation_eur"]
    )

    # Version 1 preserved on disk with the original estimate
    v1 = store.session_dir(session_id) / "versions" / "v01.json"
    assert v1.exists()
    assert str(original["estimate"]["suggested_quotation_eur"]) in v1.read_text()
    # Revision artifacts archived
    assert (store.session_dir(session_id) / "revision-01.txt").exists()


def test_restore_previous_version(tmp_path):
    client, _ = make_revision_client(tmp_path)
    original = upload(client).json()
    session_id = original["session_id"]
    revise(client, session_id)

    versions = client.get(f"/sessions/{session_id}/versions").json()
    assert versions == [1]

    restored = client.post(f"/sessions/{session_id}/versions/1/restore")
    assert restored.status_code == 200
    body = restored.json()
    assert body["estimate"]["suggested_quotation_eur"] == original["estimate"]["suggested_quotation_eur"]
    assert body["requirements"]["paint_scope"]["ceiling"] is False
    assert body["raw_metadata"]["restored_from"] == "1"
    # Restore itself created a new version (it's reversible)
    assert client.get(f"/sessions/{session_id}/versions").json() == [1, 2]


def test_revise_requires_completed_quote(tmp_path):
    client, _ = make_revision_client(tmp_path)
    response = client.post(
        "/sessions/visit-00000000-000000-000000/revise",
        files={"audio": ("changes.m4a", b"x", "audio/mp4")},
    )
    assert response.status_code == 404
