# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

## Working agreement (Claude Code-specific)

- Work milestone by milestone per [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).
  After completing a milestone: explain what was built, why, alternatives,
  tradeoffs, and remaining risks — then STOP and wait for founder approval.
- When architecture changes, update every affected document in the same change.
  Code and docs must never drift apart. [docs/DECISIONS.md](docs/DECISIONS.md)
  is the numbered decision log; the code references decisions by number
  (e.g. "Decision 9") — keep those references accurate.

## Hard product invariants

These are load-bearing. Violating one is a correctness bug, not a style choice.

- **The estimate engine is never AI.** AI is bounded to exactly two stages:
  transcription (local Whisper) and requirements extraction (one Claude call
  per visit). Measurement, gaze resolution, and estimation are pure
  deterministic code. Visualization AI (Decision 23) is presentation-only and
  must never influence a measurement or a number in the estimate.
- **Metric internally, permanently** (Decision 9). Field names encode units
  (`_m2`, `_litres`, `_eur`). Currency is EUR. Imperial units may exist only
  in a display-layer conversion, nowhere else.
- **The phone uploads Apple's `CapturedRoom` JSON verbatim** (Decision 10) —
  no transformation, no unit conversion on the device. All interpretation
  happens in the backend.
- **Every number in an estimate must be explainable from its inputs.** The
  estimator emits an `assumptions` trail; keep it truthful.
- Naming: the product is **Build Pilot**. **BuildMate** is an internal legacy
  codename that still appears in some runtime strings and identifiers (Bonjour
  service name `BuildMate on <host>`, auth docstrings, bundle id
  `com.buildpilot.BuildPilot`, package `buildpilot`, Bonjour type
  `_buildpilot._tcp`). This is a known naming inconsistency, not two systems.
  **Do not rename anything** — Bonjour services, bundle identifiers, runtime
  strings, source files, and APIs are load-bearing (renaming breaks
  provisioning, permissions, and installs). A future branding pass will resolve
  this; until then, treat every `buildpilot`/`BuildMate` identifier as
  intentional.

## Commands

Backend (run from `backend/`, using the repo venv at `.venv/`):

```bash
# One-time setup (Apple Silicon Mac): installs MLX Whisper via the whisper extra
../.venv/bin/pip install -e ".[dev,whisper]"

# Run the full test suite — REQUIRED before presenting any milestone as done
../.venv/bin/python -m pytest

# A single test file / test
../.venv/bin/python -m pytest tests/test_estimator.py
../.venv/bin/python -m pytest tests/test_estimator.py::test_name

# Include the gated real-Whisper integration test (slow, downloads a model)
BUILDPILOT_RUN_WHISPER_TESTS=1 ../.venv/bin/python -m pytest

# Run the server (port 8787; Bonjour-advertises to the iPhone; Mac console at http://localhost:8787/)
../.venv/bin/python -m buildpilot
../.venv/bin/python -m buildpilot --reload      # dev: auto-restart on code change

# Exercise the pipeline without a phone
curl -F "room_scan=@tests/fixtures/synthetic_room_5x3.json" http://localhost:8787/sessions
```

iOS app (requires Xcode + a LiDAR iPhone — the Simulator cannot run RoomPlan):

```bash
cd iphone/BuildPilot
xcodegen generate     # the .xcodeproj is generated from project.yml, not committed
open BuildPilot.xcodeproj
```

## Architecture (the big picture)

Two devices, no cloud/database/accounts in V1: the **iPhone is a thin capture
client**, the **Mac backend runs the whole deterministic pipeline**. Full
detail in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

Data flow: the phone captures RoomPlan geometry + audio + ARKit camera poses,
uploads them raw via `POST /sessions` (multipart), and displays the returned
draft. The backend pipeline ([backend/buildpilot/pipeline.py](backend/buildpilot/pipeline.py))
runs the stages in order, writing each artifact to the session directory as it
completes:

1. **measurement** (`pipelines/measurement.py`) — CapturedRoom JSON → areas
   (m²) + confidence. Deterministic geometry.
