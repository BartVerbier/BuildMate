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

## Decision 13 — Estimator rounding rules (2026-07-10)

Paint and primer quantities round UP to the nearest 0.5 L; labour hours
round UP to the nearest 0.25 h; money rounds HALF-UP to 2 decimal places
using decimal arithmetic, applied at each cost line. Every estimate carries
an `assumptions` list documenting each calculation step.

## Decision 14 — Synchronous processing over the local network (2026-07-10)

`POST /sessions` runs the whole pipeline in the request and returns the
finished session. One painter, one phone, one Mac — a job queue would be
over-engineering. The session directory persists every artifact, so a
dropped connection is recovered with `GET /sessions/{id}`. Revisit when
there is more than one concurrent user.

## Decision 15 — Audio decoding via afconvert, not ffmpeg (2026-07-10)

mlx-whisper's file loader shells out to ffmpeg; instead we decode m4a to
16 kHz mono with macOS's built-in `afconvert` and hand Whisper the raw
samples. One fewer third-party dependency, Apple-native, and the formats we
receive come from AVFoundation anyway.

## Decision 16 — Requirements extraction via Claude structured outputs (2026-07-10)

The extractor uses `messages.parse()` with the Pydantic schema so the LLM
output is validated data, never free text. Default model `claude-opus-4-8`,
overridable via `BUILDPILOT_EXTRACTOR_MODEL` (e.g. `claude-haiku-4-5` for
lower cost). Missing credentials, empty transcripts, or API failures degrade
to the default paint scope with an explicit note — the pipeline always
completes and the painter always reviews.

## Decision 17 — Mac console is a local web dashboard, not a native app (2026-07-10)

The Mac-side console (session list, pipeline status, room preview,
transcript, requirements, estimate, export) is a single self-contained HTML
page served by the existing FastAPI backend at `/`. A native macOS app would
double the Apple codebase for a founder-facing dev console; the web page has
zero extra toolchain, reads straight from the session directories, and stays
in sync with the API by construction. The room preview is a top-down floor
plan rendered from the CapturedRoom wall geometry — more legible than a 3D
point cloud and dependency-free. Revisit if the Mac side ever becomes a
customer-facing product.

## Decision 18 — Quote sharing via PDF + native share sheet (2026-07-10)

The iPhone renders the draft quote to a light, print-styled PDF (SwiftUI
`ImageRenderer` into a PDF context) and shares it with SwiftUI `ShareLink` —
Apple's native share sheet provides Mail, Messages, WhatsApp, AirDrop,
Print, and Save to Files with no custom sharing code.

## Decision 19 — Zero-config connection via Bonjour (2026-07-10)

The backend advertises `_buildpilot._tcp` on the local network (macOS's
built-in `dns-sd`, no dependencies); the iPhone discovers it with
`NWBrowser` and resolves the address automatically. A painter never types
an IP address. Manual entry remains available in Settings as a fallback.
Companion reliability rules: the app preflights the connection before
scanning starts, and a failed upload keeps the captured bundle on the phone
with a Try Again action — a network problem can never destroy a visit.

## Decision 20 — The quote is a sales conversation, not a data dump (2026-07-10)

Three product rules for every customer-facing surface:

1. **Internal pricing is never customer-visible.** The phone's calculation
   trail shows quantities and coverage only; the margin composition lives
   exclusively on developer surfaces (Mac console, session JSON). The phone
   filters the estimator's `Quotation:`/margin lines — the estimator itself
   is unchanged and remains fully explainable.
2. **The scope read-back precedes the price.** After processing, the painter
   first sees "Today we've discussed" — the agreed scope in natural language —
   ends with "Is there anything else you'd like included before I prepare
   your quote?", and only then reveals the price. If the conversation wasn't
   captured, the read-back says so honestly instead of showing a default
   scope as if it were agreed. Reopening a visit from history skips the
   read-back (the sales moment already happened).
3. **The quote carries the painter's identity, not the app's.** Company
   name, painter name, phone, and email are simple app settings rendered
   onto the PDF and text quote. No CRM, no customer database.

## Decision 21 — Transport abstraction: local Mac is dev, cloud is the target (2026-07-10)

The local Mac backend is a **development environment**, not the production
architecture. Production is: iPhone → internet (Wi-Fi or cellular) → cloud
backend → AI processing → response.

Seams cut now so the migration is minimal later:

- The app talks only to the `BackendClient` protocol; `HTTPBackendClient`
  works identically against `http://<mac>:8787` and a future
  `https://api.<domain>`.
- `BackendLocator` is the single answer to "which backend?": fixed
  `productionURL` (when set, the entire phone-side migration) → configured
  URL → Bonjour discovery. Bonjour is explicitly a development convenience
  and never part of the production path.
- Backend: FastAPI is host-agnostic; the local-only pieces are isolated in
  `__main__.py` (Bonjour advertisement) and `SessionStore` (on-disk session
  directories — the single seam to swap for object storage / a database in
  the cloud milestone).

Out of scope until the cloud milestone: authentication, TLS configuration,
multi-user storage.

## Decision 22 — Photo documentation and the quotation package (2026-07-10)

Every visit is a permanent project record: scan, audio, transcript,
extraction, measurements, estimate, quote PDF, and photos.

- Photos are captured on the estimate screen — RoomPlan owns the camera
  exclusively during scanning (Apple constraint), so "Before" photos are
  taken right after the scan while still in the room, and "After" photos
  when the visit is reopened from history. Kinds: before / progress / after.
- Photos live on the phone (Documents) and are archived best-effort to the
  backend session directory via POST /sessions/{id}/photos.
