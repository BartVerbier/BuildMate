"""Extractor unit tests. The real Claude call requires API credentials and is
exercised manually / in field testing; these tests cover the degradation
contract, which must hold with no network and no key."""

from buildpilot.models.session import PaintScope
from buildpilot.pipelines.extraction import (
    ClaudeRequirementsExtractor,
    default_requirements,
)


def test_empty_transcript_degrades_without_api_call():
    result = ClaudeRequirementsExtractor().extract("   ")
    assert result.transcript_available is False
    assert result.paint_scope == PaintScope(walls=True, ceiling=True)


def test_default_requirements_carry_reason():
    result = default_requirements("no transcript")
    assert result.transcript_available is False
    assert any("no transcript" in n for n in result.special_notes)


def test_model_configurable_via_env(monkeypatch):
    monkeypatch.setenv("BUILDPILOT_EXTRACTOR_MODEL", "claude-haiku-4-5")
    assert ClaudeRequirementsExtractor().model == "claude-haiku-4-5"
    monkeypatch.delenv("BUILDPILOT_EXTRACTOR_MODEL")
    assert ClaudeRequirementsExtractor().model == "claude-opus-4-8"
