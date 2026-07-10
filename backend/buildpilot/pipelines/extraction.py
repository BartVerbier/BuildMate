"""LLM requirements extractor — the ONE paid AI call per visit.

Converts the visit transcript into the typed RequirementExtraction contract
via Claude structured outputs. The output is data, never decisions: the
deterministic estimator consumes the typed fields and does all arithmetic.

Degradation policy: if no transcript or no API credentials are available,
the pipeline continues with the default paint scope (walls + ceiling) and a
note in the estimate — the painter reviews everything anyway.
"""

from __future__ import annotations

import logging
import os
import time
from typing import List

logger = logging.getLogger(__name__)

from pydantic import BaseModel, Field

from buildpilot.models.session import PaintScope, RequirementExtraction

DEFAULT_EXTRACTOR_MODEL = "claude-opus-4-8"

SYSTEM_PROMPT = """You extract painting job requirements from a transcript of a
conversation between a painter and a customer during a site visit to ONE room.

Rules:
- Extract only what is actually said or clearly implied. Do not invent work.
- scope_of_work: concrete painting tasks the customer wants (short phrases).
- exclusions: surfaces or tasks the customer explicitly does NOT want.
- preparation_required: prep work mentioned (filling cracks, sanding, covering).
- special_notes: colour/finish preferences, access constraints, anything else
  a painter would want on the quote.
- paint_scope.walls / paint_scope.ceiling: whether that surface should be
  painted. Default to walls=true. Set ceiling=false only if the conversation
  excludes it; if the ceiling is never mentioned, leave ceiling=true.
- The transcript may contain filler and unrelated small talk; ignore it."""


class _LlmExtraction(BaseModel):
    """Schema handed to the model — excludes fields the pipeline sets itself."""

    scope_of_work: List[str] = Field(default_factory=list)
    exclusions: List[str] = Field(default_factory=list)
    preparation_required: List[str] = Field(default_factory=list)
    special_notes: List[str] = Field(default_factory=list)
    paint_scope: PaintScope = Field(default_factory=PaintScope)


class ExtractionError(RuntimeError):
    """Raised when extraction cannot run; orchestrator degrades gracefully."""


def default_requirements(reason: str) -> RequirementExtraction:
    """The documented fallback: default scope, flagged for painter review."""
    return RequirementExtraction(
        special_notes=[f"Requirements extraction unavailable: {reason}"],
        paint_scope=PaintScope(),
        transcript_available=False,
    )


class ClaudeRequirementsExtractor:
    """Extracts requirements with Claude structured outputs.

    Model is configurable via BUILDPILOT_EXTRACTOR_MODEL (e.g. claude-haiku-4-5
    to trade capability for cost); default is claude-opus-4-8.
    """

    def __init__(self, model: str | None = None) -> None:
        self.model = model or os.environ.get(
            "BUILDPILOT_EXTRACTOR_MODEL", DEFAULT_EXTRACTOR_MODEL
        )

    @staticmethod
    def is_available() -> bool:
        """Cheap credential hint for /health. The real check is the API call:
        the SDK also resolves `ant auth login` profiles, so an unset env var
        does not prove there are no credentials."""
        return bool(
            os.environ.get("ANTHROPIC_API_KEY")
            or os.environ.get("ANTHROPIC_AUTH_TOKEN")
        )

    def extract(self, transcript: str) -> RequirementExtraction:
        if not transcript.strip():
            return default_requirements("empty transcript")
        try:
            import anthropic
        except ImportError as exc:
            raise ExtractionError("anthropic SDK is not installed") from exc

        logger.info(
            "Extraction request: model=%s, transcript=%d chars", self.model, len(transcript)
        )
        started = time.perf_counter()
        try:
            client = anthropic.Anthropic()
            response = client.messages.parse(
                model=self.model,
                max_tokens=4096,
                system=SYSTEM_PROMPT,
                messages=[
                    {
                        "role": "user",
                        "content": f"Visit transcript:\n\n{transcript}",
                    }
                ],
                output_format=_LlmExtraction,
            )
        except anthropic.APIError as exc:  # includes AuthenticationError
            raise ExtractionError(f"Anthropic API error: {exc}") from exc
        except TypeError as exc:
            # The SDK raises TypeError at request-build time when no credential
            # source (env var, auth token, `ant auth login` profile) resolves.
            raise ExtractionError("no Anthropic credentials configured") from exc

        extracted: _LlmExtraction = response.parsed_output
        logger.info(
            "Extraction response in %.1fs: scope=%d, exclusions=%d, prep=%d, notes=%d, "
            "paint walls=%s ceiling=%s",
            time.perf_counter() - started,
            len(extracted.scope_of_work),
            len(extracted.exclusions),
            len(extracted.preparation_required),
            len(extracted.special_notes),
            extracted.paint_scope.walls,
            extracted.paint_scope.ceiling,
        )
        return RequirementExtraction(
            scope_of_work=extracted.scope_of_work,
            exclusions=extracted.exclusions,
            preparation_required=extracted.preparation_required,
            special_notes=extracted.special_notes,
            paint_scope=extracted.paint_scope,
            transcript_available=True,
        )