- The quote PDF is paginated A4: letterhead (logo + company + contact),
  customer details, date/time, price with VAT line, summary; details page
  (measurements, scope, notes, customer-safe calculation basis, editable
  Terms & Conditions); then "Existing Condition" (before photos) and
  "Completed Result" (after photos, omitted when none), four per page.

## Decision 23 — Automatic Before photos and the AI visualization (2026-07-10)

**Automatic Before photos.** RoomPlan exposes its underlying ARSession;
during every scan the app polls `arSession.currentFrame` every 2.5s (never
touching RoomPlan's delegate), JPEG-encodes samples, and keeps the three
sharpest (JPEG size at fixed quality as the sharpness proxy). They are
saved as the visit's Before photos and archived to the backend — the
painter never has to remember photos. Full-quality manual capture remains
for After photos (no scan on the return visit).

**AI visualization ("Proposed Result").** After the estimate exists, the
backend renders the finished room from the newest archived Before photo +
the typed requirements via a hosted instruction-based image-editing model
(Gemini 2.5 Flash Image, `GEMINI_API_KEY`, adapter in
`pipelines/visualization.py`). The edit instruction is built
deterministically from RequirementExtraction with strict preserve-the-room
rules. This amends Decision 12: AI is allowed for transcription,
extraction, and *presentation* (visualization) — measurements and the
estimate remain deterministic and are never influenced by the image model.
Degradation: no key → the endpoint answers 503, the phone hides the card,
the PDF omits the section. Local generation (on-device or Mac diffusion)
was rejected: slower, heavier, and far less reliable at
structure-preserving edits than hosted image-edit models.

The quote PDF is now a presentation: cover with price → Current Room
(auto Before photos) → Proposed Result (AI render, clearly captioned as a
visualization) → Scope of Work → Price Breakdown with VAT and Terms
(→ Completed Result after the job).

## Decision 24 — BuildMate rebrand and pre-scan customer capture (2026-07-11)

Founder decision, superseding parts of Decisions 9-era branding and the
zero-friction start flow:

- The product's user-facing identity is **BuildMate**: black/yellow design
  system, house + "M" icon, construction positioning. Internal identifiers
  (bundle id `com.buildpilot.BuildPilot`, Bonjour type `_buildpilot._tcp`,
  package `buildpilot`) intentionally keep the old name — changing them
  breaks provisioning, permissions, and installs for zero user value.
- Starting a visit now begins with a customer form: **Customer Name and
  Property Address are required**; phone/email optional; a Painter trade
  chip anticipates future trades (still V1 painters-only under the hood).
- Quote PDFs carry a deterministic quote number (Q-YYYYMMDD-HEX from the
  visit id), the property address, customer contact, and BuildMate footer.

## Decision 25 — Customer revision workflow and future visualization (2026-07-11)

**Revision workflow.** A quote is revisable at the table: "Make Changes" →
listening mode → POST /sessions/{id}/revise. The endpoint composes the
existing pipeline stages (transcribe → LLM-merge into current requirements →
deterministic re-estimate → re-render); the previous state is saved as a
numbered version (sessions/<id>/versions/vNN.json) and any version can be
restored (restore itself versions the current state, so it is reversible).
Change summaries combine the LLM's scope bullets with deterministic price
deltas computed by comparing the old and new estimates. Estimator remains
never-AI.

**Estimator-voice content is deterministic.** The project summary sentence,
staged scope of work (Preparation/Repairs/Painting/Completion), optional
recommendations, and project duration are generated by templates and rules
from the typed extraction (`WorkPlan`, `ConversationSummary`) — same input,
same words, no AI call.

**Future interactive visualization (design note, not built).** The
visualization is isolated behind: the `visualization` PhotoKind (an opaque
artifact the UI presents), the backend adapter (`pipelines/visualization.py`),
and the per-session archive of RoomPlan geometry + reference photos +
requirements. An interactive 3D room (rotate, tap-wall-to-recolour,
before/after compare) would be a new *renderer* over the same inputs —
SceneKit/RealityKit consuming room.json for geometry and per-surface
requirement mapping — replacing only the Proposed Result card and the
render adapter, not the capture flow, pipeline, or data model.

## Decision 26: Measurement completes uncaptured walls; renders belong to the phone (2026-07-11)

**Room-closure completion.** Real scans often reconstruct only some walls
(furniture blocks the LiDAR sweep) — a field scan captured 2 of 4 walls and
would have quoted half the room. The engine now compares total wall width
against the floor-polygon perimeter; below 90% coverage it adds the missing
wall area deterministically (missing perimeter × median wall height), notes
it ("verify on site"), and caps confidence at 0.55 so the app always shows
"check the room". Deterministic, hand-computable, tested.

**Low storage is movable.** RoomPlan has no bench/sideboard category — both
report as "storage" like a built-in wardrobe. Storage under 1.4 m tall is
treated as movable furniture (no wall deduction); only tall storage is a
built-in. Erring movable slightly over-counts paintable area — the safe
direction. The scan's fixed/movable counts are now typed fields on the
measurement and drive the quotation's preparation wording.

**AI renders are requested by the phone, never pushed.** The revise endpoint
no longer renders server-side (the phone had no way to download the result —
the cause of visualizations disappearing after "Make Changes"). Instead it
returns `render_required` and the phone re-requests renders through POST
/visualize, the same path as after the original scan. /visualize takes
`stage=finished|preparation`; the three-stage story (today → prepared &
protected → finished) appears in the app and the PDF. Visit records preserve
their photos when a revision replaces the session content.

## Rationale

These decisions are intended to reduce complexity and increase the likelihood of building a working prototype quickly. The core value proposition is not the scanning technology itself, but the automation of the site visit and the generation of a useful draft estimate.

## Future Review

These choices (except those marked permanent) should be revisited if the product proves viable and the team needs to expand the scope, move to production infrastructure, or support additional verticals.
