"""Transcription unit tests + an optional real-Whisper integration test.

The integration test synthesizes speech with macOS `say`, converts to m4a with
`afconvert` (the exact format the iPhone uploads), and runs real MLX Whisper.
It is skipped unless BUILDPILOT_RUN_WHISPER_TESTS=1 — it downloads model
weights on first run and takes seconds, not milliseconds.
"""

import os
import subprocess
from pathlib import Path

import pytest

from buildpilot.pipelines.transcription import MlxWhisperTranscriber, TranscriptionError


def test_missing_audio_file_raises():
    with pytest.raises(TranscriptionError):
        MlxWhisperTranscriber().transcribe(Path("/nonexistent/visit.m4a"))


def test_model_name_from_env(monkeypatch):
    monkeypatch.setenv("BUILDPILOT_WHISPER_MODEL", "mlx-community/whisper-tiny")
    assert MlxWhisperTranscriber().model_name == "mlx-community/whisper-tiny"
    assert MlxWhisperTranscriber(model_name="x").model_name == "x"


@pytest.mark.skipif(
    os.environ.get("BUILDPILOT_RUN_WHISPER_TESTS") != "1",
    reason="set BUILDPILOT_RUN_WHISPER_TESTS=1 to run the real Whisper integration test",
)
def test_real_whisper_transcribes_synthesized_speech(tmp_path):
    aiff = tmp_path / "visit.aiff"
    m4a = tmp_path / "visit.m4a"
    subprocess.run(
        ["say", "-o", str(aiff), "Please paint all the walls in this room."],
        check=True,
    )
    subprocess.run(
        ["afconvert", "-f", "m4af", "-d", "aac", str(aiff), str(m4a)], check=True
    )

    text = MlxWhisperTranscriber().transcribe(m4a).lower()
    assert "paint" in text and "walls" in text
