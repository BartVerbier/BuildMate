# API_KEYS

## Overview

Build Pilot is local-first. Exactly one external service is used in V1:
the Anthropic API, for requirements extraction — one small call per visit.
Everything else (measurement, transcription, estimation) runs locally at
zero API cost.

## Required key

| Variable | Used by | Notes |
|---|---|---|
| `ANTHROPIC_API_KEY` | Requirements extractor | Optional — without it the pipeline degrades to the default paint scope and notes it on the estimate. Get a key at console.anthropic.com. |
| `GEMINI_API_KEY` | Proposed-result visualization (Developer API) | Optional — AI Studio *prepay* billing. Get a key at aistudio.google.com. ~$0.04 per rendered image. |
| `GOOGLE_CLOUD_PROJECT` + `GOOGLE_APPLICATION_CREDENTIALS` | Proposed-result visualization (**Vertex AI** — preferred when set) | Same model, billed to the Google Cloud project, so **GCP trial credits apply**. `GOOGLE_APPLICATION_CREDENTIALS` points at a service-account JSON key (Vertex AI User role); relative paths resolve against `backend/`. Optional `GOOGLE_CLOUD_LOCATION` (default `global`). |

Set it in the shell that runs the backend:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
cd backend && ../.venv/bin/python -m uvicorn buildpilot.server:app --host 0.0.0.0 --port 8787
```

## Related configuration

- `BUILDPILOT_EXTRACTOR_MODEL` — defaults to `claude-opus-4-8`; set
  `claude-haiku-4-5` to reduce per-visit cost.
- `BUILDPILOT_WHISPER_MODEL` — local model choice; no key needed
  (weights download from Hugging Face on first use and are cached).

## Security notes

- Never commit keys; `.env*` is gitignored.
- The visit audio never leaves the Mac — only the transcript text is sent
  to the extraction API (docs/DECISIONS.md, Decision 12).
- Keep provider-specific code isolated in
  `backend/buildpilot/pipelines/extraction.py` so the provider can be swapped.