2. **gaze** (`pipelines/gaze.py`) — ray-casts ARKit camera poses against wall
   rectangles so "this wall" in the transcript grounds to real geometry.
   Deterministic.
3. **transcription** (`pipelines/transcription.py`) — local Whisper; MLX on
   Apple Silicon, `faster-whisper` on Linux (selected by platform marker in
   `pyproject.toml`). Free, audio never leaves the machine.
4. **extraction** (`pipelines/extraction.py`) — the one paid AI call: Claude
   structured output → typed `RequirementExtraction`.
5. **estimator** (`pipelines/estimator.py`) — pure function; measurements +
   requirements + `CompanyProfile` → `EstimateDraft`.

Key seams:
- **Degradation policy** lives in `pipeline.py`: a scan with no walls fails the
  session; missing audio/Whisper or missing API key degrade to the default
  paint scope with a note. The pipeline always completes if the scan is usable.
- **Stage interfaces** (`pipelines/interfaces.py`) — every stage is behind a
  protocol so AI providers are modular/replaceable.
- **Session contract** (`models/session.py`) — the versioned Pydantic model
  that is the source of truth passed device→backend→device.
- **Storage** (`session_store.py`) — each visit is a self-contained directory
  on disk (Decision 11): `session.json`, `room.json`, `audio.m4a`,
  `transcript.txt`, `estimate.json`. This is the seam a cloud DB replaces later.
- **Company profile** (`config.py`) — hard-coded `DEFAULT_COMPANY_PROFILE`
  (rates, coverage, margins) but modelled as a first-class estimator input so
  it becomes configurable without touching estimation logic.
- **Auth** (`auth.py`) — bearer token via `BUILDPILOT_API_TOKEN`. Unset =
  disabled (local LAN default, keeps tests token-free); set = every request
  except `/health` needs `Authorization: Bearer`. This is the production switch.
- **Cloud switch** on the phone is `BackendLocator.productionURL` in
  `BackendClient.swift`; the app talks only to the `BackendClient` protocol.

Beyond the core estimate flow the server also exposes visit **revision**
(`/sessions/{id}/revise`, `/versions`, `/versions/{v}/restore`), **photo**
archival, and **visualization** (`/sessions/{id}/visualize`, `pipelines/visualization.py`) —
an instruction-based image edit of a Before photo (Gemini/Vertex), presentation-only.

## Configuration (all env vars optional; see [backend/README.md](backend/README.md))

`ANTHROPIC_API_KEY` enables extraction; `BUILDPILOT_EXTRACTOR_MODEL` picks the
model; `BUILDPILOT_WHISPER_MODEL` the local Whisper model;
`BUILDPILOT_SESSIONS_DIR` the storage root; `BUILDPILOT_API_TOKEN` enables auth;
`GOOGLE_CLOUD_PROJECT`/`GEMINI_API_KEY` enable visualization. Local secrets go
in `backend/.env` (gitignored, loaded at startup). Railway deploys from
`backend/` via `Procfile`/`railway.toml` with `--no-warmup`.

## Product Vision

Build Pilot exists to help contractors produce a professional estimate during
the first customer visit — scan the room, talk through the job, and hand over a
credible draft quote before leaving. V1 is deliberately narrow: painting
companies only.

Design principles:
- Deterministic whenever correctness matters.
- AI only where interpretation or creativity adds value.
- Contractor-first UX.
- Speed on-site.
- Accuracy over cleverness.
- Simplicity before features.
- The estimate engine is never AI.

## Current Project Status

**Backend**
- Deployed on Railway.
- Bearer-token authentication enabled (public deployment).
- Gemini integration (visualization).
- Anthropic integration (requirements extraction).
- Production backend operational.

**iPhone**
- Verified against the production backend over 5G.
- Local development (Mac backend over LAN) still supported.

**Distribution**
- Apple Developer enrollment pending activation.
- TestFlight not yet configured.

**Current priority — DO NOT add new features.**

The current objective is to get the first external tester (Ariana) using the
app through TestFlight. Feature work resumes only after external testing has
begun.
