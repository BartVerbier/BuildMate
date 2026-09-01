"""Wire-format pin: the JSON the iPhone actually sends must keep working.

Three contracts broke silently before tonight (/reestimate 404'd, the
company profile and metadata were dropped). This file replays VERBATIM
payloads as the app's encoders produce them — PlanEditPayload through
JSONEncoder(.convertToSnakeCase), the profile through explicit CodingKeys —
so drift on either side turns a silent field-drop into a red test.

If a payload here looks wrong, check the Swift encoder FIRST: these
literals are the contract, not a convenience.
"""

from tests.test_revision import make_revision_client
from tests.test_server_e2e import upload


def test_edit_plan_wire_format_minimal(tmp_path):
    """EditPlanView with only the verify toggle flipped: Swift's
    convertToSnakeCase always includes measurements_verified (it is
    non-optional in PlanEditPayload) — this must never 400 as 'empty'."""
    client, _ = make_revision_client(tmp_path)
    session_id = upload(client).json()["session_id"]
    response = client.post(
        f"/sessions/{session_id}/reestimate",
        json={"measurements_verified": False},
    )
    assert response.status_code == 200
    assert response.json()["version"] == 2


def test_edit_plan_wire_format_full(tmp_path):
    """Every field EditPlanView can send, keyed exactly as the phone encodes
    them (openingAreaM2 -> opening_area_m2, paintedWallIds ->
    painted_wall_ids, ...)."""
    client, _ = make_revision_client(tmp_path)
    session_id = upload(client).json()["session_id"]
    payload = {
        "walls": [
            {"wall_id": "w1", "width_m": 5.2, "height_m": 2.5, "opening_area_m2": 1.8},
            {"wall_id": "w2", "height_m": 2.45},
        ],
        "ceiling_area_m2": 15.5,
        "door_area_m2": 1.8,
        "window_area_m2": 1.2,
        "paint_scope": {"walls": True, "ceiling": False},
        "painted_wall_ids": ["w1", "w2"],
        "coats": 3,
        "scope_of_work": ["Paint two walls"],
        "exclusions": ["Ceiling"],
        "preparation_required": ["Fill cracks"],
        "special_notes": ["Keys under the mat"],
        "measurements_verified": True,
    }
    response = client.post(f"/sessions/{session_id}/reestimate", json=payload)
    assert response.status_code == 200
    session = response.json()["session"]

    walls = {w["wall_id"]: w for w in session["measurements"]["walls"]}
    assert walls["w1"]["net_area_m2"] == round(5.2 * 2.5 - 1.8, 2)
    assert walls["w2"]["height_m"] == 2.45
    assert session["measurements"]["ceiling_area_m2"] == 15.5
    assert session["requirements"]["painted_wall_ids"] == ["w1", "w2"]
    assert session["requirements"]["paint_scope"]["ceiling"] is False
    assert session["company_profile"]["coats"] == 3
    assert session["measurements"]["completeness"]["human_confirmed"] is True
    # Response shape iOS decodes as RevisionResponse — all four keys present.
    body = response.json()
    assert set(body) == {"session", "changes", "version", "render_required"}


def test_upload_wire_format_as_the_phone_sends_it(tmp_path):
    """POST /sessions with company_profile + client_metadata exactly as
    submitVisit() encodes them (explicit snake_case CodingKeys, JSON string
    fields in the multipart form)."""
    from tests.test_server_e2e import FIXTURE
    client, _ = make_revision_client(tmp_path)
    response = client.post(
        "/sessions",
        files={"room_scan": ("room.json", FIXTURE.read_bytes(), "application/json")},
        data={
            "company_profile": (
                '{"profile_id":"contractor-settings-v1",'
                '"labour_rate_eur_per_hour":55,"paint_cost_eur_per_litre":19.5,'
                '"primer_cost_eur_per_litre":14,"paint_coverage_m2_per_litre":12,'
                '"primer_coverage_m2_per_litre":10,"labour_m2_per_hour":10,'
                '"coats":2,"waste_factor":0.1,"prep_factor":0.15,'
                '"profit_margin":0.2,"travel_cost_eur":25,"vat_rate":0.21,'
                '"currency":"EUR","minimum_charge_eur":0,"discount_rate":0,'
                '"prep_material_allowance_eur":0,"consumables_allowance_eur":0,'
                '"misc_percentage":0}'
            ),
            "client_metadata": '{"recording_consent":"true","recording_consent_at":"2026-09-02T08:00:00Z"}',
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["company_profile"]["labour_rate_eur_per_hour"] == 55
    assert body["raw_metadata"]["client_recording_consent"] == "true"
