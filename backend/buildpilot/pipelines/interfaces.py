"""Pipeline stage interfaces for the V1 processing chain.

Each stage is a pure function over exactly the data it needs:

    CapturedRoom JSON -> measure    -> RoomMeasurement
    audio file        -> transcribe -> transcript text
    transcript        -> extract    -> RequirementExtraction
    all of the above  -> estimate   -> EstimateDraft

Only transcription and requirements extraction may be AI-backed.
Measurement and estimation must stay deterministic and explainable.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, Protocol

from buildpilot.models.session import (
    CompanyProfile,
    EstimateDraft,
    RequirementExtraction,
    RoomMeasurement,
)


class MeasurementEngine(Protocol):
    """Deterministic. Input is Apple's CapturedRoom JSON, parsed, verbatim."""

    def measure(self, captured_room: Dict[str, Any]) -> RoomMeasurement: ...


class Transcriber(Protocol):
    """May be AI-backed (local Whisper planned). Returns plain transcript text."""

    def transcribe(self, audio_path: Path) -> str: ...


class RequirementsExtractor(Protocol):
    """May be AI-backed (LLM). Must return the structured contract, nothing more."""

    def extract(self, transcript: str) -> RequirementExtraction: ...


class Estimator(Protocol):
    """Deterministic. Never AI."""

    def estimate(
        self,
        measurements: RoomMeasurement,
        requirements: RequirementExtraction,
        company_profile: CompanyProfile,
    ) -> EstimateDraft: ...
