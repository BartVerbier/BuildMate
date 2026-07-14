"""Manual plan editing: deterministic re-derivation + re-estimate."""

from buildpilot.config import DEFAULT_COMPANY_PROFILE
from buildpilot.models.session import (
    PlanEdit,
    RequirementExtraction,
    RoomMeasurement,
    WallDetail,
    WallEdit,
)
from buildpilot.pipelines.editing import apply_plan_edit

from tests.test_server_e2e import make_client, upload


def _measurements() -> RoomMeasurement:
    return RoomMeasurement(
        gross_wall_area_m2=20, net_wall_area_m2=18.5, ceiling_area_m2=15,
        floor_area_m2=15, door_area_m2=1.5, window_area_m2=0,
        paintable_surface_area_m2=33.5, confidence_score=0.55,
        walls=[
            WallDetail(wall_id="w1", width_m=5, height_m=2.5, gross_area_m2=12.5, opening_area_m2=1.5, net_area_m2=11),
            WallDetail(wall_id="w2", width_m=3, height_m=2.5, gross_area_m2=7.5, opening_area_m2=0, net_area_m2=7.5),
        ],
        notes=["added estimated wall area for the uncaptured walls — verify on site",
               "Floor area from scanned floor polygon"],
    )


def test_wall_edit_rederives_areas_without_mutating_input():
    m0 = _measurements()
    m, _, _ = apply_plan_edit(
        m0, RequirementExtraction(), DEFAULT_COMPANY_PROFILE,
        PlanEdit(walls=[WallEdit(wall_id="w1", width_m=6.0, opening_area_m2=2.0)]),
    )
    w1 = next(w for w in m.walls if w.wall_id == "w1")
    assert w1.width_m == 6.0
    assert w1.gross_area_m2 == 15.0   # 6.0 x 2.5
    assert w1.net_area_m2 == 13.0     # 15.0 - 2.0
    assert m.net_wall_area_m2 == 20.5  # 13.0 + 7.5
    assert m.paintable_surface_area_m2 == 35.5  # 20.5 + 15 ceiling
    # original untouched
    assert m0.walls[0].width_m == 5 and m0.net_wall_area_m2 == 18.5


def test_coats_and_scope_and_ceiling_edits():
    m, r, p = apply_plan_edit(
        _measurements(), RequirementExtraction(), DEFAULT_COMPANY_PROFILE,
        PlanEdit(coats=3, ceiling_area_m2=10.0,
                 paint_scope=None, painted_wall_ids=["w1"]),
    )
    assert p.coats == 3
    assert m.ceiling_area_m2 == 10.0
    assert r.painted_wall_ids == ["w1"]


def test_unknown_painted_wall_ids_are_dropped():
    m, r, _ = apply_plan_edit(
        _measurements(), RequirementExtraction(), DEFAULT_COMPANY_PROFILE,
        PlanEdit(painted_wall_ids=["w1", "w9"]),
    )
    assert r.painted_wall_ids == ["w1"]  # w9 doesn't exist


def test_manual_verification_clears_incomplete_scan_warnings():
    m, _, _ = apply_plan_edit(
        _measurements(), RequirementExtraction(), DEFAULT_COMPANY_PROFILE,
        PlanEdit(measurements_verified=True),
    )
    assert m.confidence_score == 1.0
    assert not any("uncaptured walls" in n for n in m.notes)
    assert any("manually verified" in n.lower() for n in m.notes)
    assert any("Floor area" in n for n in m.notes)  # unrelated note kept


# --- endpoint -----------------------------------------------------------------


def test_reestimate_updates_in_place_and_versions(tmp_path):
    client, store = make_client(tmp_path)
    sid = upload(client).json()["session_id"]
    paint_before = client.get(f"/sessions/{sid}").json()["estimate"]["paint_quantity_litres"]

    resp = client.post(f"/sessions/{sid}/reestimate", json={"coats": 4})
    assert resp.status_code == 200
    body = resp.json()
    assert body["session"]["session_id"] == sid          # same visit, in place
    assert body["version"] == 2
    assert body["session"]["estimate"]["paint_quantity_litres"] > paint_before  # more coats → more paint
    assert body["session"]["company_profile"]["coats"] == 4
    assert (store.session_dir(sid) / "versions" / "v01.json").exists()  # reversible
    assert body["changes"]  # deterministic price deltas returned


def test_reestimate_empty_edit_is_a_deterministic_noop(tmp_path):
    client, _ = make_client(tmp_path)
    sid = upload(client).json()["session_id"]
    before = client.get(f"/sessions/{sid}").json()["estimate"]
    after = client.post(f"/sessions/{sid}/reestimate", json={}).json()["session"]["estimate"]
    assert after == before  # no changes → identical estimate


def test_reestimate_409_when_no_plan(tmp_path):
    import json as _json

    client, _ = make_client(tmp_path)
    empty = _json.dumps({"walls": [], "floors": []}).encode()
    failed = client.post(
        "/sessions", files={"room_scan": ("room.json", empty, "application/json")}
    ).json()
    assert client.post(
        f"/sessions/{failed['session_id']}/reestimate", json={"coats": 3}
    ).status_code == 409
