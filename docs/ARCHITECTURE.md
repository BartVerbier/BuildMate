# ARCHITECTURE

## Overview

Build Pilot is a local, two-device workflow:
- The iPhone is the capture device (thin client).
- The Mac is the processing engine during development.

No cloud infrastructure, no database, no accounts.

## Data Flow (implemented)

```text
iPhone                          Mac backend (FastAPI, port 8787)
──────                          ────────────────────────────────
Start Visit
  ├─ RoomCaptureSession         POST /sessions  (multipart)
  └─ AVAudioRecorder                 │
Finish Visit                         ▼
  ├─ CapturedRoom → JSON        1. Measurement Engine   (deterministic)
  └─ visit.m4a                       CapturedRoom JSON → areas (m²) + confidence
        │                       2. Transcription        (local MLX Whisper, free)
        └──── upload ──────►         audio.m4a → transcript.txt
                                3. Requirements Extract (Claude, 1 call/visit)
                                     transcript → typed RequirementExtraction
                                4. Deterministic Estimator (never AI)
                                     measurements + requirements + company
                                     profile → EstimateDraft (EUR)
        ◄──── session JSON ─────     │
Review draft estimate                ▼
                                sessions/<id>/  (session directory:
                                session.json, room.json, audio.m4a,
                                transcript.txt, estimate.json)
```

## Components

### iPhone app (`iphone/BuildPilot/`)
SwiftUI, three screens (start / scanning / estimate). RoomPlan owns LiDAR
and the camera; audio records alongside. The phone uploads raw captures
verbatim and displays the returned estimate. No processing on the phone.

### Backend (`backend/buildpilot/`)
- `pipelines/measurement.py` — parses CapturedRoom JSON defensively (both
  known encodings of enums/matrices), floor area from the scanned polygon
  with a wall-footprint fallback, area-weighted confidence, and notes
  explaining every non-obvious choice.
- `pipelines/transcription.py` — MLX Whisper on Apple Silicon; audio decoded
  with macOS `afconvert` (no ffmpeg). Zero API cost; audio never leaves the Mac.
- `pipelines/extraction.py` — the one paid AI call: Claude structured outputs
  produce the typed `RequirementExtraction` including the `PaintScope`
  booleans the estimator consumes.
- `pipelines/estimator.py` — pure function with documented rounding rules
  (Decision 13); emits an `assumptions` trail so every number is explainable.
- `pipeline.py` — orchestration with explicit degradation: measurement
  failure fails the session; transcription/extraction failures degrade to
  the default paint scope with a note.
- `server.py` — `POST /sessions` (synchronous, Decision 14),
  `GET /sessions` (list), `GET /sessions/{id}`, `GET /sessions/{id}/room`,
  `GET /sessions/{id}/transcript`, `GET /health`, and `GET /` — the Mac
  console (Decision 17): a local web dashboard with session list, pipeline
  status, floor-plan preview, transcript, requirements, estimate, and export.

## Degradation policy

The pipeline always completes if the scan is usable:

| Failure | Behaviour |
|---|---|
| Scan has no walls | Session marked `failed` with an error |
| No audio / Whisper unavailable | Default paint scope (walls + ceiling), noted |
| No API key / Claude error | Default paint scope, noted on the estimate |

The painter reviews every draft; degraded estimates say so explicitly.

## Design Principles

- Keep the system simple and local-first.
- Prefer native Apple capabilities over custom scanning implementations.
- Keep AI provider integration modular and replaceable.
- Metric units internally, everywhere; conversion only at the display layer (Decision 9).
- The phone uploads raw captures verbatim (Decision 10); all interpretation happens in the backend.
- Each visit is a self-contained session directory on disk; no database (Decision 11).
- AI is bounded to transcription (local) and requirements extraction (one API call); measurement and estimation are deterministic (Decision 12).

## Deployment Model

V1 development runs on an iPhone and a Mac on the same network. This is a
**development environment**, not the production architecture (Decision 21):
production is iPhone → internet → cloud backend. The app already talks only
to the `BackendClient` interface, and `BackendLocator.productionURL` is the
single switch that will point it at the cloud; the backend's storage seam
(`SessionStore`) is where object storage / a database replaces session
directories in the cloud milestone.
