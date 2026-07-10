"""Smoke test: dummy implementations satisfy the pipeline stage protocols.

Python does not enforce Protocol conformance at runtime, so this test's value
is limited to catching signature drift between the protocols and the models
they exchange. Real behavioural tests arrive with each stage's implementation.
"""

from pathlib import Path
from typing import Any, Dict

import pytest

from buildpilot.models.session import (
    CompanyProfile,
    EstimateDraft,
    RequirementExtraction,
    RoomMeasurement,
)
from buildpilot.pipelines.interfaces import (
    Estimator,
    MeasurementEngine,
    RequirementsExtractor,
    Transcriber,
)


class DummyMeasurementEngine:
    def measure(self, captured_room: Dict[str, Any]) -> RoomMeasurement:
        return RoomMeasurement(
            gross_wall_area_m2=float(captured_room["gross"]),
            net_wall_area_m2=8.0,
            ceiling_area_m2=6.0,
            floor_area_m2=6.0,
            door_area_m2=1.5,
            window_area_m2=0.5,
            paintable_surface_area_m2=14.0,
            confidence_score=0.8,
        )


class DummyTranscriber:
    def transcribe(self, audio_path: Path) -> str:
        return f"transcript of {audio_path.name}"


class DummyRequirementsExtractor:
    def extract(self, transcript: str) -> RequirementExtraction:
        return RequirementExtraction(scope_of_work=[transcript])


class DummyEstimator:
    def estimate(
        self,
        measurements: RoomMeasurement,
        requirements: RequirementExtraction,
        company_profile: CompanyProfile,
    ) -> EstimateDraft:
        litres = measurements.paintable_surface_area_m2 / company_profile.paint_coverage_m2_per_litre
        return EstimateDraft(
            paint_quantity_litres=litres,
            primer_quantity_litres=0.0,
            labour_hours=2.0,
            material_cost_eur=litres * company_profile.paint_cost_eur_per_litre,
            labour_cost_eur=2.0 * company_profile.labour_rate_eur_per_hour,
            suggested_quotation_eur=150.0,
        )


def test_stage_protocols_accept_conforming_implementations():
    measurement_engine: MeasurementEngine = DummyMeasurementEngine()
    transcriber: Transcriber = DummyTranscriber()
    extractor: RequirementsExtractor = DummyRequirementsExtractor()
    estimator: Estimator = DummyEstimator()

    measurements = measurement_engine.measure({"gross": 10.0})
    assert measurements.gross_wall_area_m2 == 10.0

    transcript = transcriber.transcribe(Path("visit.m4a"))
    assert transcript == "transcript of visit.m4a"

    requirements = extractor.extract(transcript)
    assert requirements.scope_of_work == [transcript]

    profile = CompanyProfile(
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
    estimate = estimator.estimate(measurements, requirements, profile)
    assert estimate.paint_quantity_litres == pytest.approx(14.0 / 12.0)
    assert estimate.labour_cost_eur == 90.0
    assert estimate.currency == "EUR"
