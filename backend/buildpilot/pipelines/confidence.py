"""The confidence engine — how much to trust a scan's measurements (0-100).

Deterministic and never AI, like every other number the estimate depends on.

Architecture: a blend of independent **signal providers**. Each provider looks
at the capture and either emits a `ConfidenceSignal` (a normalised 0-1 quality
with a weight, a plain-language reason, and an improvement tip) or *abstains*
by returning ``None`` when it has no data to judge. The engine blends whatever
signals are present, renormalising weights, so:

- adding a new signal (lighting, device motion, furniture occlusion, manual-edit
  count, ...) is a new provider class in this file plus one line in
  ``DEFAULT_PROVIDERS`` — no change to the engine, the model, or the UI, which
  all render signals generically;
- a provider that lacks data simply abstains, so partial information degrades
  gracefully instead of scoring a hard zero.

Today's registered providers use only signals that genuinely exist in a scan:
geometry confidence, wall/perimeter completeness, and floor coverage. The three
listed future signals are named in the provider docstrings as the intended
extension points.
"""

from __future__ import annotations

from typing import Dict, List, Optional, Protocol

from buildpilot.models.session import (
    ConfidenceReport,
    ConfidenceSignal,
    RoomMeasurement,
)

# --- Single source of truth for every confidence threshold -----------------
# Band cut-offs on the 0-100 score. The display reads the band, never a raw
# number, so these live in exactly one place (previously the "0.6" magic number
# was duplicated across the estimator and the iOS app).
HIGH_BAND_MIN = 75
MEDIUM_BAND_MIN = 50
# A single signal at/below this 0-1 quality contributes its improvement tip.
SIGNAL_LOW_THRESHOLD = 0.6
# The geometry-confidence level below which the estimator flags the quote for
# manual review. Kept here so the estimator and the engine agree by import.
GEOMETRY_WARNING_THRESHOLD = 0.6


class ConfidenceContext:
    """Everything a provider may inspect. Grows by adding attributes, never by
    changing existing providers.

    `metadata` is the session's ``raw_metadata`` bag — the drop-in home for
    future string-valued signals (e.g. ``lighting``, ``motion_score``,
    ``manual_edit_count``) until they earn a typed field.
    """

    def __init__(
        self,
        measurement: Optional[RoomMeasurement],
        metadata: Optional[Dict[str, str]] = None,
    ) -> None:
        self.measurement = measurement
        self.metadata: Dict[str, str] = metadata or {}


class SignalProvider(Protocol):
    """A single confidence contributor."""

    key: str
    label: str
    weight: float

    def evaluate(self, ctx: ConfidenceContext) -> Optional[ConfidenceSignal]:
        """Return a signal, or None to abstain when there's nothing to judge."""
        ...


def _pct(value: float) -> int:
    return int(round(max(0.0, min(1.0, value)) * 100))


class GeometryConfidenceProvider:
    """RoomPlan's own area-weighted confidence over the scanned surfaces.

    (Extension sibling — not yet built: a DeviceMotionProvider reading a
    shake/blur metric from ``ctx.metadata`` would slot in beside this one.)
    """

    key = "geometry"
    label = "Scan geometry"
    weight = 0.5

    def evaluate(self, ctx: ConfidenceContext) -> Optional[ConfidenceSignal]:
        m = ctx.measurement
        if m is None:
            return None
        score = max(0.0, min(1.0, m.confidence_score))
        detail = f"RoomPlan reported {_pct(score)}% geometry confidence across the scanned surfaces."
        tip = (
            "Scan slowly and keep walls, floor, and corners in frame so the "
            "scanner can lock onto the room."
            if score <= SIGNAL_LOW_THRESHOLD
            else None
        )
        return ConfidenceSignal(
            key=self.key, label=self.label, score=score, weight=self.weight,
            detail=detail, tip=tip,
        )


