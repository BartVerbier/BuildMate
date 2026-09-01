"""Schema pin for the money path (Codex suggestion #10, 2026-09-01).

The iPhone decodes these JSON field names via convertFromSnakeCase; a rename
on the backend would not error — the Swift optional would silently become
nil and a price, gate, or breakdown would quietly vanish from the UI. This
suite freezes the names that carry money or gate decisions. Renaming one is
a coordinated two-platform change: update here LAST, after Models.swift.
"""

from buildpilot.models.session import (
    CompanyProfile,
    EstimateDraft,
    MeasurementCompleteness,
    RoomMeasurement,
)

ESTIMATE_MONEY_FIELDS = {
    "paint_quantity_litres",
    "primer_quantity_litres",
    "labour_hours",
    "material_cost_eur",
    "labour_cost_eur",
    "suggested_quotation_eur",
    "currency",
    "assumptions",
    "quotable",
    "not_quotable_reason",
}

PROFILE_MONEY_FIELDS = {
    "profile_id",
    "labour_rate_eur_per_hour",
    "paint_cost_eur_per_litre",
    "primer_cost_eur_per_litre",
    "paint_coverage_m2_per_litre",
    "primer_coverage_m2_per_litre",
    "labour_m2_per_hour",
    "coats",
    "waste_factor",
    "prep_factor",
    "profit_margin",
    "travel_cost_eur",
    "vat_rate",
    "currency",
}

MEASUREMENT_AREA_FIELDS = {
    "gross_wall_area_m2",
    "net_wall_area_m2",
    "ceiling_area_m2",
    "floor_area_m2",
    "paintable_surface_area_m2",
}


def test_estimate_field_names_are_frozen():
    assert ESTIMATE_MONEY_FIELDS <= set(EstimateDraft.model_fields)


def test_profile_field_names_are_frozen():
    assert PROFILE_MONEY_FIELDS <= set(CompanyProfile.model_fields)


def test_measurement_area_field_names_are_frozen():
    assert MEASUREMENT_AREA_FIELDS <= set(RoomMeasurement.model_fields)


def test_gate_field_names_are_frozen():
    assert {"status", "human_confirmed", "open_edges"} <= set(
        MeasurementCompleteness.model_fields
    )


def test_gate_defaults_stay_backward_compatible():
    """An old session with no gate fields must decode quotable — the app
    treats a missing `quotable` as true, and the backend must agree."""
    draft = EstimateDraft(
        paint_quantity_litres=1, primer_quantity_litres=1, labour_hours=1,
        material_cost_eur=1, labour_cost_eur=1, suggested_quotation_eur=1,
    )
    assert draft.quotable is True
    assert draft.not_quotable_reason is None
