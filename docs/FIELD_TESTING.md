# FIELD_TESTING — Founder Runbook

The checklist for taking Build Pilot on real visits. Version 1 assumes the
iPhone and the Mac are available together (per product decision, deployment
architecture is out of scope for V1 testing).

## Before leaving (5 minutes, at the desk)

1. **Start the backend** on the Mac:
   ```bash
   cd backend && export ANTHROPIC_API_KEY=sk-ant-...
   ../.venv/bin/python -m buildpilot
   ```
   Wait for `Whisper warm-up done` in the log — this guarantees the model
   is downloaded and compiled *before* any customer visit.
2. **Check the log for warnings** — a missing API key is announced loudly
   (extraction will degrade to the default scope without it).
3. **Open the console** at http://localhost:8787/ — it should load with your
   previous sessions.
4. On the iPhone: **Settings (gear) → your Mac appears** under "Your Mac".
   Tap it; the check turns green.
5. **Business identity filled in** (Settings → Your Business) — it goes on
   every quote.
6. **Company profile numbers checked** in `backend/buildpilot/config.py` —
   labour rate, paint costs, **VAT rate** for your market. These are
   placeholders until you tune them.
7. Do one **dry-run visit** in the office: scan a room, review, share the
   PDF to yourself.

## During a visit

- Ask before recording: *"I'll record our chat so nothing gets missed —
  that okay?"* (etiquette and, in some countries, law).
- Scan every wall; let RoomPlan's on-screen coaching finish a wall before
  moving on.
- The phone can lie on the table during processing — the screen stays awake.
- If sending fails: the visit is saved on the phone; **Try Again** after
  checking the network.

## After a visit — what to check

Open the console (http://localhost:8787/):

- **Stage timings** are shown on the pipeline card (also in
  `session.json → raw_metadata → timing_*`). Transcription dominating?
  Try `BUILDPILOT_WHISPER_MODEL=mlx-community/whisper-tiny` and compare
  transcript quality.
- **Transcript** — read it. This is the ground truth for extraction quality.
- **Requirements vs. what the customer actually said** — the key V1 metric.
- **Floor plan** — does it match the real room shape?
- **Measurements vs. a tape measure** on at least the first three visits.

## When something goes wrong — what to collect

1. `<sessions dir>/buildpilot.log` — the backend log (timestamps, stage
   timings, warnings, stack traces).
2. The whole `sessions/<visit-id>/` directory — it contains everything
   needed to replay the visit (raw scan, audio, every stage's output).
3. iPhone logs: Console.app → device → filter subsystem
   `com.buildpilot.app` — start, preflight, scan size, upload duration,
   failures.

A failed visit is never lost: the session directory keeps the raw inputs,
so the pipeline can be re-run against them after a fix.

## Known V1 limitations (by design)

- English-first: Whisper and the extraction prompt are untuned for other
  languages (multilingual support is explicitly deferred).
- One room per visit; quotes are advisory and not editable in the app.
- The estimate uses the hard-coded company profile — tune it before
  trusting any price.
