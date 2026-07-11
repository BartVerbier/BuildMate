"""Local Whisper transcription. Zero API cost; audio never leaves the host.

Two interchangeable backends behind the same Transcriber protocol:

- MlxWhisperTranscriber — MLX on Apple Silicon (the Mac dev environment).
  Fast; decodes m4a with macOS's built-in `afconvert`.
- FasterWhisperTranscriber — CTranslate2 on CPU (Linux / Railway). Decodes
  audio itself via its bundled PyAV/ffmpeg, so it needs no system binary.

select_transcriber() picks the right one for the host (or honours the
BUILDPILOT_TRANSCRIBER override), so the deployment target — not the code —
decides. Model weights download on first use and are cached locally.
"""

from __future__ import annotations

import logging
import os
import subprocess
import tempfile
import wave
from pathlib import Path

logger = logging.getLogger(__name__)

DEFAULT_WHISPER_MODEL = "mlx-community/whisper-base-mlx"
DEFAULT_FASTER_WHISPER_MODEL = "base"
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

    def warm_up(self) -> None:
        """Force model download and MLX compilation ahead of the first visit
        by transcribing a fraction of a second of silence. Called from a
        background thread at server startup so the first real transcription
        never pays the cold-start cost during a customer visit."""
        import numpy as np

        try:
            import mlx_whisper
        except ImportError:
            return
        mlx_whisper.transcribe(
            np.zeros(WHISPER_SAMPLE_RATE // 10, dtype=np.float32),
            path_or_hf_repo=self.model_name,
        )

    def transcribe(self, audio_path: Path) -> str:
        text, _segments = self.transcribe_segments(audio_path)
        return text

    def transcribe_segments(self, audio_path: Path) -> tuple[str, list[dict]]:
        """Transcript text plus Whisper's timed segments
        ([{start, end, text}], seconds from the start of the recording) —
        the timeline that lets gaze resolution ground words in geometry."""
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
        segments = [
            {
                "start": float(s.get("start", 0.0)),
                "end": float(s.get("end", 0.0)),
                "text": (s.get("text") or "").strip(),
            }
            for s in result.get("segments") or []
            if (s.get("text") or "").strip()
        ]
        return (result.get("text") or "").strip(), segments


class FasterWhisperTranscriber:
    """Transcribes visit audio with faster-whisper (CTranslate2, CPU).

    The Linux/Railway backend: pure-Python wheels, no Apple Silicon, and it
    decodes the m4a itself (bundled PyAV), so no `afconvert`/ffmpeg binary is
    required. The import and the model load are deferred and the model is
    cached per process — the first visit pays the load, later visits are warm.
    """

    _model_cache: dict = {}

    def __init__(self, model_name: str | None = None) -> None:
        self.model_name = model_name or os.environ.get(
            "BUILDPILOT_WHISPER_MODEL", DEFAULT_FASTER_WHISPER_MODEL
        )

    @staticmethod
    def is_available() -> bool:
        try:
            import faster_whisper  # noqa: F401
        except ImportError:
            return False
        return True

    def _model(self):
        if self.model_name not in self._model_cache:
            from faster_whisper import WhisperModel

            # int8 keeps memory and CPU modest on a small Railway instance.
            self._model_cache[self.model_name] = WhisperModel(
                self.model_name, device="cpu", compute_type="int8"
            )
        return self._model_cache[self.model_name]

    def warm_up(self) -> None:
        """Load the model ahead of the first visit (background thread)."""
        try:
            self._model()
        except Exception:  # warm-up must never take the server down
            logger.exception("faster-whisper warm-up failed — first visit will be slow")

    def transcribe(self, audio_path: Path) -> str:
        return self.transcribe_segments(audio_path)[0]

    def transcribe_segments(self, audio_path: Path) -> tuple[str, list[dict]]:
        if not audio_path.exists():
            raise TranscriptionError(f"Audio file not found: {audio_path}")
        try:
            import faster_whisper  # noqa: F401
        except ImportError as exc:
            raise TranscriptionError(
                "faster-whisper is not installed; install it or configure another transcriber"
            ) from exc
        segments_iter, _info = self._model().transcribe(str(audio_path))
        segments = [
            {"start": float(s.start), "end": float(s.end), "text": s.text.strip()}
            for s in segments_iter
            if s.text and s.text.strip()
        ]
        text = " ".join(s["text"] for s in segments).strip()
        return text, segments


def select_transcriber():
    """The transcriber for this host.

    BUILDPILOT_TRANSCRIBER forces a backend ("mlx" or "faster"); otherwise
    prefer MLX (the Mac dev box), fall back to faster-whisper (Railway). The
    MLX fallback still raises a clear TranscriptionError when nothing is
    installed, so the pipeline degrades to the default scope as designed.
    """
    forced = (os.environ.get("BUILDPILOT_TRANSCRIBER") or "").strip().lower()
    if forced == "mlx":
        return MlxWhisperTranscriber()
    if forced == "faster":
        return FasterWhisperTranscriber()
    if MlxWhisperTranscriber.is_available():
        return MlxWhisperTranscriber()
    if FasterWhisperTranscriber.is_available():
        return FasterWhisperTranscriber()
    return MlxWhisperTranscriber()


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
