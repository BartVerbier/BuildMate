from datetime import datetime, timezone

import pytest
from pydantic import ValidationError

from buildpilot.models.session import (
    SESSION_SCHEMA_VERSION,
    AudioCapture,
    CompanyProfile,
    EstimateDraft,
    RequirementExtraction,
    RoomMeasurement,
    RoomScanCapture,
    Session,
    SessionStatus,
)


def make_company_profile(**overrides) -> CompanyProfile:
    values = dict(
        labour_rate_eur_per_hour=45.0,
        paint_cost_eur_per_litre=18.0,
        primer_cost_eur_per_litre=20.0,
        paint_coverage_m2_per_litre=12.0,
        primer_coverage_m2_per_litre=10.0,
        coats=2,
        waste_factor=0.1,
        prep_factor=0.15,
        profit_margin=0.2,
        travel_cost_eur=25.0,
        vat_rate=0.21,
    )
    values.update(overrides)
    return CompanyProfile(**values)


def test_session_defaults():
    session = Session(
        session_id="sess-001",
        created_at="2026-07-10T00:00:00Z",
        updated_at="2026-07-10T00:00:00Z",
    )

    assert session.schema_version == SESSION_SCHEMA_VERSION
    assert session.status == SessionStatus.DRAFT
    assert session.capture_device == "iphone"
    assert session.room_scan is None
    assert session.audio is None
    assert session.measurements is None
    assert session.requirements is None
    assert session.company_profile is None
    assert session.estimate is None


def test_timestamps_are_parsed_as_datetimes():
    session = Session(
        session_id="sess-002",
        created_at="2026-07-10T09:30:00Z",
        updated_at="2026-07-10T10:00:00+02:00",
    )

    assert session.created_at == datetime(2026, 7, 10, 9, 30, tzinfo=timezone.utc)
    assert isinstance(session.updated_at, datetime)


def test_invalid_timestamp_is_rejected():
    with pytest.raises(ValidationError):
        Session(session_id="sess-bad", created_at="yesterday", updated_at="later")


def test_full_session_round_trips_through_json():
    session = Session(
        session_id="sess-003",
        created_at="2026-07-10T00:00:00Z",
        updated_at="2026-07-10T00:00:00Z",
        room_scan=RoomScanCapture(file_name="room.json", size_bytes=48_000),
        audio=AudioCapture(file_name="visit.m4a", duration_seconds=120.0, size_bytes=1_024_000),
        measurements=RoomMeasurement(
            gross_wall_area_m2=42.0,
            net_wall_area_m2=36.5,
            ceiling_area_m2=15.0,
            floor_area_m2=15.0,
            door_area_m2=3.5,
            window_area_m2=2.0,
            paintable_surface_area_m2=51.5,
            confidence_score=0.91,
        ),
        requirements=RequirementExtraction(
            scope_of_work=["Paint walls"],
            exclusions=["Ceiling"],
            preparation_required=["Fill cracks"],
            special_notes=["Use eggshell finish"],
        ),
        company_profile=make_company_profile(),
        estimate=EstimateDraft(
            paint_quantity_litres=9.5,
            primer_quantity_litres=4.0,
            labour_hours=8.0,
            material_cost_eur=251.0,
            labour_cost_eur=360.0,
            suggested_quotation_eur=780.0,
        ),
    )

    restored = Session.model_validate_json(session.model_dump_json())

    assert restored == session
    assert restored.room_scan.format == "captured-room-json"
    assert restored.audio.mime_type == "audio/mp4"
    assert restored.company_profile.labour_rate_eur_per_hour == 45.0
    assert restored.company_profile.currency == "EUR"
    assert restored.estimate.suggested_quotation_eur == 780.0


def test_negative_area_is_rejected():
    with pytest.raises(ValidationError):
        RoomMeasurement(
            gross_wall_area_m2=-1.0,
            net_wall_area_m2=0.0,
            ceiling_area_m2=0.0,
            floor_area_m2=0.0,
            door_area_m2=0.0,
            window_area_m2=0.0,
            paintable_surface_area_m2=0.0,
            confidence_score=0.5,
        )


def test_confidence_score_must_be_at_most_one():
    with pytest.raises(ValidationError):
        RoomMeasurement(
            gross_wall_area_m2=10.0,
            net_wall_area_m2=10.0,
            ceiling_area_m2=5.0,
            floor_area_m2=5.0,
            door_area_m2=0.0,
            window_area_m2=0.0,
            paintable_surface_area_m2=15.0,
            confidence_score=1.2,
        )


def test_zero_coverage_is_rejected():
    with pytest.raises(ValidationError):
        make_company_profile(paint_coverage_m2_per_litre=0.0)


def test_at_least_one_coat_required():
    with pytest.raises(ValidationError):
        make_company_profile(coats=0)
