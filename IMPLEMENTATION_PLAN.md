# IMPLEMENTATION_PLAN

## Status

**Prototype branch (`prototype-v1`):** Milestones 1–5 built end-to-end; the
backend is deployed on Railway with bearer auth, Anthropic extraction, and
Gemini/Vertex visualization, and the iPhone app has been verified against it
over 5G. Backend suite: 110 tests + a gated real-Whisper integration test.

**Pre-TestFlight sequencing (Decision 29, 2026-07-12):** M1 (reliability,
confidence engine, contractor identity, secret hygiene) ✅ complete; the
manual measurement-editing flagship shipped as EditPlanView. The remainder of
that sequencing is **superseded by the 2026-09-01 plan below.**

## The 2026-09-01 plan — accuracy-first road to the App Store

Founder-approved. Two fixed points: ground-truth measuring starts 2026-09-02
(the founder lasers real rooms daily — docs/GROUND_TRUTH_PROTOCOL.md), and
the end state is a professional-grade App Store release. Every milestone ends
with a founder hard stop.

**Foundation (night of 2026-09-01):** everything committed and pushed; CI on
every push; scan-intake tool (`backend/tools/pull_scan.py`) bridging job
sites to the corpus; ground-truth harness live (asserts a COMPLETE verdict is
within tolerance AND an out-of-tolerance scan flagged itself); App Store
version automation (`bump-build.sh`); estimator completeness gate built
behind the corpus's evidence before deploying.

- **A — Prove the engine** (gated on ~8 laser-measured rooms): accuracy
  report per engine version; deploy Decision 34 + the completeness gate on
  evidence; test an iOS 18 deployment target against the same rooms
  (RoomPlan wall handling improved in iOS 18); set the internal tolerance.
- **B — Guided per-wall capture:** promote the AR continuity spike into the
  capture flow (wall checklist, closure detection, targeted rescans). Exit is
  measured, not vibed: pattern-A field scans close the loop on most rooms and
  every COMPLETE verdict sits inside the milestone-A tolerance.
- **C — Protection time:** derived from the founder's 22 years of painting
  (fixed/movable object counts already measured per scan), validated against
  the painter_estimate recorded with every ground-truth room.
- **D — Professional finish:** M2 design pass, real copy (lighting-gate
  placeholders), onboarding, every error state. Then TestFlight (founder,
  boss, Ariana).
- **E — App Store structural work:** per-user auth replacing the baked-in
  shared token (the ContractorResolver seam exists for this); in-app
  recording-consent step (App Review + EU law); the Build Pilot/BuildMate
  naming decision; privacy policy, nutrition labels, support page.
- **F — Whole-wall before/after:** deliberately last — most expensive, least
  certain, and the one milestone real usage may legitimately resize.
  wall_projection.py (Stage 0) is the validated foundation.

Standing discipline: engine changes land with a fixture proving them against
laser truth; docs update in the same commit as architecture changes; push
daily; the hard product invariants in CLAUDE.md stay inviolate.

## Architecture Summary

- The iPhone is a thin capture client: RoomPlan + audio, uploaded raw.
- The Mac backend runs a deterministic pipeline over each session:
  measurement → transcription → requirements extraction → estimation.
- AI is bounded to transcription (local Whisper) and requirements
  extraction (one small LLM call). Measurement and estimation are never AI.
- Sessions are self-contained directories; no database in V1.
- Units are metric internally, permanently (docs/DECISIONS.md, Decision 9).

## Milestones

### Milestone 1 — Foundational Session Contract and Scaffolding ✅ complete

(Absorbed the former Milestone 0 — the two were near-duplicates.)

Delivered:
- versioned Session contract and core domain models (Pydantic)
- pipeline stage interfaces
- backend scaffolding and foundational tests

### Milestone 1.5 — Foundation Repair and Real Capture Data ✅ complete (scans pending)

Objective:
- Fix foundation defects found in the 2026-07-10 architectural review
  before building the measurement engine on top of them.

