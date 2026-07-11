"""Transcriber selection + faster-whisper segment shaping.

The real faster-whisper (CTranslate2, heavy) installs only on Railway; here a
stub module stands in so the selection logic and output shaping are covered
without the dependency.
"""

import sys
import types

import pytest

from buildpilot.pipelines import transcription as T


@pytest.fixture()
def fake_faster_whisper(monkeypatch):
    """Inject a minimal `faster_whisper` module with a scripted model."""
    module = types.ModuleType("faster_whisper")

    class Segment:
        def __init__(self, start, end, text):
            self.start, self.end, self.text = start, end, text

    class WhisperModel:
        def __init__(self, model_name, device="cpu", compute_type="int8"):
            self.model_name = model_name

        def transcribe(self, path):
            segs = [
                Segment(0.0, 2.0, " Look at this wall. "),
                Segment(2.0, 4.0, "We are painting it."),
                Segment(4.0, 4.5, "   "),  # blank — must be dropped
            ]
            return iter(segs), {"language": "en"}

    module.WhisperModel = WhisperModel
    monkeypatch.setitem(sys.modules, "faster_whisper", module)
    T.FasterWhisperTranscriber._model_cache.clear()
    yield
    T.FasterWhisperTranscriber._model_cache.clear()


def test_faster_whisper_shapes_segments(fake_faster_whisper, tmp_path):
    audio = tmp_path / "visit.m4a"
    audio.write_bytes(b"fake-audio")
    text, segments = T.FasterWhisperTranscriber().transcribe_segments(audio)

    assert text == "Look at this wall. We are painting it."
    assert [s["text"] for s in segments] == ["Look at this wall.", "We are painting it."]
    assert segments[0]["start"] == 0.0 and segments[0]["end"] == 2.0


def test_faster_whisper_missing_file_raises(fake_faster_whisper, tmp_path):
    with pytest.raises(T.TranscriptionError):
        T.FasterWhisperTranscriber().transcribe_segments(tmp_path / "nope.m4a")


def test_select_prefers_mlx_when_available(monkeypatch):
    monkeypatch.delenv("BUILDPILOT_TRANSCRIBER", raising=False)
    monkeypatch.setattr(T.MlxWhisperTranscriber, "is_available", staticmethod(lambda: True))
    monkeypatch.setattr(T.FasterWhisperTranscriber, "is_available", staticmethod(lambda: True))
    assert isinstance(T.select_transcriber(), T.MlxWhisperTranscriber)


def test_select_falls_back_to_faster_on_linux(monkeypatch):
    monkeypatch.delenv("BUILDPILOT_TRANSCRIBER", raising=False)
    monkeypatch.setattr(T.MlxWhisperTranscriber, "is_available", staticmethod(lambda: False))
    monkeypatch.setattr(T.FasterWhisperTranscriber, "is_available", staticmethod(lambda: True))
    assert isinstance(T.select_transcriber(), T.FasterWhisperTranscriber)


def test_select_honours_override(monkeypatch):
    monkeypatch.setattr(T.MlxWhisperTranscriber, "is_available", staticmethod(lambda: True))
    monkeypatch.setenv("BUILDPILOT_TRANSCRIBER", "faster")
    assert isinstance(T.select_transcriber(), T.FasterWhisperTranscriber)
    monkeypatch.setenv("BUILDPILOT_TRANSCRIBER", "mlx")
    assert isinstance(T.select_transcriber(), T.MlxWhisperTranscriber)
