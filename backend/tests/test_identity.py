"""Contractor identity: id normalisation, request resolution, store ownership."""

from types import SimpleNamespace

from buildpilot.identity import (
    CONTRACTOR_HEADER,
    ContractorResolver,
    normalize_contractor_id,
)
from buildpilot.models.session import DEFAULT_CONTRACTOR_ID
from buildpilot.session_store import SessionStore

ROOM = b'{"walls": []}'


def test_normalize_falls_back_to_default():
    for bad in (None, "", "   ", "..", "a/b", "a\\b", "x" * 65, "bad id!"):
        assert normalize_contractor_id(bad) == DEFAULT_CONTRACTOR_ID


def test_normalize_accepts_safe_ids():
    assert normalize_contractor_id("acme-123") == "acme-123"
    assert normalize_contractor_id("Acme_Co.42") == "Acme_Co.42"
    assert normalize_contractor_id("  spaced  ") == "spaced"


def _request(headers):
    return SimpleNamespace(headers=headers)


def test_resolver_reads_header_or_defaults():
    resolver = ContractorResolver()
    assert resolver.resolve(_request({CONTRACTOR_HEADER: "acme"})).contractor_id == "acme"
    assert resolver.resolve(_request({})).contractor_id == DEFAULT_CONTRACTOR_ID
    # a spoofed path-like id is neutralised, never trusted as a storage key
    assert resolver.resolve(
        _request({CONTRACTOR_HEADER: "../etc"})
    ).contractor_id == DEFAULT_CONTRACTOR_ID


def test_store_enforces_ownership(tmp_path):
    store = SessionStore(tmp_path / "sessions")
    session = store.create_session(ROOM, None, contractor_id="acme")

    # the owner can load it; another contractor cannot even see it exists
    assert store.load(session.session_id, "acme") is not None
    assert store.load(session.session_id, "rival") is None
    # no contractor given (single-tenant console) skips the check
    assert store.load(session.session_id, None) is not None


def test_store_list_filters_by_contractor(tmp_path):
    store = SessionStore(tmp_path / "sessions")
    store.create_session(ROOM, None, contractor_id="acme")
    store.create_session(ROOM, None, contractor_id="rival")

    assert len(store.list_sessions("acme")) == 1
    assert len(store.list_sessions("rival")) == 1
    assert len(store.list_sessions(None)) == 2  # console sees all


def test_existing_sessions_backfill_default_contractor(tmp_path):
    # A session created without a contractor id (older store call) is owned by
    # the default contractor, so nothing is orphaned.
    store = SessionStore(tmp_path / "sessions")
    session = store.create_session(ROOM, None)
    assert session.contractor_id == DEFAULT_CONTRACTOR_ID
    assert store.load(session.session_id, DEFAULT_CONTRACTOR_ID) is not None
