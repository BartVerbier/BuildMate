"""Revision workflow tests: version → transcribe → merge → re-estimate →
deterministic deltas → restore. LLM merge is faked; estimator runs real."""

from buildpilot.models.session import PaintScope, RequirementExtraction

from tests.test_server_e2e import FakeTranscriber, make_client, upload


class RevisingExtractor:
    """Fake extractor whose revise() adds the ceiling back in."""

    def extract(self, transcript, room_context=None):
        return RequirementExtraction(
            scope_of_work=["Paint the walls"],
            exclusions=["Ceiling"],
            paint_scope=PaintScope(walls=True, ceiling=False),
        )

    def revise(self, current, transcript, room_context=None):
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
    # No Before photo archived → nothing for the phone to re-render.
    assert body["render_required"] is False

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


def test_revision_flags_render_when_before_photo_exists(tmp_path):
    """With a Before photo archived, a revision tells the phone to
    re-request the AI renders (the old ones no longer match the quote)."""
    client, _ = make_revision_client(tmp_path)
    session_id = upload(client).json()["session_id"]
    client.post(
        f"/sessions/{session_id}/photos",
        files={"photo": ("p.jpg", b"\xff\xd8\xff\xe0" + b"room" * 50, "image/jpeg")},
        data={"kind": "before"},
    )
    body = revise(client, session_id).json()
    assert body["render_required"] is True


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


def test_sequential_revisions_append_transcript_timeline(tmp_path):
    """Two spoken changes on the SAME visit (the reopened-visit voice workflow
    reuses this exact endpoint): the original transcript is preserved, each
    change is appended as its own timeline entry, prior quote versions are kept,
    the session_id never changes, and no duplicate session is created."""
    client, store = make_revision_client(tmp_path)
    original = upload(client).json()
    session_id = original["session_id"]
    session_dir = store.session_dir(session_id)

    # The original visit transcript, written at scan time.
    original_transcript = (session_dir / "transcript.txt").read_text()
    assert original_transcript.strip()

    # First spoken change, then a second — same session throughout.
    r1 = revise(client, session_id).json()
    assert r1["session"]["session_id"] == session_id
    assert r1["version"] == 2
    r2 = revise(client, session_id).json()
    assert r2["session"]["session_id"] == session_id
    assert r2["version"] == 3

    # The original transcript is NOT replaced.
    assert (session_dir / "transcript.txt").read_text() == original_transcript
    # Each spoken change is its own timeline entry (voice history preserved).
    assert (session_dir / "revision-01.txt").exists()
    assert (session_dir / "revision-02.txt").exists()
    # Prior quote versions preserved and enumerable.
    assert (session_dir / "versions" / "v01.json").exists()
    assert (session_dir / "versions" / "v02.json").exists()
    assert client.get(f"/sessions/{session_id}/versions").json() == [1, 2]

    # No duplicate session was created — exactly one session on disk.
    assert len(list(store.root.glob("*/session.json"))) == 1


def test_revise_requires_completed_quote(tmp_path):
    client, _ = make_revision_client(tmp_path)
    response = client.post(
        "/sessions/visit-00000000-000000-000000/revise",
        files={"audio": ("changes.m4a", b"x", "audio/mp4")},
    )
    assert response.status_code == 404


# --- ungrounded wall references (the 2026-08-16 money-bug) -------------------
# A revision like "paint only the wall with the TV" that the extractor cannot
# map to a wall id must NEVER silently price the whole room. The flag and the
# loud change line are the contract the app's warning card builds on.


class UngroundedWallExtractor:
    """Fake extractor whose revise() limits painting to a wall it cannot
    identify — no gaze context exists in a post-scan revision."""

    def extract(self, transcript, room_context=None):
        return RequirementExtraction(
            scope_of_work=["Paint the walls"], paint_scope=PaintScope()
        )

    def revise(self, current, transcript, room_context=None):
        updated = current.model_copy(update={
            "scope_of_work": ["Paint wall with TV and cabinets"],
            "paint_scope": PaintScope(walls=True, ceiling=False),
            "painted_wall_ids": [],
            "unresolved_wall_reference": "the wall with the TV",
        })
        return updated, ["Painting limited to the TV wall"]


def test_ungrounded_wall_reference_is_flagged_never_silent(tmp_path):
    client, _ = make_client(
        tmp_path,
        transcriber=FakeTranscriber(text="Only the wall with the TV please."),
        extractor=UngroundedWallExtractor(),
    )
    session_id = upload(client).json()["session_id"]
    body = revise(client, session_id).json()

    requirements = body["session"]["requirements"]
    assert requirements["unresolved_wall_reference"] == "the wall with the TV"
    assert requirements["painted_wall_ids"] == []
    # The change list says, in words, that the quote still covers ALL walls.
    assert any("ALL walls" in c for c in body["changes"])


class BogusWallIdExtractor(UngroundedWallExtractor):
    """The model confidently names walls that don't exist in the scan."""

    def revise(self, current, transcript, room_context=None):
        updated = current.model_copy(update={
            "painted_wall_ids": ["w97", "w98"],
        })
        return updated, ["Painting limited to two walls"]


def test_bogus_wall_ids_trigger_the_deterministic_backstop(tmp_path):
    client, _ = make_client(
        tmp_path,
        transcriber=FakeTranscriber(text="Just those two walls."),
        extractor=BogusWallIdExtractor(),
    )
    session_id = upload(client).json()["session_id"]
    body = revise(client, session_id).json()

    requirements = body["session"]["requirements"]
    assert requirements["painted_wall_ids"] == []  # bogus ids dropped
    assert requirements["unresolved_wall_reference"]  # backstop flagged it
    assert any("ALL walls" in c for c in body["changes"])


class WholeRoomExtractor(UngroundedWallExtractor):
    """An explicit whole-room change: empty ids are CORRECT here."""

    def revise(self, current, transcript, room_context=None):
        updated = current.model_copy(update={
            "painted_wall_ids": [],
            "unresolved_wall_reference": None,
        })
        return updated, ["Painting every wall again"]


def test_explicit_whole_room_change_raises_no_false_alarm(tmp_path):
    client, _ = make_client(
        tmp_path,
        transcriber=FakeTranscriber(text="Actually paint everything."),
        extractor=WholeRoomExtractor(),
    )
    session_id = upload(client).json()["session_id"]
    body = revise(client, session_id).json()

    requirements = body["session"]["requirements"]
    assert requirements["unresolved_wall_reference"] is None
    assert not any("ALL walls" in c for c in body["changes"])


class BogusInitialIdsExtractor:
    """Initial extraction (live scan) naming nonexistent walls — the
    pipeline's filter must flag, not silently widen to the whole room."""

    def extract(self, transcript, room_context=None):
        return RequirementExtraction(
            scope_of_work=["Paint that wall"],
            paint_scope=PaintScope(),
            painted_wall_ids=["w42"],
        )

    def revise(self, current, transcript, room_context=None):
        raise AssertionError("not used")


def test_pipeline_filter_flags_dropped_ids_on_initial_extraction(tmp_path):
    client, _ = make_client(
        tmp_path,
        transcriber=FakeTranscriber(text="Paint that wall over there."),
        extractor=BogusInitialIdsExtractor(),
    )
    body = upload(client).json()
    requirements = body["requirements"]
    assert requirements["painted_wall_ids"] == []
    assert requirements["unresolved_wall_reference"]
