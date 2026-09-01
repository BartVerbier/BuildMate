# Review Backlog — deferred with reasons, not forgotten

Independent-review suggestions (Codex, 2026-09-01) that are real but
deliberately sequenced later. Each entry says when it unblocks. Acted on
immediately instead: money-field schema pins (test_money_field_schema.py),
the not-quotable state in the visits list, the scan-review facts line, and
the phantom-version + contractor-allowlist fixes.

## After milestone A (engine proven against laser truth)

- **Split measurement.py into staged sub-pipelines** (wall graph → openings
  → areas → completeness → confidence). Right refactor, wrong moment:
  restructuring the highest-risk file before its accuracy exam would blur
  what milestone A measures. The ground-truth harness then makes this
  refactor safe.
- **Extract a pure "apply plan edit" function from /reestimate.** Same
  logic: the route is well-tested today; extract when edit types grow
  (protection time, per-surface pricing will force it anyway).

## After first device iteration (milestone B/D)

- **Split VisitController** into capture-lifecycle / persistence / render
  coordinators. It is past comfortable inspection size, but reshaping the
  field-critical controller with no device in hand risks tomorrow's visits
  for structure's sake.
- **Sharpen flow-transition labels** ("scan incomplete — rescan now",
  "quote ready, not yet quotable") — belongs in the milestone D copy pass
  with founder eyes on it.

## Considered and declined (say why once, here)

- **Generating one shared geometry implementation for Swift + Python.**
  The generated real-scan parity tests already fail on any drift, which is
  the risk the suggestion targets; a codegen pipeline across two languages
  costs more than it protects in V1.
- **Splitting the upload into intake + metadata calls.** One multipart
  request is deliberate: field networks are flaky, and a visit must land
  atomically or not at all. The envelope is documented and contract-tested.
