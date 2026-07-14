"""Deterministic estimator. Never AI.

Every rule is explicit, every rounding step is defined, and every applied
assumption is recorded in the estimate's `assumptions` list so a painter can
follow the arithmetic from measurements to quotation.

Rounding rules (docs/DECISIONS.md, Decision 13):
- paint and primer quantities round UP to the nearest 0.5 L
- labour hours round UP to the nearest 0.25 h
- money rounds HALF-UP to 2 decimal places, applied at each cost line
"""

from __future__ import annotations

import math
from decimal import ROUND_HALF_UP, Decimal

from buildpilot.models.session import (
    CompanyProfile,
    EstimateDraft,
    PaintScope,
    RequirementExtraction,
    RoomMeasurement,
)
from buildpilot.pipelines.confidence import GEOMETRY_WARNING_THRESHOLD

PAINT_ROUNDING_LITRES = 0.5
LABOUR_ROUNDING_HOURS = 0.25


def round_up(value: float, step: float) -> float:
    """Round a positive quantity up to the nearest step (e.g. 0.5 L tins)."""
    return math.ceil(round(value / step, 9)) * step


def money(value: float | Decimal) -> Decimal:
    """Round to 2 dp, half-up — the conventional rule for currency.

    Floats convert via str() so that e.g. 2.675 rounds to 2.68, not 2.67
    (Decimal(2.675) would inherit the float's binary inexactness).
    """
    if isinstance(value, float):
        value = Decimal(str(value))
    return value.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


class DeterministicEstimator:
    """Combines measurements, extracted requirements, and the company profile."""

    def estimate(
        self,
        measurements: RoomMeasurement,
        requirements: RequirementExtraction,
        company_profile: CompanyProfile,
    ) -> EstimateDraft:
        p = company_profile
        scope: PaintScope = requirements.paint_scope
        assumptions: list[str] = []

        # --- area to paint ---------------------------------------------------
        area_m2 = 0.0
        if scope.walls:
            selected = [
                w for w in measurements.walls
                if w.wall_id in requirements.painted_wall_ids
            ]
            if requirements.painted_wall_ids and selected:
                # The conversation limited painting to specific walls: price
                # exactly those. Estimated wall completion (uncaptured walls)
                # never applies here — the painter pointed at real walls.
                wall_area = sum(w.net_area_m2 for w in selected)
                area_m2 += wall_area
                described = ", ".join(
                    f"{w.wall_id} ({w.width_m:.2f}x{w.height_m:.2f} m)" for w in selected
                )
                assumptions.append(
                    f"Painting {len(selected)} of {len(measurements.walls)} walls "
                    f"per conversation: {described} = {wall_area:.2f} m2"
                )
            else:
                if requirements.painted_wall_ids and not selected:
                    assumptions.append(
                        "Requested wall selection did not match the scan; "
                        "all walls included — verify before quoting"
                    )
                area_m2 += measurements.net_wall_area_m2
                assumptions.append(
                    f"Walls included: net wall area {measurements.net_wall_area_m2:.2f} m2"
                )
        else:
            assumptions.append("Walls excluded per conversation")
        if scope.ceiling:
            area_m2 += measurements.ceiling_area_m2
            assumptions.append(
                f"Ceiling included: {measurements.ceiling_area_m2:.2f} m2"
            )
        else:
            assumptions.append("Ceiling excluded per conversation")
        if not requirements.transcript_available:
            assumptions.append(
                "No usable conversation transcript: default scope applied (walls + ceiling)"
            )

        # --- materials --------------------------------------------------------
        paint_exact = area_m2 * p.coats / p.paint_coverage_m2_per_litre * (1 + p.waste_factor)
        paint_litres = round_up(paint_exact, PAINT_ROUNDING_LITRES) if paint_exact > 0 else 0.0
        assumptions.append(
            f"Paint: {area_m2:.2f} m2 x {p.coats} coats / {p.paint_coverage_m2_per_litre} m2/L "
            f"x {1 + p.waste_factor:.2f} waste = {paint_exact:.2f} L, rounded up to {paint_litres} L"
        )

        primer_exact = area_m2 / p.primer_coverage_m2_per_litre * (1 + p.waste_factor)
        primer_litres = round_up(primer_exact, PAINT_ROUNDING_LITRES) if primer_exact > 0 else 0.0
        assumptions.append(
            f"Primer: 1 coat over full painted area = {primer_exact:.2f} L, "
            f"rounded up to {primer_litres} L"
        )

        paint_cost = money(Decimal(str(paint_litres)) * Decimal(str(p.paint_cost_eur_per_litre)))
        primer_cost = money(Decimal(str(primer_litres)) * Decimal(str(p.primer_cost_eur_per_litre)))
        material_cost = money(paint_cost + primer_cost)

        # --- labour -----------------------------------------------------------
        # Painting passes: paint coats plus one primer coat, at the same
        # application rate; prep work is a multiplier on top.
        passes = p.coats + 1
        labour_exact = (area_m2 * passes / p.labour_m2_per_hour) * (1 + p.prep_factor)
        labour_hours = round_up(labour_exact, LABOUR_ROUNDING_HOURS) if labour_exact > 0 else 0.0
        assumptions.append(
            f"Labour: {area_m2:.2f} m2 x {passes} passes (incl. primer) / "
            f"{p.labour_m2_per_hour} m2/h x {1 + p.prep_factor:.2f} prep = "
            f"{labour_exact:.2f} h, rounded up to {labour_hours} h"
        )
        labour_cost = money(Decimal(str(labour_hours)) * Decimal(str(p.labour_rate_eur_per_hour)))

        # --- quotation ----------------------------------------------------------
        subtotal = money(material_cost + labour_cost + money(p.travel_cost_eur))
        with_margin = money(subtotal * (1 + Decimal(str(p.profit_margin))))
        quotation = money(with_margin * (1 + Decimal(str(p.vat_rate))))
        assumptions.append(
            f"Quotation: (materials {material_cost} + labour {labour_cost} + "
            f"travel {money(p.travel_cost_eur)}) x {1 + p.profit_margin:.2f} margin "
            f"x {1 + p.vat_rate:.2f} VAT = {quotation} {p.currency}"
        )
        if measurements.confidence_score < GEOMETRY_WARNING_THRESHOLD:
            assumptions.append(
                f"WARNING: low scan confidence ({measurements.confidence_score:.2f}) - verify measurements"
            )

        return EstimateDraft(
            paint_quantity_litres=paint_litres,
            primer_quantity_litres=primer_litres,
            labour_hours=labour_hours,
            material_cost_eur=float(material_cost),
            labour_cost_eur=float(labour_cost),
            suggested_quotation_eur=float(quotation),
            currency=p.currency,
            assumptions=assumptions,
        )
