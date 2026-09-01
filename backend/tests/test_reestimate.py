"""Manual plan corrections (POST /sessions/{id}/reestimate) and the
completeness gate (Decision 34, second half).

The gate promise, both directions:
- an incomplete, unconfirmed scan produces a draft that says NOT QUOTABLE;
- the painter's on-site verification (the Edit Plan toggle) clears it.

Everything on this path is deterministic — these tests run the REAL
measurement engine and estimator; only transcription/extraction are faked
(and never invoked by /reestimate).
"""

import json
from pathlib import Path

from tests.test_revision import make_revision_client
from tests.test_server_e2e import upload

REAL_SCANS = Path(__file__).parent / "fixtures" / "real_scans"
# A genuine open-loop field capture (2 of 4+ walls) — measures incomplete.
INCOMPLETE_SCAN = REAL_SCANS / "visit-20260711-072128-4f23cd.json"


def upload_incomplete(client):
    raw = json.loads(INCOMPLETE_SCAN.read_text())
    room = raw.get("room_scan", raw)
    return client.post(
        "/sessions",
        files={"room_scan": ("room.json", json.dumps(room).encode(), "application/json")},
    )


def reestimate(client, session_id, **payload):
    return client.post(f"/sessions/{session_id}/reestimate", json=payload)


# --- the completeness gate ----------------------------------------------------


def test_incomplete_scan_is_not_quotable(tmp_path):
    client, _ = make_revision_client(tmp_path)
    body = upload_incomplete(client).json()
    estimate = body["estimate"]
    assert body["measurements"]["completeness"]["status"] == "incomplete"
    assert estimate["quotable"] is False
    assert "did not capture the whole room" in estimate["not_quotable_reason"]
    assert any(a.startswith("NOT QUOTABLE") for a in estimate["assumptions"])


def test_complete_scan_is_quotable(tmp_path):
    client, _ = make_revision_client(tmp_path)
    estimate = upload(client).json()["estimate"]
    assert estimate["quotable"] is True
    assert estimate["not_quotable_reason"] is None


def test_verification_clears_the_gate_and_withdrawal_restores_it(tmp_path):
    client, _ = make_revision_client(tmp_path)
    session_id = upload_incomplete(client).json()["session_id"]

    verified = reestimate(client, session_id, measurements_verified=True).json()
    assert verified["session"]["measurements"]["completeness"]["human_confirmed"] is True
    assert verified["session"]["estimate"]["quotable"] is True
    assert "Measurements verified on site" in verified["changes"]

    withdrawn = reestimate(client, session_id, measurements_verified=False).json()
    assert withdrawn["session"]["estimate"]["quotable"] is False
    assert "On-site verification withdrawn" in withdrawn["changes"]


# --- manual measurement edits -------------------------------------------------


def test_wall_edit_reconciles_totals_and_reprices(tmp_path):
    client, store = make_revision_client(tmp_path)
    original = upload(client).json()
    session_id = original["session_id"]

    response = reestimate(
        client, session_id,
        walls=[{"wall_id": "w1", "width_m": 6.0, "height_m": 2.5}],
    )
    assert response.status_code == 200
    body = response.json()
    m = body["session"]["measurements"]

    # The edited wall recomputed, and the totals re-derived from the
    # breakdown — Decision 34: they must never diverge.
    walls = {w["wall_id"]: w for w in m["walls"]}
    assert walls["w1"]["gross_area_m2"] == 15.0
    counted = [w for w in m["walls"] if w["duplicate_of"] is None]
    assert m["gross_wall_area_m2"] == round(sum(w["gross_area_m2"] for w in counted), 2)
    assert m["net_wall_area_m2"] == round(sum(w["net_area_m2"] for w in counted), 2)
    assert m["paintable_surface_area_m2"] == round(
        m["net_wall_area_m2"] + m["ceiling_area_m2"], 2
    )

    # Bigger wall, bigger quote; deltas in the change list; prior version kept.
    assert (
        body["session"]["estimate"]["suggested_quotation_eur"]
        > original["estimate"]["suggested_quotation_eur"]
    )
    assert any(c.startswith("Wall w1 set to") for c in body["changes"])
    assert body["version"] == 2
    assert (store.session_dir(session_id) / "versions" / "v01.json").exists()


def test_unknown_wall_id_is_rejected(tmp_path):
    client, _ = make_revision_client(tmp_path)
    session_id = upload(client).json()["session_id"]
    response = reestimate(
        client, session_id, walls=[{"wall_id": "w99", "width_m": 2.0}]
    )
    assert response.status_code == 422
    assert "w99" in response.json()["detail"]


def test_empty_edit_is_rejected(tmp_path):
    client, _ = make_revision_client(tmp_path)
    session_id = upload(client).json()["session_id"]
    assert reestimate(client, session_id).status_code == 400


def test_manual_edits_feed_the_confidence_engine(tmp_path):
    """Edits count into raw_metadata (as strings — the phone decodes
    [String: String]) and the confidence report is recomputed."""
    client, _ = make_revision_client(tmp_path)
    session_id = upload(client).json()["session_id"]
    body = reestimate(
        client, session_id,
        walls=[{"wall_id": "w1", "width_m": 5.5}], ceiling_area_m2=16.0,
    ).json()
    metadata = body["session"]["raw_metadata"]
    assert metadata["manual_edit_count"] == "2"
    assert all(isinstance(v, str) for v in metadata.values())
    assert body["session"]["confidence"] is not None


def test_picking_walls_resolves_unresolved_reference(tmp_path):
    """The designed resolution path for the 2026-08-16 money bug: the painter
    choosing walls in Edit Plan clears unresolved_wall_reference."""
    client, store = make_revision_client(tmp_path)
    session_id = upload(client).json()["session_id"]
    session = store.load(session_id)
    session.requirements.unresolved_wall_reference = "the wall with the TV"
    store.save(session)

    body = reestimate(client, session_id, painted_wall_ids=["w2"]).json()
    r = body["session"]["requirements"]
    assert r["painted_wall_ids"] == ["w2"]
    assert r["unresolved_wall_reference"] is None
    # And the estimate now prices exactly that wall.
    assert any("Painting w2" in c for c in body["changes"])


def test_coats_override_reprices(tmp_path):
    client, _ = make_revision_client(tmp_path)
    original = upload(client).json()
    body = reestimate(client, original["session_id"], coats=3).json()
    assert body["session"]["company_profile"]["coats"] == 3
    assert (
        body["session"]["estimate"]["suggested_quotation_eur"]
        > original["estimate"]["suggested_quotation_eur"]
    )
