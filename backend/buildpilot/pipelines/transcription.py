"""Local Whisper transcription via MLX (Apple Silicon). Zero API cost.

The visit audio never leaves the Mac (docs/DECISIONS.md, Decision 12).
Model weights download from Hugging Face on first use and are cached locally.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import wave
from pathlib import Path

DEFAULT_WHISPER_MODEL = "mlx-community/whisper-base-mlx"
WHISPER_SAMPLE_RATE = 16_000


class TranscriptionError(RuntimeError):
    """Raised when transcription cannot run (missing file, missing runtime)."""


class MlxWhisperTranscriber:
    """Transcribes visit audio with mlx-whisper.

    The mlx_whisper import is deferred so that machines without MLX (or test
    runs that inject a fake) never pay the import cost.
    """

    def __init__(self, model_name: str | None = None) -> None:
        self.model_name = model_name or os.environ.get(
            "BUILDPILOT_WHISPER_MODEL", DEFAULT_WHISPER_MODEL
        )

    @staticmethod
    def is_available() -> bool:
        try:
            import mlx_whisper  # noqa: F401
        except ImportError:
            return False
        return True

    def transcribe(self, audio_path: Path) -> str:
        if not audio_path.exists():
            raise TranscriptionError(f"Audio file not found: {audio_path}")
        try:
            import mlx_whisper
        except ImportError as exc:
            raise TranscriptionError(
                "mlx-whisper is not installed; install it or configure a fake transcriber"
            ) from exc
        samples = _decode_audio(audio_path)
        result = mlx_whisper.transcribe(samples, path_or_hf_repo=self.model_name)
        return (result.get("text") or "").strip()


def _decode_audio(audio_path: Path):
    """Decode any Apple-supported audio file to 16 kHz mono float32 samples.

    Uses macOS's built-in `afconvert` instead of requiring ffmpeg — one fewer
    third-party dependency, and the formats we receive (m4a from AVFoundation)
    are exactly the ones afconvert handles natively.
    """
    import numpy as np

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        wav_path = Path(tmp.name)
    try:
        try:
            subprocess.run(
                [
                    "afconvert",
                    "-f", "WAVE",
                    "-d", f"LEI16@{WHISPER_SAMPLE_RATE}",
                    "-c", "1",
                    str(audio_path),
                    str(wav_path),
                ],
                check=True,
                capture_output=True,
            )
        except (subprocess.CalledProcessError, FileNotFoundError) as exc:
            detail = exc.stderr.decode(errors="replace") if getattr(exc, "stderr", None) else str(exc)
            raise TranscriptionError(f"afconvert failed to decode {audio_path.name}: {detail}") from exc
        with wave.open(str(wav_path), "rb") as wav:
            frames = wav.readframes(wav.getnframes())
        return np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
    finally:
        wav_path.unlink(missing_ok=True)