Delivered:
- repository under git with a proper .gitignore
- `pyproject.toml` packaging; reproducible env via `pip install -e ".[dev]"`
- package renamed `app` → `buildpilot`; sys.path hack removed
- single pipeline interface module (duplicate abstraction deleted)
- metric-unit contract: `_m2`, `_litres`, `_eur` field names; EUR currency
- `room_scan` field added to Session (CapturedRoom JSON verbatim)
- timestamps as validated datetimes; correct audio MIME type
- dead test assertion fixed; tests rewritten with real assertions
- `samples/` created with capture checklist; capture-spike instructions in
  `iphone/README.md`
- CLAUDE.md added (imports AGENTS.md per current Claude Code practice)

Remaining (founder task, requires physical device):
- capture ≥3 real rooms with Apple's RoomPlan sample app and commit the
  CapturedRoom JSON exports to `samples/rooms/`

### Milestone 2 — Measurement Engine ✅ built (prototype branch)

Objective:
- Convert CapturedRoom JSON into structured measurements with confidence.

Deliverables:
- deterministic measurement engine: gross/net wall area, ceiling, floor,
  door, window, and paintable surface areas (m²), confidence score
- golden-file tests against the real scans in `samples/rooms/`
- simple debug output for manual review

Dependencies:
- Milestone 1.5 complete, including the real room scans

Estimated effort: 4 to 6 engineer-days

Risks:
- geometry quality varies by scan quality
- measurement logic will require iteration against real-world examples

Definition of Done:
- structured measurements produced from every sample scan
- outputs are consistent, explainable, and reviewable

### Milestone 3 — Conversation Understanding ✅ built (prototype branch)

Objective:
- Convert the visit conversation into structured requirements.

Deliverables:
- local Whisper transcription path (mlx-whisper or whisper.cpp)
- LLM requirements extractor behind a narrow adapter
- structured scope, exclusions, preparation, and special notes

Dependencies:
- Milestone 1.5 complete

Estimated effort: 3 to 5 engineer-days

Definition of Done:
- recorded audio produces structured requirements in a stable format
- low-confidence or empty transcripts are handled gracefully

### Milestone 4 — Deterministic Estimate Generation ✅ built (prototype branch)

Objective:
- Produce a draft estimate from measurements, requirements, and a default
  company profile.

Deliverables:
- hard-coded default CompanyProfile for V1 (EUR)
- estimation engine with explicit rounding rules (litres rounded up to
  purchasable quantities; currency rounded half-up to 2 dp)
- draft estimate output contract

Dependencies:
- Milestones 2 and 3 complete

Estimated effort: 3 to 5 engineer-days

Definition of Done:
- a draft estimate is generated from sample data without manual intervention
- every number in the estimate is explainable from its inputs

### Milestone 5 — iPhone Capture App ✅ built, ⏳ device-untested (prototype branch)

Objective:
- The real capture client: Start Visit / Finish Visit.

Deliverables:
- SwiftUI app: RoomCaptureSession + AVAudioRecorder started together
  (RoomPlan already owns LiDAR and camera — there is no separate LiDAR step)
- session bundle upload (multipart HTTP: session.json + room.json + audio.m4a)
  to the Mac backend over the local network
- estimate review screen showing the returned draft

Dependencies:
- Milestones 2–4 complete (backend can process an uploaded session end to end)

Estimated effort: 5 to 7 engineer-days

Definition of Done:
- a painter can run the full workflow on a physical device against the Mac

### Milestone 6 — Review, Hardening, and Reliability

Objective:
- Make the workflow dependable enough for repeated real visits.

Deliverables:
- error handling and logging across the pipeline
- end-to-end tests for the major workflow
- field-test fixes and regression tests

Dependencies:
- Milestones 1 through 5 complete

Estimated effort: 4 to 6 engineer-days

Definition of Done:
- the core workflow demonstrated end to end, repeatedly, on real visits

## Dependencies Summary

- iPhone device with RoomPlan/LiDAR support
- Xcode development environment
- Mac-based local backend environment
- local network access between devices
- sample room data for testing and iteration (Milestone 1.5)

## Estimated Total Effort

Approximately 20 to 30 engineer-days for a lean, high-quality V1.

## Key Risks

- capture quality varies by device and environment
- the measurement pipeline may require real-world tuning
- transcription quality depends on audio conditions
- the product experience fails if the iPhone workflow is not extremely simple

## Recommended Approach

Small, testable increments. The first priority is to prove that a painter
can start a visit, finish a visit, and receive a useful draft estimate.
Everything else waits until that workflow is reliable.
