# ARCHITECTURE

## Overview

Build Pilot is a two-device workflow:
- The iPhone is the capture device (thin client).
- A backend runs the whole deterministic pipeline and stores every artifact.

The backend runs in two shapes from the **same code** (Decision 28):
- **Local Mac** during development — Bonjour-discovered on the LAN, MLX Whisper,
  no auth.
- **Cloud (Railway)** for real testing — public URL, bearer-token auth,
  `faster-whisper`. Storage stays on the filesystem in both (no database,
  Decision 11).

No database and no user accounts in V1. Session state lives entirely in
per-visit directories on disk.

## Data Flow (implemented)

```text
iPhone                           Backend (FastAPI, port 8787 / Railway $PORT)
──────                           ────────────────────────────────────────────
Start Visit
  ├─ Customer form (name +       POST /sessions  (multipart)
  │   address required, D24)       room_scan  = CapturedRoom JSON (required)
  ├─ RoomCaptureSession            audio      = visit.m4a       (optional)
  ├─ AVAudioRecorder               poses      = camera pose log (optional)
  └─ ARKit camera poses                 │
Finish Visit                            ▼      Bearer-token gate (auth.py):
  ├─ CapturedRoom → JSON         every request but /health needs the token
  ├─ visit.m4a                   when BUILDPILOT_API_TOKEN is set; no-op locally
  └─ poses.json                         │
        │                               ▼
        └──── upload ──────►     1. Measurement Engine   (deterministic, required)
                                      CapturedRoom JSON → areas (m²) + confidence
                                 2. Transcription        (local Whisper, free)
                                      audio.m4a → transcript.txt (+ timed segments)
                                 3. Gaze resolution      (deterministic geometry)
                                      poses + segments + walls → "[facing wN]"
                                 4. Requirements Extract (Claude, 1 call/visit)
                                      transcript → typed RequirementExtraction
                                 5. Deterministic Estimator (never AI)
                                      measurements + requirements + company
                                      profile → EstimateDraft (EUR)
        ◄──── session JSON ─────       │
Review draft estimate                  ▼
        │                        sessions/<id>/  (session directory)
        ├─ Before photos ──────► POST /sessions/{id}/photos   (archive, best-effort)
        ├─ "Proposed Result" ──► POST /sessions/{id}/visualize (Gemini/Vertex render)
        └─ "Make Changes" ─────► POST /sessions/{id}/revise    (versioned re-estimate)
```

Processing is **synchronous** (Decision 14): `POST /sessions` runs the whole
pipeline and returns the completed `Session`. A dropped connection loses
nothing — every artifact is on disk and the phone re-fetches via
`GET /sessions/{id}`.

## Pipeline (backend/buildpilot/pipeline.py)

Deterministic orchestration with explicit degradation. Each stage writes its
output to the session directory as it completes, so a crashed run still leaves
inspectable artifacts.

1. **Measurement** (`pipelines/measurement.py`) — parses CapturedRoom JSON
   defensively (both known encodings of enums/matrices), floor area from the
   scanned polygon with a wall-footprint fallback, area-weighted confidence,
   and notes explaining every non-obvious choice. Required: failure fails the
   session.
2. **Transcription** (`pipelines/transcription.py`) — local Whisper, selected
   per platform by `select_transcriber()`: MLX Whisper on Apple Silicon
   (audio decoded with macOS `afconvert`, Decision 15), `faster-whisper` on
   Linux/Railway (pure CPU, decodes audio itself). Zero API cost; audio never
   leaves the host. When the transcriber exposes `transcribe_segments`, timed
   segments are kept (`segments.json`) to feed gaze; plain text degrades to
   room-level extraction.
3. **Gaze resolution** (`pipelines/gaze.py`, Decision 27) — pure deterministic
   geometry, never AI. Ray-casts the ARKit camera poses (`poses.json`, same
   world frame as the RoomPlan geometry) against the CapturedRoom wall
   rectangles, annotating each spoken segment with the wall the camera dwelled
   on ("[facing w2]", written to `gaze.json`) so the extractor can ground
   "this wall" in a real wall id. Enhancement only: any failure is logged and
   skipped, never blocks the visit. The same projection math scores how
   completely a wall fills a frame, which drives reference-photo selection for
   visualization.
