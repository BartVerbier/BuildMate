# Backend

Local backend for Build Pilot: the deterministic pipeline that turns a room
scan and visit audio into a draft estimate.

## Setup

```bash
cd backend
python3 -m venv ../.venv          # or reuse the existing repo venv
../.venv/bin/pip install -e ".[dev]"
```

## Run tests

```bash
cd backend
../.venv/bin/python -m pytest
```

## Structure

- `buildpilot/models/` — versioned session contract and domain models
  (metric units, EUR — see docs/DECISIONS.md, Decision 9)
- `buildpilot/pipelines/` — pipeline stage interfaces
- `tests/` — contract and validation tests

## Current scope

Milestone 1.5 complete: contract, models, interfaces, packaging, tests.
No RoomPlan processing, AI integration, or estimation logic yet — those are
Milestones 2–4.
