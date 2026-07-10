# Backend

Local backend for Build Pilot: the deterministic pipeline that turns a room
scan and visit audio into a draft estimate.

## Setup

```bash
cd backend
python3 -m venv ../.venv          # or reuse the existing repo venv
../.venv/bin/pip install -e ".[dev,whisper]"
```

The `whisper` extra installs MLX Whisper (Apple Silicon). Without it the
pipeline still runs — transcription degrades gracefully and the estimate uses
the default paint scope.

## Configuration (environment variables, all optional)

| Variable | Default | Purpose |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | Enables the requirements extractor (the only paid AI call, one per visit). Without it the pipeline degrades to the default paint scope. |
| `BUILDPILOT_EXTRACTOR_MODEL` | `claude-opus-4-8` | Extractor model (e.g. `claude-haiku-4-5` to cut cost). |
| `BUILDPILOT_WHISPER_MODEL` | `mlx-community/whisper-base-mlx` | Local Whisper model (downloads from Hugging Face on first use). |
| `BUILDPILOT_SESSIONS_DIR` | `backend/sessions/` | Where session directories are stored. |

## Run the server

```bash
cd backend
../.venv/bin/python -m buildpilot
```

This serves on port 8787 and advertises the backend on the local network via
Bonjour (`_buildpilot._tcp`, using macOS's built-in `dns-sd`), so the iPhone
app finds this Mac automatically — no IP addresses to type. Options:
`--port`, `--host`.

## Mac console

Open **http://localhost:8787/** in a browser while the server runs: session
list, processing pipeline, top-down floor plan from the scan, transcript,
requirements, the draft estimate with its calculation trail, and export
links. It refreshes automatically as visits arrive from the phone.

## API

- `GET /` — the Mac console (local web dashboard)
- `GET /health` — status + stage availability
- `POST /sessions` — multipart (`room_scan` JSON, optional `audio` m4a);
  runs the pipeline synchronously and returns the completed session
- `GET /sessions` — all sessions, newest first
- `GET /sessions/{id}` — re-fetch (recovery after a dropped connection)
- `GET /sessions/{id}/room` — the CapturedRoom JSON, verbatim
- `GET /sessions/{id}/transcript` — plain-text transcript (404 if none)
- `POST /sessions/{id}/photos` — archive a visit photo (multipart `photo` +
  `kind`: before/progress/after) into the session directory

Try it without a phone:

```bash
curl -F "room_scan=@tests/fixtures/synthetic_room_5x3.json" http://localhost:8787/sessions
```

## Run tests

```bash
cd backend
../.venv/bin/python -m pytest                        # fast suite
BUILDPILOT_RUN_WHISPER_TESTS=1 ../.venv/bin/python -m pytest   # + real Whisper
```

## Structure

- `buildpilot/models/` — versioned session contract (metric, EUR — Decision 9)
- `buildpilot/pipelines/` — measurement, transcription, extraction, estimator
- `buildpilot/pipeline.py` — orchestrator with explicit degradation policy
- `buildpilot/session_store.py` — session-directory storage (Decision 11)
- `buildpilot/server.py` — FastAPI app
- `tests/` — 38 tests + gated real-Whisper integration test
