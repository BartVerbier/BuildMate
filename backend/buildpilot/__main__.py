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


def load_env_file() -> list[str]:
    """Loads backend/.env (KEY=VALUE lines) into the environment if present.

    Keeps API keys out of shell profiles and the repo (.env is gitignored).
    Existing environment variables always win. No dependency needed.
    """
    env_path = Path(__file__).resolve().parents[1] / ".env"
    loaded: list[str] = []
    if not env_path.exists():
        return loaded
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key, value = key.strip(), value.strip().strip("'\"")
        if key and value and key not in os.environ:
            os.environ[key] = value
            loaded.append(key)
    # A relative service-account path in .env should resolve against
    # backend/, not whatever directory the server was launched from.
    creds = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if creds and not Path(creds).is_absolute():
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = str(env_path.parent / creds)
    return loaded


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
    # Self-heal: kill any stray registration from a previous run. An orphaned
    # dns-sd advertises a dead port and makes the iPhone see a phantom
    # duplicate Mac ("... (2)") that can never connect.
    subprocess.run(["pkill", "-f", "dns-sd -R BuildMate"], capture_output=True)
    time.sleep(0.5)  # let mDNS drop the stale name before re-registering
    hostname = socket.gethostname().removesuffix(".local")
    return subprocess.Popen(
        ["dns-sd", "-R", f"BuildMate on {hostname}", "_buildpilot._tcp", "local", str(port)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def warm_up_whisper() -> None:
    """Background thread: pre-load whichever Whisper backend this host uses."""
    from buildpilot.pipelines.transcription import select_transcriber

    transcriber = select_transcriber()
    if not hasattr(transcriber, "warm_up") or not type(transcriber).is_available():
        logger.warning(
            "No Whisper backend installed (%s) — transcription will degrade to default scope",
            type(transcriber).__name__,
        )
        return
    try:
        started = time.perf_counter()
        transcriber.warm_up()
        logger.info(
            "%s warm-up done in %.1fs — first visit will be fast",
            type(transcriber).__name__, time.perf_counter() - started,
        )
    except Exception:  # warm-up must never take the server down
        logger.exception("Whisper warm-up failed — first transcription will be slow")


def materialize_google_credentials() -> bool:
    """Railway has no file upload: if the service-account key is provided as
    JSON in GOOGLE_APPLICATION_CREDENTIALS_JSON, write it to a temp file and
    point GOOGLE_APPLICATION_CREDENTIALS at it (what google-auth expects).
    Local development keeps using the file path directly. Returns True when a
    credential file was materialized."""
    import tempfile

    raw = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS_JSON")
    if not raw:
        return False
    if os.environ.get("GOOGLE_APPLICATION_CREDENTIALS"):
        return False  # an explicit path already wins
    fd, path = tempfile.mkstemp(prefix="vertex-", suffix=".json")
    with os.fdopen(fd, "w") as handle:
        handle.write(raw)
    os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = path
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description="Build Pilot local backend")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--no-warmup", action="store_true", help="skip Whisper warm-up")
    parser.add_argument(
        "--reload", action="store_true",
        help="dev: auto-restart when backend code changes (a stale server "
             "silently 404s new endpoints — this prevents that)",
    )
    args = parser.parse_args()

    loaded_keys = load_env_file()
    log_file = configure_logging()
    logger.info("Console: http://localhost:%d/  ·  Log file: %s", args.port, log_file)
    if loaded_keys:
        logger.info("Loaded from backend/.env: %s", ", ".join(loaded_keys))
    if materialize_google_credentials():
        logger.info("Vertex credentials materialized from GOOGLE_APPLICATION_CREDENTIALS_JSON")
    if os.environ.get("BUILDPILOT_API_TOKEN"):
        logger.info("Bearer-token authentication ENABLED (public deployment).")
    else:
        logger.info("Bearer-token authentication disabled (local development).")

    bonjour = advertise(args.port)
    if bonjour:
        logger.info("Advertising on the local network — the iPhone app will find this Mac automatically.")

    if not args.no_warmup:
        threading.Thread(target=warm_up_whisper, name="whisper-warmup", daemon=True).start()

    if not os.environ.get("ANTHROPIC_API_KEY") and not os.environ.get("ANTHROPIC_AUTH_TOKEN"):
        logger.warning(
            "No ANTHROPIC_API_KEY set — requirements extraction will degrade to the default paint scope."
        )
    if os.environ.get("GOOGLE_CLOUD_PROJECT"):
        logger.info(
            "Visualization via Vertex AI (project %s) — bills Google Cloud credits.",
            os.environ["GOOGLE_CLOUD_PROJECT"],
        )
    elif os.environ.get("GEMINI_API_KEY"):
        logger.info("Visualization via Gemini Developer API (AI Studio prepay billing).")
    else:
        logger.warning(
            "No GOOGLE_CLOUD_PROJECT or GEMINI_API_KEY set — the proposed-result "
            "visualization will be unavailable."
        )

    try:
        uvicorn.run(
            "buildpilot.server:app", host=args.host, port=args.port,
            log_level="info", reload=args.reload,
        )
    finally:
        if bonjour:
            bonjour.terminate()


if __name__ == "__main__":
    main()
