# ARCHITECTURE

## Overview

Build Pilot is designed as a local, two-device workflow:
- The iPhone acts as the capture device.
- The Mac acts as the local processing and reasoning engine during development.

This architecture keeps the first version simple and avoids introducing cloud infrastructure prematurely.

## High-Level Components

### 1. Capture Client on iPhone
The iPhone app is responsible for:
- starting room capture
- collecting LiDAR and RoomPlan data
- recording microphone input
- capturing the user's visit flow
- sending the generated payload to the local backend

### 2. Local Backend on Mac
The backend service is responsible for:
- receiving capture payloads from the phone
- organizing raw data into a structured session
- running measurement and conversation-processing steps
- producing a draft estimate
- exposing a simple API for the app and future debugging tools

### 3. AI Processing Layer
This layer converts raw capture inputs into useful business outputs:
- spatial measurements from scan data
- structured notes from customer conversation
- scope, exclusions, and special notes
- estimate suggestions based on company profile assumptions

### 4. Estimate Engine
The estimate engine combines:
- room measurements
- customer requirements
- a hard-coded company profile for V1
- business rules for labour, materials, and margin

The output is a draft estimate that remains advisory until a painter reviews it.

## Data Flow

1. The painter presses Start Visit on the iPhone.
2. The app begins capture of room data and audio.
3. The painter walks through the site naturally.
4. The painter presses Finish Visit.
5. The app packages the session data and sends it to the local backend.
6. The backend processes the inputs into structured measurements and requirements.
7. The system produces a draft estimate for review.

## Design Principles

- Keep the system simple and local-first.
- Prefer native Apple capabilities over custom scanning implementations.
- Keep AI provider integration modular and replaceable.
- Make the data contract explicit so future iterations can evolve without rewriting the whole pipeline.
- Metric units internally, everywhere; conversion only at the display layer (docs/DECISIONS.md, Decision 9).
- The phone uploads raw captures verbatim (CapturedRoom JSON + audio); all interpretation happens in the backend.
- Each visit is a self-contained session directory on disk; no database in V1.
- AI is bounded to transcription and requirements extraction; measurement and estimation are deterministic.

## Deployment Model

For V1, the application is expected to run on:
- an iPhone on the same local network as the Mac
- a development backend process on the Mac

This is sufficient to prove the workflow and validate the product experience before any production architecture is considered.
