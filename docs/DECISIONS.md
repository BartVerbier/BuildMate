# DECISIONS

## Summary

This document captures the architectural and product decisions that shape the Build Pilot project. Decisions marked **permanent** require explicit founder approval to revisit.

## Key Decisions

1. Focus the first version on painting companies only.
2. Use the iPhone as the primary capture device.
3. Use the Mac as the local processing engine during development.
4. Prefer Apple-native technologies such as RoomPlan, ARKit, and LiDAR.
5. Avoid cloud infrastructure in V1.
6. Keep the user experience extremely simple with a minimal set of actions.
7. Make AI provider integration modular and replaceable.
8. Prioritize proving the workflow over building a broad feature set.

## Decision 9 — Metric units internally, everywhere (permanent, 2026-07-10)

Internal units across all code, contracts, and stored data:

- lengths: metres (m)
- areas: square metres (m²)
- paint volumes: litres (L)
- coverage: square metres per litre (m²/L)
- labour: hours
- currency: euros (EUR) for V1

RoomPlan measurements are already in metres and are **never converted
internally**. Conversion to imperial units happens only at the display
layer, and only for countries that use imperial units.

Rationale: RoomPlan outputs metres natively (zero conversion, fewer bugs),
paint coverage is quoted in m²/L industry-wide, and the target market is
metric. Field names encode the units (`_m2`, `_litres`, `_eur`) so the code
cannot silently drift from this decision.

## Decision 10 — CapturedRoom JSON verbatim as the scan contract (2026-07-10)

The iPhone encodes Apple's `CapturedRoom` with `JSONEncoder` and sends it
untouched. The backend parses only the fields it needs.

Rationale: the phone stays thin; Apple versions the schema for us; the
backend keeps full-fidelity raw data so improved measurement logic can be
re-run on old visits.

## Decision 11 — Session directory instead of a database (2026-07-10)

Each visit is a self-contained folder: `sessions/<id>/` containing
`session.json`, `room.json`, `audio.m4a`, and one artifact per pipeline
stage (`transcript.txt`, `requirements.json`, `estimate.json`).

Rationale: replayable, diffable, explainable, and zero infrastructure.
Revisit only when multi-user support exists.

## Decision 12 — AI is bounded to two stages (2026-07-10)

Only transcription and requirements extraction may use AI. Transcription is
planned as local Whisper on the Mac (zero API cost, audio never leaves the
machine). Requirements extraction is one small LLM call per visit.
Measurement and estimation are deterministic and must never be AI.

## Rationale

These decisions are intended to reduce complexity and increase the likelihood of building a working prototype quickly. The core value proposition is not the scanning technology itself, but the automation of the site visit and the generation of a useful draft estimate.

## Future Review

These choices (except those marked permanent) should be revisited if the product proves viable and the team needs to expand the scope, move to production infrastructure, or support additional verticals.
