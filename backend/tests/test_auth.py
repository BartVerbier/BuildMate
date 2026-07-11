"""Bearer-token authentication tests.

Auth is disabled when BUILDPILOT_API_TOKEN is unset (local development) and
enforced when it is set (public deployment). /health stays open either way.
"""

from fastapi.testclient import TestClient

from buildpilot.auth import TOKEN_ENV
from tests.test_server_e2e import FIXTURE, make_client

TOKEN = "test-secret-0123456789abcdef"


def _upload(client, headers=None):
    return client.post(
        "/sessions",
        files={"room_scan": ("room.json", FIXTURE.read_bytes(), "application/json")},
        headers=headers or {},
    )


def test_auth_disabled_without_token_env(tmp_path, monkeypatch):
    monkeypatch.delenv(TOKEN_ENV, raising=False)
    client, _ = make_client(tmp_path)
    # No Authorization header, no token configured → open (local dev).
    assert _upload(client).status_code == 200
    assert client.get("/health").json()["authentication"] == "disabled"


def test_protected_endpoint_rejects_missing_token(tmp_path, monkeypatch):
    monkeypatch.setenv(TOKEN_ENV, TOKEN)
    client, _ = make_client(tmp_path)
    assert _upload(client).status_code == 401


def test_protected_endpoint_rejects_wrong_token(tmp_path, monkeypatch):
    monkeypatch.setenv(TOKEN_ENV, TOKEN)
    client, _ = make_client(tmp_path)
    resp = _upload(client, headers={"Authorization": "Bearer not-the-token"})
    assert resp.status_code == 401


def test_protected_endpoint_accepts_correct_token(tmp_path, monkeypatch):
    monkeypatch.setenv(TOKEN_ENV, TOKEN)
    client, _ = make_client(tmp_path)
    resp = _upload(client, headers={"Authorization": f"Bearer {TOKEN}"})
    assert resp.status_code == 200


def test_health_is_open_even_when_auth_enabled(tmp_path, monkeypatch):
    monkeypatch.setenv(TOKEN_ENV, TOKEN)
    client, _ = make_client(tmp_path)
    health = client.get("/health")
    assert health.status_code == 200
    assert health.json()["authentication"] == "enabled"


def test_get_endpoints_are_also_protected(tmp_path, monkeypatch):
    """Not just billable POSTs — customer data behind GET is protected too."""
    monkeypatch.setenv(TOKEN_ENV, TOKEN)
    client, _ = make_client(tmp_path)
    assert client.get("/sessions").status_code == 401
    assert client.get(
        "/sessions", headers={"Authorization": f"Bearer {TOKEN}"}
    ).status_code == 200
