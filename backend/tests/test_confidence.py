"""Unit tests for the deterministic confidence engine."""

from buildpilot.models.session import ConfidenceSignal, RoomMeasurement
from buildpilot.pipelines.confidence import (
    HIGH_BAND_MIN,
    MEDIUM_BAND_MIN,
    ConfidenceContext,
    ConfidenceEngine,
    _band,
    score_measurement,
)


def mk(confidence, ratio=None, floor=None) -> RoomMeasurement:
    return RoomMeasurement(
        gross_wall_area_m2=40, net_wall_area_m2=37, ceiling_area_m2=15,
        floor_area_m2=15, door_area_m2=2, window_area_m2=1,
        paintable_surface_area_m2=52, confidence_score=confidence,
        wall_perimeter_ratio=ratio, floor_captured=floor,
    )


def test_full_quality_scan_scores_high():
    report = score_measurement(mk(0.9, ratio=1.0, floor=True))
    assert report.score >= HIGH_BAND_MIN
    assert report.band == "high"
    assert report.tips == []  # nothing to improve
    # every registered signal contributed
    assert {s.key for s in report.signals} == {
        "geometry", "wall_completeness", "floor_coverage"
    }


def test_poor_scan_scores_low_with_tips():
    report = score_measurement(mk(0.3, ratio=0.5, floor=False))
    assert report.band == "low"
    assert report.score < MEDIUM_BAND_MIN
    # each weak signal surfaces its improvement tip
    assert len(report.tips) == 3
    assert any("perimeter" in t for t in report.tips)
    assert any("floor" in t.lower() for t in report.tips)


def test_engine_abstains_on_missing_signals_and_renormalises():
    # No perimeter/floor data: only the geometry signal is available, and the
    # score must equal that signal alone (weights renormalise over what's present).
    report = score_measurement(mk(0.8, ratio=None, floor=None))
    assert [s.key for s in report.signals] == ["geometry"]
    assert report.score == 80


def test_no_signals_reports_honest_midpoint():
    # An engine with no providers can't judge the scan: neither confident nor a
    # hard zero — it reports the midpoint and says so.
    report = ConfidenceEngine(providers=[]).evaluate(ConfidenceContext(mk(0.9)))
    assert report.score == 50
    assert report.signals == []
    assert "couldn't be assessed" in report.headline


def test_engine_is_extensible_with_a_new_provider():
    # A future signal (e.g. lighting) plugs in without touching the engine.
    class LightingProvider:
        key = "lighting"
        label = "Lighting"
        weight = 1.0

        def evaluate(self, ctx):
            lux = ctx.metadata.get("lighting")
            if lux is None:
                return None
            return ConfidenceSignal(
                key=self.key, label=self.label, score=float(lux),
                weight=self.weight, detail="test lighting signal",
            )

    engine = ConfidenceEngine(providers=[LightingProvider()])
    # abstains with no metadata
    assert engine.evaluate(ConfidenceContext(mk(0.9))).signals == []
    # contributes when the signal exists
    report = engine.evaluate(ConfidenceContext(mk(0.9), {"lighting": "0.2"}))
    assert [s.key for s in report.signals] == ["lighting"]
    assert report.score == 20


def test_band_boundaries():
    assert _band(HIGH_BAND_MIN) == "high"
    assert _band(HIGH_BAND_MIN - 1) == "medium"
    assert _band(MEDIUM_BAND_MIN) == "medium"
    assert _band(MEDIUM_BAND_MIN - 1) == "low"
