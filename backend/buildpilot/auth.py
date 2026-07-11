"""Bearer-token authentication for the BuildMate backend.

The threat this closes: once the backend is reachable on the public Internet
(Railway), its AI endpoints spend real money per call (Claude extraction,
Vertex/Gemini renders). An unauthenticated public URL is an open, billable
API. This adds a single shared secret the phone must present.

Design:
- The expected token lives ONLY in the environment (BUILDPILOT_API_TOKEN),
  never in the code or the repo.
- When the variable is UNSET, authentication is DISABLED. That is the local
  development default — the Mac on a trusted LAN stays zero-friction, and
  every existing test keeps passing without a token.
- When the variable is SET (Railway, and any other public deployment), every
  request except the health check must carry `Authorization: Bearer <token>`;
  anything else gets 401.

Rotation: set a new BUILDPILOT_API_TOKEN value in the deployment environment
and the matching value on the phone. There is no persisted state, so a
rotation takes effect on the next request — no migration, no restart data.
"""

from __future__ import annotations

import hmac
import os

from fastapi import Header, HTTPException, Request

TOKEN_ENV = "BUILDPILOT_API_TOKEN"
# The health endpoint must stay open so Railway's platform health check
# (which cannot send a bearer token) can probe the service.
_OPEN_PATHS = frozenset({"/health"})


def auth_enabled() -> bool:
    """True when a token is configured — i.e. this is a protected deployment."""
    return bool(os.environ.get(TOKEN_ENV))


def require_token(request: Request, authorization: str | None = Header(default=None)) -> None:
    """FastAPI dependency: enforce the bearer token on protected requests.

    No-op when BUILDPILOT_API_TOKEN is unset (local development) or for the
    open health path. Uses a constant-time comparison so the check does not
    leak the token through timing.
    """
    expected = os.environ.get(TOKEN_ENV)
    if not expected:
        return  # local development: authentication disabled
    if request.url.path in _OPEN_PATHS:
        return

    if authorization is None or not authorization.startswith("Bearer "):
        raise HTTPException(
            status_code=401,
            detail="Missing bearer token",
            headers={"WWW-Authenticate": "Bearer"},
        )
    provided = authorization[len("Bearer "):].strip()
    if not hmac.compare_digest(provided, expected):
        raise HTTPException(
            status_code=401,
            detail="Invalid bearer token",
            headers={"WWW-Authenticate": "Bearer"},
        )