4. **Requirements extraction** (`pipelines/extraction.py`, Decision 16) — the
   one paid AI call per visit: Claude structured outputs produce the typed
   `RequirementExtraction`, including the `PaintScope` booleans and
   `painted_wall_ids` the estimator consumes. The room's wall inventory is
   passed as context; `painted_wall_ids` the model returns are filtered to
   walls that actually exist.
5. **Estimation** (`pipelines/estimator.py`) — a pure function with documented
   rounding rules (Decision 13: litres rounded up to purchasable quantities,
   currency half-up to 2 dp). Emits an `assumptions` trail so every number is
   explainable. Never AI.

### Degradation policy

The pipeline always completes if the scan is usable:

| Failure | Behaviour |
|---|---|
| Scan has no walls | Session marked `failed` with an error |
| No audio / Whisper unavailable | Default paint scope (walls + ceiling), noted |
| No / malformed pose log | Gaze skipped; extraction runs on plain transcript |
| Gaze error | Logged in `raw_metadata`, extraction runs on plain transcript |
| No API key / Claude error | Default paint scope, noted on the estimate |

Any unexpected stage error is caught so a broken stage never returns a 500; the
session is marked `failed` instead. The painter reviews every draft; degraded
estimates say so explicitly.

## HTTP API (backend/buildpilot/server.py)

A single global bearer-token dependency (`Depends(require_token)`) guards every
route, so any endpoint added later is protected by default.

| Method + path | Purpose |
|---|---|
| `GET /health` | Status + stage availability; the only always-open path |
| `POST /sessions` | Multipart (`room_scan` JSON required, `audio`, `poses`); runs the pipeline synchronously, returns the completed session |
| `GET /sessions` | All sessions, newest first |
| `GET /sessions/{id}` | Re-fetch (reconnect after a dropped call) |
| `GET /sessions/{id}/room` | CapturedRoom JSON, verbatim |
| `GET /sessions/{id}/transcript` | Plain-text transcript (404 if none) |
| `POST /sessions/{id}/photos` | Archive a visit photo (`before`/`progress`/`after`) with optional capture time `t` (Decision 22) |
| `POST /sessions/{id}/revise` | Customer revision: transcribe change → LLM-merge → re-estimate → version (Decision 25) |
| `GET /sessions/{id}/versions` | List saved quote version numbers |
| `POST /sessions/{id}/versions/{v}/restore` | Restore an earlier version (itself versioned, so reversible) |
| `POST /sessions/{id}/visualize` | Render a "proposed result" (`stage=finished`) or "prepared room" (`stage=preparation`) image (Decision 23) |
| `GET /` | The Mac console (local web dashboard) |

### Authentication (backend/buildpilot/auth.py, Decision 28)

A single shared secret in the environment (`BUILDPILOT_API_TOKEN`), never in
the code or repo. **Unset → auth disabled** (local-LAN default, keeps every
test token-free). **Set → every request but `/health` must carry
`Authorization: Bearer <token>`**, compared in constant time; anything else is
`401`. Rotation is a value change on the deployment and the phone — no
persisted state, effective on the next request. This closes the threat of an
unauthenticated public URL spending real money on the AI endpoints.

### Revision & versioning (Decision 25)

`POST /sessions/{id}/revise` composes existing stages — no new pipeline stage.
The current session is first snapshotted to `versions/vNN.json`; the revision
audio is transcribed, the LLM merges the spoken changes into the current
requirements, the deterministic estimator re-runs, and the change summary
combines the LLM's scope bullets with deterministic price deltas
(`_estimate_deltas`). The estimator remains never-AI. Because a revision
changes the quote, the stale visualization is discarded and the response sets
`render_required` so the phone re-requests renders via `/visualize` — the
backend never renders a paid image the phone cannot download (Decision 26).

### Visualization (backend/buildpilot/pipelines/visualization.py, Decision 23)

