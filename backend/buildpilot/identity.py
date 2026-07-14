"""Contractor identity — the multi-tenant seam.

Every project in Build Pilot belongs to exactly one contractor. V1 ships
single-tenant, but the whole system already *routes by contractor* so that
per-contractor project sync (a documented near-term milestone) drops in without
touching the data model, the store, or the endpoints.

How resolution works today vs. later:

- Today (this module's default `ContractorResolver`): the phone declares its
  identity with an ``X-Contractor-Id`` header. When absent — pure-local Mac
  development, older app builds — it falls back to ``DEFAULT_CONTRACTOR_ID``.
  This is a *routing* signal, deliberately NOT a security boundary: in
  single-tenant mode there is nothing to protect between tenants.

- Later (a subclass wired in where real auth lives): the contractor is derived
  from *verified* per-contractor credentials, and the header is ignored. Every
  caller here already asks "who owns this?" through `resolve()`, so only this
  one class changes — `SessionStore`, the pipeline, and the routes are already
  contractor-aware.

Keeping this separate from `auth.py` is intentional: authentication answers
"is this request allowed to reach the API?"; identity answers "whose data is
it?". They converge when multi-tenant auth lands, and this seam is where.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from fastapi import Request

from buildpilot.models.session import DEFAULT_CONTRACTOR_ID

CONTRACTOR_HEADER = "X-Contractor-Id"

# Contractor ids are used verbatim as storage keys, so constrain them to a
# filesystem-safe, non-path-like alphabet. Anything else falls back to the
# default rather than raising — a malformed id must never fail a live visit.
_ID_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,64}$")


@dataclass(frozen=True)
class Contractor:
    """The owner of a project. A value object today; room to grow (display
    name, plan, entitlements) without changing call sites."""

    contractor_id: str


def normalize_contractor_id(raw: str | None) -> str:
    """Coerces an incoming id to a safe contractor id, or the default.

    Rejects path traversal and unexpected characters so an id can be trusted
    as a storage key. Returns DEFAULT_CONTRACTOR_ID for None/empty/invalid.
    """
    if not raw:
        return DEFAULT_CONTRACTOR_ID
    candidate = raw.strip()
    if candidate == ".." or not _ID_PATTERN.match(candidate):
        return DEFAULT_CONTRACTOR_ID
    return candidate


class ContractorResolver:
    """Maps an incoming request to the contractor that owns the work.

    The default single-tenant implementation trusts the ``X-Contractor-Id``
    header (see module docstring for why that is safe in V1). Swap this for a
    credential-deriving subclass to go multi-tenant.
    """

    def resolve(self, request: Request) -> Contractor:
        raw = request.headers.get(CONTRACTOR_HEADER)
        return Contractor(contractor_id=normalize_contractor_id(raw))


def current_contractor(request: Request) -> Contractor:
    """FastAPI dependency: the contractor that owns this request's project.

    Reads the resolver from app state so a deployment can install a stricter
    one without editing the routes.
    """
    resolver: ContractorResolver = getattr(
        request.app.state, "contractor_resolver", None
    ) or ContractorResolver()
    return resolver.resolve(request)
