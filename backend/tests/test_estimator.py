"""Every expected number in this file is hand-computed from the documented rules."""

import pytest

from buildpilot.models.session import (
    CompanyProfile,
    PaintScope,
    RequirementExtraction,
    RoomMeasurement,
)
from buildpilot.pipelines.estimator import DeterministicEstimator, money, round_up


def profile() -> CompanyProfile:
    return CompanyProfile(
        labour_rate_eur_per_hour=45.0,
        paint_cost_eur_per_litre=18.0,
        primer_cost_eur_per_litre=15.0,
        paint_coverage_m2_per_litre=12.0,
        primer_coverage_m2_per_litre=10.0,
        labour_m2_per_hour=10.0,
        coats=2,
        waste_factor=0.10,
        prep_factor=0.15,
        profit_margin=0.20,
        travel_cost_eur=25.0,
        vat_rate=0.21,
    )


def measurements() -> RoomMeasurement:
    return RoomMeasurement(
        gross_wall_area_m2=42.0,
        net_wall_area_m2=36.0,
        ceiling_area_m2=15.0,
        floor_area_m2=15.0,
        door_area_m2=3.5,
        window_area_m2=2.5,
        paintable_surface_area_m2=51.0,
        confidence_score=0.9,
    )


def test_rounding_helpers():
    assert round_up(9.35, 0.5) == 9.5
    assert round_up(9.5, 0.5) == 9.5      # exact value does not round up further
    assert round_up(0.01, 0.5) == 0.5
    assert round_up(15.3 * 1.15, 0.25) == 17.75
    assert float(money(1575.057)) == 1575.06
    assert float(money(2.675)) == 2.68    # half-up, not banker's rounding


def test_walls_and_ceiling_estimate_exact_numbers():
    """Area 51 m2, walls + ceiling.

    paint  = 51 x 2 / 12 x 1.10 = 9.35  -> 9.5 L  -> 171.00 EUR
    primer = 51 / 10 x 1.10     = 5.61  -> 6.0 L  ->  90.00 EUR
    labour = 51 x 3 / 10 x 1.15 = 17.595 -> 17.75 h -> 798.75 EUR
    quote  = (261.00 + 798.75 + 25.00) x 1.20 x 1.21 = 1575.06 EUR
    """
    estimate = DeterministicEstimator().estimate(
        measurements(), RequirementExtraction(), profile()
    )

    assert estimate.paint_quantity_litres == 9.5
    assert estimate.primer_quantity_litres == 6.0
    assert estimate.labour_hours == 17.75
    assert estimate.material_cost_eur == 261.00
    assert estimate.labour_cost_eur == 798.75
    assert estimate.suggested_quotation_eur == 1575.06
    assert estimate.currency == "EUR"
    assert any("9.5 L" in a for a in estimate.assumptions)


def test_walls_only_scope():
    """Area 36 m2, ceiling excluded.

    paint  = 36 x 2 / 12 x 1.10 = 6.6  -> 7.0 L
    primer = 36 / 10 x 1.10     = 3.96 -> 4.0 L
    """
    requirements = RequirementExtraction(paint_scope=PaintScope(walls=True, ceiling=False))
    estimate = DeterministicEstimator().estimate(measurements(), requirements, profile())

    assert estimate.paint_quantity_litres == 7.0
    assert estimate.primer_quantity_litres == 4.0
    assert any("Ceiling excluded" in a for a in estimate.assumptions)


def test_nothing_to_paint_yields_zero_quantities():
    requirements = RequirementExtraction(paint_scope=PaintScope(walls=False, ceiling=False))
    estimate = DeterministicEstimator().estimate(measurements(), requirements, profile())

    assert estimate.paint_quantity_litres == 0.0
    assert estimate.primer_quantity_litres == 0.0
    assert estimate.labour_hours == 0.0
    assert estimate.material_cost_eur == 0.0
    # travel still applies; painter reviews
    assert estimate.suggested_quotation_eur == pytest.approx(36.30)


def test_low_confidence_adds_warning():
    low = measurements().model_copy(update={"confidence_score": 0.4})
    estimate = DeterministicEstimator().estimate(low, RequirementExtraction(), profile())
    assert any(a.startswith("WARNING") for a in estimate.assumptions)


def test_estimator_is_deterministic():
    a = DeterministicEstimator().estimate(measurements(), RequirementExtraction(), profile())
    b = DeterministicEstimator().estimate(measurements(), RequirementExtraction(), profile())
    assert a.model_dump() == b.model_dump()


def test_wall_selection_prices_only_selected_walls():
    """Conversation limited painting to w1: only its net area is priced.

    walls: w1 net 11.3, w2 net 10.7, w3 7.5, w4 7.5 (room total 37.0)
    area = 11.3 (ceiling excluded)
    paint  = 11.3 x 2 / 12 x 1.10 = 2.0717 -> 2.5 L
    labour = 11.3 x 3 / 10 x 1.15 = 3.8985 -> 4.0 h
    """
    from buildpilot.models.session import WallDetail

    m = measurements().model_copy(update={"walls": [
        WallDetail(wall_id="w1", width_m=5.0, height_m=2.5, gross_area_m2=12.5,
                   opening_area_m2=1.2, net_area_m2=11.3),
        WallDetail(wall_id="w2", width_m=5.0, height_m=2.5, gross_area_m2=12.5,
                   opening_area_m2=1.8, net_area_m2=10.7),
        WallDetail(wall_id="w3", width_m=3.0, height_m=2.5, gross_area_m2=7.5,
                   net_area_m2=7.5),
        WallDetail(wall_id="w4", width_m=3.0, height_m=2.5, gross_area_m2=7.5,
                   net_area_m2=7.5),
    ]})
    requirements = RequirementExtraction(
        painted_wall_ids=["w1"],
        paint_scope=PaintScope(walls=True, ceiling=False),
    )
    estimate = DeterministicEstimator().estimate(m, requirements, profile())

    assert estimate.paint_quantity_litres == 2.5
    assert estimate.labour_hours == 4.0
    assert any("Painting 1 of 4 walls" in a for a in estimate.assumptions)


def test_unknown_wall_selection_falls_back_to_all_walls():
    requirements = RequirementExtraction(
        painted_wall_ids=["w9"],  # not in the (empty) wall list
        paint_scope=PaintScope(walls=True, ceiling=False),
    )
    estimate = DeterministicEstimator().estimate(measurements(), requirements, profile())
    assert any("did not match" in a for a in estimate.assumptions)
    assert any("net wall area 36.00" in a for a in estimate.assumptions)