Presentation AI only: it never influences measurements or the estimate, and it
degrades to `503` when unavailable. Takes the archived Before photo that best
shows the painted walls (chosen deterministically by projecting each photo's
camera pose through the scene — `_select_reference` + `gaze.py`; falls back to
the newest photo when pose data is missing) plus the extracted requirements,
and returns the same photo with only the requested finishes changed, via a
hosted instruction-based image-editing model (Gemini 2.5 Flash Image). It
refuses to render when requirements were not extracted from the conversation,
so a render never shows finishes nobody asked for.

## Components

### iPhone app (`iphone/BuildPilot/`)
SwiftUI. Flow: customer form → RoomPlan capture (LiDAR + camera + audio +
ARKit poses recorded together) → processing → read-back → draft estimate, with
Before photos, "Proposed Result" visualization, and "Make Changes" revision on
the estimate screen. The phone uploads raw captures verbatim and displays what
the backend returns; no interpretation on the device. It talks only to the
`BackendClient` protocol; `BackendLocator` selects the Bonjour-discovered Mac
(dev) or the production URL (cloud).

### Backend (`backend/buildpilot/`)
- `models/session.py` — the versioned `Session` Pydantic contract (metric, EUR),
  the single source of truth passed device → backend → device.
- `pipelines/` — `measurement`, `transcription`, `gaze`, `extraction`,
  `estimator`, `visualization`, and the stage protocols in `interfaces.py`.
- `pipeline.py` — orchestration with the degradation policy above.
- `server.py` — the FastAPI app and every endpoint.
- `auth.py` — the bearer-token gate.
- `session_store.py` — session-directory storage (Decision 11).
- `config.py` — the hard-coded V1 `DEFAULT_COMPANY_PROFILE` (EUR), modelled as
  a first-class estimator input so it becomes configurable later without
  touching estimation logic.
- `console.html` — the Mac console dashboard served at `/` (Decision 17).
- `__main__.py` — the launcher: loads `backend/.env`, materializes Vertex
  credentials from `GOOGLE_APPLICATION_CREDENTIALS_JSON` (Railway has no file
  upload), advertises Bonjour on macOS, and warms the Whisper model in the
  background.

### Session directory (backend/buildpilot/session_store.py)
Each visit is a self-contained folder (Decision 11) — replayable, diffable,
explainable, no database:

```text
sessions/<session_id>/
    session.json      # the Session record (source of truth; written atomically)
    room.json         # CapturedRoom JSON, verbatim from the phone
    audio.m4a         # visit audio (optional)
    poses.json        # ARKit camera pose log (optional)
    transcript.txt    # transcription stage
    segments.json     # timed transcript segments (when available)
    gaze.json         # per-segment wall annotations
    estimate.json     # estimation stage (also embedded in session.json)
    photos/           # before-/progress-/after-NN.jpg (+ photo-times.json),
                      #   plus visualization-/preparation-NN.jpg renders
    versions/         # vNN.json snapshots for revision/restore
```

## Design Principles

- Keep the system simple and local-first; the same code scales to the cloud
  behind auth and a platform-appropriate transcriber.
- Prefer native Apple capabilities over custom scanning implementations.
- Keep AI provider integration modular and replaceable (behind stage protocols).
- Metric units internally, everywhere; conversion only at the display layer
  (Decision 9).
- The phone uploads raw captures verbatim (Decision 10); all interpretation
  happens in the backend.
- Each visit is a self-contained session directory on disk; no database
  (Decision 11).
- AI is bounded to transcription (local), requirements extraction (one API
  call), and presentation-only visualization (Decisions 12 & 23). Measurement,
  gaze, and estimation are deterministic and never AI.

## Deployment Model

Two shapes of the same backend (Decision 28):

- **Development:** iPhone + Mac on the same network. The Mac advertises
  `_buildpilot._tcp` via Bonjour (Decision 19) so the app finds it with no IP
  entry; MLX Whisper; auth disabled.
- **Cloud (Railway):** iPhone → internet → backend. Root directory `backend/`;
  started via `Procfile`/`railway.toml` (`--no-warmup` so the health check
  goes green before the model loads); `faster-whisper`; bearer auth enabled;
  Vertex/Gemini credentials from the environment. Storage is still the
  filesystem — the `SessionStore` seam is where object storage / a database
  would replace session directories in a later milestone.

The app already talks only to the `BackendClient` interface, and
`BackendLocator.productionURL` is the single switch that points it at the cloud.
