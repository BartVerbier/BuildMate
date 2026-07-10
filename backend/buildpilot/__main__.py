"""Run the Build Pilot backend:

    python -m buildpilot [--port 8787] [--host 0.0.0.0]

- Advertises the server via Bonjour (`_buildpilot._tcp`, macOS built-in
  `dns-sd`) so the iPhone app finds the Mac automatically.
- Warms the Whisper model in the background so the first real visit never
  pays the model-download / compile cost.
- Logs to the terminal and to `<sessions dir>/buildpilot.log` for field
  diagnostics.
"""

from __future__ import annotations

import argparse
import logging
import os
import shutil
import socket
import subprocess
import threading
import time
from pathlib import Path

import uvicorn

logger = logging.getLogger("buildpilot")


def sessions_root() -> Path:
    configured = os.environ.get("BUILDPILOT_SESSIONS_DIR")
    if configured:
        return Path(configured)
    return Path(__file__).resolve().parents[1] / "sessions"


def configure_logging() -> Path:
    root = sessions_root()
    root.mkdir(parents=True, exist_ok=True)
    log_file = root / "buildpilot.log"
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        handlers=[logging.StreamHandler(), logging.FileHandler(log_file)],
    )
    return log_file


def advertise(port: int) -> subprocess.Popen | None:
    if shutil.which("dns-sd") is None:  # non-macOS dev machine: skip quietly
        return None
    hostname = socket.gethostname().removesuffix(".local")
    return subprocess.Popen(
        ["dns-sd", "-R", f"Build Pilot on {hostname}", "_buildpilot._tcp", "local", str(port)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def warm_up_whisper() -> None:
    """Background thread: pre-load the Whisper model before the first visit."""
    from buildpilot.pipelines.transcription import MlxWhisperTranscriber

    if not MlxWhisperTranscriber.is_available():
        logger.warning("mlx-whisper not installed — transcription will degrade")
        return
    try:
        started = time.perf_counter()
        MlxWhisperTranscriber().warm_up()
        logger.info("Whisper warm-up done in %.1fs — first visit will be fast", time.perf_counter() - started)
    except Exception:  # warm-up must never take the server down
        logger.exception("Whisper warm-up failed — first transcription will be slow")


def main() -> None:
    parser = argparse.ArgumentParser(description="Build Pilot local backend")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--no-warmup", action="store_true", help="skip Whisper warm-up")
    args = parser.parse_args()

    log_file = configure_logging()
    logger.info("Console: http://localhost:%d/  ·  Log file: %s", args.port, log_file)

    bonjour = advertise(args.port)
    if bonjour:
        logger.info("Advertising on the local network — the iPhone app will find this Mac automatically.")

    if not args.no_warmup:
        threading.Thread(target=warm_up_whisper, name="whisper-warmup", daemon=True).start()

    if not os.environ.get("ANTHROPIC_API_KEY") and not os.environ.get("ANTHROPIC_AUTH_TOKEN"):
        logger.warning(
            "No ANTHROPIC_API_KEY set — requirements extraction will degrade to the default paint scope."
        )

    try:
        uvicorn.run("buildpilot.server:app", host=args.host, port=args.port, log_level="info")
    finally:
        if bonjour:
            bonjour.terminate()


if __name__ == "__main__":
    main()
