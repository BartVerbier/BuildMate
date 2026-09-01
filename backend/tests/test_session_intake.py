"""Upload-time intake: the contractor's pricing snapshot and client metadata.

Pins the two halves of the (previously silently dropped) upload contract:
the phone's company_profile actually prices the visit, and client_metadata
(e.g. the recording-consent confirmation) lands namespaced in raw_metadata.
"""

import json

from tests.test_server_e2e import FIXTURE, make_client


def upload_with(client, *, profile: dict | None = None, metadata: dict | None = None,
                raw_profile: str | None = None, raw_metadata: str | None = None):
    files = {"room_scan": ("room.json", FIXTURE.read_bytes(), "application/json")}
    data = {}
    if profile is not None:
        data["company_profile"] = json.dumps(profile)
    if raw_profile is not None:
        data["company_profile"] = raw_profile
    if metadata is not None:
        data["client_metadata"] = json.dumps(metadata)
    if raw_metadata is not None:
        data["client_metadata"] = raw_metadata
    return client.post("/sessions", files=files, data=data)


PHONE_PROFILE = {
    # What the app actually sends (Phase B settings) — including fields the
    # backend does not model yet, which must be ignored, never an error.
    "profile_id": "contractor-settings-v1",
    "labour_rate_eur_per_hour": 62.0,
    "paint_cost_eur_per_litre": 18.0,
    "primer_cost_eur_per_litre": 15.0,
    "paint_coverage_m2_per_litre": 12.0,
    "primer_coverage_m2_per_litre": 10.0,
    "labour_m2_per_hour": 10.0,
    "coats": 2,
    "waste_factor": 0.10,
    "prep_factor": 0.15,
    "profit_margin": 0.20,
    "travel_cost_eur": 25.0,
    "vat_rate": 0.21,
    "currency": "EUR",
    "minimum_charge_eur": 350.0,
    "discount_rate": 0.0,
    "prep_material_allowance_eur": 40.0,
    "consumables_allowance_eur": 25.0,
    "misc_percentage": 0.05,
}


def test_uploaded_profile_prices_the_visit(tmp_path):
    client, store = make_client(tmp_path)
    body = upload_with(client, profile=PHONE_PROFILE).json()
    # Frozen onto the session…
    assert body["company_profile"]["profile_id"] == "contractor-settings-v1"
    assert body["company_profile"]["labour_rate_eur_per_hour"] == 62.0
    # …and actually used: labour is billed at the contractor's rate.
    labour_hours = body["estimate"]["labour_hours"]
    assert body["estimate"]["labour_cost_eur"] == round(labour_hours * 62.0, 2)
    # The estimator's own arithmetic trail names the rate too.
    stored = store.load(body["session_id"])
    assert stored.company_profile.labour_rate_eur_per_hour == 62.0


def test_default_profile_without_upload(tmp_path):
    client, _ = make_client(tmp_path)
    body = upload_with(client).json()
    assert body["company_profile"]["profile_id"] == "default-v1"


def test_malformed_profile_degrades_to_default_with_note(tmp_path):
    client, _ = make_client(tmp_path)
    body = upload_with(client, raw_profile="{not json").json()
    assert body["status"] != "failed"
    assert body["company_profile"]["profile_id"] == "default-v1"
    assert "company_profile_error" in body["raw_metadata"]


def test_invalid_profile_values_degrade_to_default(tmp_path):
    client, _ = make_client(tmp_path)
    bad = dict(PHONE_PROFILE, coats=0)  # violates ge=1
    body = upload_with(client, profile=bad).json()
    assert body["company_profile"]["profile_id"] == "default-v1"
    assert "company_profile_error" in body["raw_metadata"]


def test_client_metadata_lands_namespaced_and_stringly(tmp_path):
    client, _ = make_client(tmp_path)
    body = upload_with(client, metadata={
        "recording_consent": "true",
        "recording_consent_at": "2026-09-02T09:14:00Z",
        "client_app_build": "42",
    }).json()
    md = body["raw_metadata"]
    assert md["client_recording_consent"] == "true"
    assert md["client_recording_consent_at"] == "2026-09-02T09:14:00Z"
    assert md["client_app_build"] == "42"  # already namespaced: not doubled
    # iPhone decodes raw_metadata as [String: String] — everything stays a string.
    assert all(isinstance(v, str) for v in md.values())


def test_hostile_metadata_is_dropped_not_fatal(tmp_path):
    client, _ = make_client(tmp_path)
    # Non-string values, absurd keys, malformed JSON: visit still succeeds.
    body = upload_with(client, metadata={"depth": {"nested": 1}, "n": "1"}).json()
    assert body["raw_metadata"].get("client_n") == "1"
    assert "client_depth" not in body["raw_metadata"]
    body2 = upload_with(client, raw_metadata="]][[").json()
    assert body2["status"] != "failed"
    # Oversized payload: ignored wholesale.
    big = {"k": "v" * 10000}
    body3 = upload_with(client, raw_metadata=json.dumps(big)).json()
    assert "client_k" not in body3["raw_metadata"]


def test_metadata_cannot_clobber_pipeline_keys(tmp_path):
    client, _ = make_client(tmp_path)
    body = upload_with(client, metadata={"error": "spoofed", "version": "99"}).json()
    md = body["raw_metadata"]
    assert md.get("error") != "spoofed"        # namespaced away
    assert md.get("client_error") == "spoofed"
    assert md.get("version") != "99"
