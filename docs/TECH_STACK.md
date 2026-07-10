# TECH_STACK

## Purpose

This document defines the initial technology direction for Build Pilot. It is a first draft intended to support rapid prototyping while remaining aligned with the founder specification.

## Recommended Stack for V1

### iPhone Application
- SwiftUI for the user interface
- RoomPlan (`RoomCaptureView` / `RoomCaptureSession`) for room capture —
  RoomPlan owns ARKit, LiDAR, and the camera; nothing custom is layered on it
- AVFoundation (`AVAudioRecorder`) for visit audio (AAC mono m4a)
- XcodeGen for project generation (`project.yml` is committed; the
  `.xcodeproj` is generated)
- iOS 17.0+ deployment target; LiDAR-capable device required

### Local Processing Backend
- Python 3.12+ for the local service running on the founder's Mac (developed on 3.14)
- FastAPI for a lightweight HTTP API (introduced when the upload endpoint is built)
- Pydantic for request and response validation
- Session-directory storage: one folder per visit holding raw captures and per-stage artifacts (see docs/DECISIONS.md, Decision 11) — no database in V1
- Packaging via `pyproject.toml`; install with `pip install -e ".[dev]"` from `backend/`

### AI and Reasoning Layer
AI is bounded to exactly two pipeline stages (docs/DECISIONS.md, Decision 12):
- Transcription: `mlx-whisper` locally on the Mac (Apple Silicon), audio
  decoded via macOS `afconvert` (Decision 15) — zero API cost, audio never
  leaves the machine
- Requirements extraction: one Claude call per visit via the `anthropic`
  SDK with structured outputs (Decision 16); provider code isolated in
  `pipelines/extraction.py`
- Measurement and estimation are deterministic Python and never use AI

### Tooling and Delivery
- Xcode for iPhone development
- VS Code for backend and documentation work
- Git for version control
- pytest for backend testing once implementation begins
- Simple local environment configuration with environment variables and configuration files

## Constraints

- The first version is intentionally local-first and does not require cloud infrastructure.
- The stack should prioritize reliability and development speed over complexity.
- Apple-native technologies should be preferred wherever they directly support the required workflow.

## Implementation Guideline

The initial implementation should be as simple as possible:
1. Capture room and audio on the iPhone.
2. Transfer data to the local Mac service.
3. Process the data into structured measurements and conversation insights.
4. Produce a draft estimate for human review.

This stack is intended to support that flow without over-engineering the system.