class WallCompletenessProvider:
    """How much of the room's perimeter was actually captured vs. estimated.

    Reads the structured ``wall_perimeter_ratio`` (captured wall width / floor
    perimeter). Abstains when there's no floor perimeter to compare against.
    (Extension sibling — not yet built: a FurnitureOcclusionProvider penalising
    walls hidden behind large movable objects would live here.)
    """

    key = "wall_completeness"
    label = "Wall coverage"
    weight = 0.35

    def evaluate(self, ctx: ConfidenceContext) -> Optional[ConfidenceSignal]:
        m = ctx.measurement
        if m is None or m.wall_perimeter_ratio is None:
            return None
        score = max(0.0, min(1.0, m.wall_perimeter_ratio))
        if score >= 0.98:
            detail = "Every wall around the room's perimeter was captured."
            tip = None
        else:
            detail = (
                f"About {_pct(score)}% of the room's perimeter was captured; "
                "the rest was estimated to keep the quote complete."
            )
            tip = (
                "Walk the full perimeter — scan behind furniture and into "
                "corners so every wall is measured, not estimated."
            )
        return ConfidenceSignal(
            key=self.key, label=self.label, score=score, weight=self.weight,
            detail=detail, tip=tip,
        )


class FloorCoverageProvider:
    """Whether a real floor plane was captured (it anchors room dimensions and
    the ceiling area). Abstains when the scan didn't report floor coverage."""

    key = "floor_coverage"
    label = "Floor coverage"
    weight = 0.15

    def evaluate(self, ctx: ConfidenceContext) -> Optional[ConfidenceSignal]:
        m = ctx.measurement
        if m is None or m.floor_captured is None:
            return None
        if m.floor_captured:
            return ConfidenceSignal(
                key=self.key, label=self.label, score=1.0, weight=self.weight,
                detail="Floor plane captured, anchoring the room's dimensions.",
                tip=None,
            )
        return ConfidenceSignal(
            key=self.key, label=self.label, score=0.4, weight=self.weight,
            detail="The floor plane wasn't captured, so floor and ceiling areas are less certain.",
            tip="Point the camera down to capture the floor — it anchors the room's size.",
        )


# Registration point. Append future providers here; nothing else changes.
DEFAULT_PROVIDERS: List[SignalProvider] = [
    GeometryConfidenceProvider(),
    WallCompletenessProvider(),
    FloorCoverageProvider(),
]


def _band(score_100: int) -> str:
    if score_100 >= HIGH_BAND_MIN:
        return "high"
    if score_100 >= MEDIUM_BAND_MIN:
        return "medium"
    return "low"


def _headline(band: str) -> str:
    return {
        "high": "High confidence — the measurements look reliable.",
        "medium": "Medium confidence — worth a quick check before you send it.",
        "low": "Low confidence — a re-scan is recommended before quoting.",
    }[band]


class ConfidenceEngine:
    def __init__(self, providers: Optional[List[SignalProvider]] = None) -> None:
        self.providers = providers if providers is not None else DEFAULT_PROVIDERS

    def evaluate(self, ctx: ConfidenceContext) -> ConfidenceReport:
        signals = [s for p in self.providers if (s := p.evaluate(ctx)) is not None]

        total_weight = sum(s.weight for s in signals)
        if total_weight > 0:
            blended = sum(s.score * s.weight for s in signals) / total_weight
        else:
            # No provider could judge this scan — neither confident nor a hard
            # zero; report the honest midpoint and say we couldn't assess it.
            blended = 0.5

        score_100 = int(round(max(0.0, min(1.0, blended)) * 100))
        band = _band(score_100)

        tips: List[str] = []
        for s in signals:
            if s.tip and s.score <= SIGNAL_LOW_THRESHOLD and s.tip not in tips:
                tips.append(s.tip)

        headline = (
            _headline(band)
            if signals
            else "Confidence couldn't be assessed from this scan."
        )
        return ConfidenceReport(
            score=score_100, band=band, headline=headline,
            signals=signals, tips=tips,
        )


def score_measurement(
    measurement: Optional[RoomMeasurement],
    metadata: Optional[Dict[str, str]] = None,
    engine: Optional[ConfidenceEngine] = None,
) -> ConfidenceReport:
    """Convenience entry point used by the pipeline."""
    engine = engine or ConfidenceEngine()
    return engine.evaluate(ConfidenceContext(measurement, metadata))
