"""Additive pricing terms (Settings foundation) + per-visit company profile.

The new CompanyProfile fields must default to a no-op so historical quotes are
unchanged, and the phone-sent profile must drive the estimate.
"""

from pathlib import Path

from buildpilot.config import DEFAULT_COMPANY_PROFILE
from buildpilot.models.session import PaintScope, RequirementExtraction, RoomMeasurement
from buildpilot.pipelines.estimator import DeterministicEstimator

from tests.test_server_e2e import make_client

FIXTURE = Path(__file__).parent / "fixtures" / "synthetic_room_5x3.json"
E = DeterministicEstimator()


def _m() -> RoomMeasurement:
    return RoomMeasurement(
        gross_wall_area_m2=40, net_wall_area_m2=37, ceiling_area_m2=15, floor_area_m2=15,
        door_area_m2=2, window_area_m2=1, paintable_surface_area_m2=52, confidence_score=0.9,
    )


def _r() -> RequirementExtraction:
    return RequirementExtraction(paint_scope=PaintScope(walls=True, ceiling=True))


def test_new_terms_default_to_a_noop():
    base = DEFAULT_COMPANY_PROFILE
    baseline = E.estimate(_m(), _r(), base).suggested_quotation_eur
    zeroed = base.model_copy(update={
        "minimum_charge_eur": 0.0, "discount_rate": 0.0,
        "prep_material_allowance_eur": 0.0, "consumables_allowance_eur": 0.0,
        "misc_percentage": 0.0,
    })
    assert E.estimate(_m(), _r(), zeroed).suggested_quotation_eur == baseline


def test_materials_allowance_adds_to_material_cost():
    base = DEFAULT_COMPANY_PROFILE
    e0 = E.estimate(_m(), _r(), base)
    e1 = E.estimate(_m(), _r(), base.model_copy(update={
        "prep_material_allowance_eur": 30.0, "consumables_allowance_eur": 20.0,
    }))
    assert e1.material_cost_eur == round(e0.material_cost_eur + 50.0, 2)
    assert e1.suggested_quotation_eur > e0.suggested_quotation_eur


def test_minimum_charge_floors_the_ex_vat_price():
    base = DEFAULT_COMPANY_PROFILE
    e0 = E.estimate(_m(), _r(), base)
    e1 = E.estimate(_m(), _r(), base.model_copy(update={"minimum_charge_eur": 100_000.0}))
    assert round(e1.suggested_quotation_eur, 2) == round(100_000.0 * (1 + base.vat_rate), 2)
    assert e1.suggested_quotation_eur > e0.suggested_quotation_eur


def test_discount_reduces_and_misc_increases():
    base = DEFAULT_COMPANY_PROFILE
    e0 = E.estimate(_m(), _r(), base).suggested_quotation_eur
    assert E.estimate(_m(), _r(), base.model_copy(update={"discount_rate": 0.10})).suggested_quotation_eur < e0
    assert E.estimate(_m(), _r(), base.model_copy(update={"misc_percentage": 0.05})).suggested_quotation_eur > e0


def test_session_uses_the_sent_company_profile(tmp_path):
    client, _ = make_client(tmp_path)
    custom = DEFAULT_COMPANY_PROFILE.model_copy(update={"labour_rate_eur_per_hour": 90.0})
    sent = client.post(
        "/sessions",
        files={"room_scan": ("room.json", FIXTURE.read_bytes(), "application/json")},
        data={"company_profile": custom.model_dump_json()},
    ).json()
    default = client.post(
        "/sessions",
        files={"room_scan": ("room.json", FIXTURE.read_bytes(), "application/json")},
    ).json()
    assert sent["company_profile"]["labour_rate_eur_per_hour"] == 90.0
    assert sent["estimate"]["labour_cost_eur"] > default["estimate"]["labour_cost_eur"]


def test_malformed_profile_falls_back_to_default(tmp_path):
    client, _ = make_client(tmp_path)
    body = client.post(
        "/sessions",
        files={"room_scan": ("room.json", FIXTURE.read_bytes(), "application/json")},
        data={"company_profile": "{not valid json"},
    ).json()
    assert body["status"] == "completed"  # never fails the visit
    assert body["company_profile"]["labour_rate_eur_per_hour"] == DEFAULT_COMPANY_PROFILE.labour_rate_eur_per_hour
