# Secret management

The one place that explains every secret BuildMate uses, where it lives, and
how to change it. This architecture is considered **final** — see "Ground
rules" at the bottom.

## Principle

Each secret lives in exactly one place per environment, and **never** in source
code:

| Environment | Store | Committed? |
|---|---|---|
| Backend — local dev | `backend/.env` | No (gitignored) |
| Backend — production | Railway → Variables | No (platform-managed) |
| iOS — local/dev build | `iphone/BuildPilot/Secrets.xcconfig` | No (gitignored) |

Templates with **placeholder values only** are committed so a new machine knows
what to fill in: `backend/.env.example`, `iphone/BuildPilot/Secrets.example.xcconfig`.

Verified: no hardcoded secret exists anywhere in tracked or untracked source
(`grep` for key/token patterns across `backend/buildpilot` and
`iphone/BuildPilot/Sources`), and no secret file is tracked by git.

## The secrets

### 1. Backend API token — `BUILDPILOT_API_TOKEN` / `BUILDMATE_API_TOKEN`
- **What:** shared bearer token protecting every backend endpoint except `/health`.
- **Where it belongs:**
  - Backend local: `backend/.env` → `BUILDPILOT_API_TOKEN` (usually **unset** locally — the Mac backend then runs with auth disabled).
  - Backend prod: Railway variable `BUILDPILOT_API_TOKEN`.
  - iOS: `Secrets.xcconfig` → `BUILDMATE_API_TOKEN` (injected into Info.plist as `BuildMateAPIToken`).
- **Where used:** [backend/buildpilot/auth.py](backend/buildpilot/auth.py) verifies it; the phone sends it via [ContractorIdentity](iphone/BuildPilot/Sources/AppConfig.swift) → [BackendClient.authorizedRequest](iphone/BuildPilot/Sources/BackendClient.swift).
- **The iOS token and the Railway token MUST be identical**, or the app gets 401.
- **How to replace:** set the new value in Railway *and* in `Secrets.xcconfig`, then rebuild the app. No code change, no migration (constant-time compare, no stored state).

### 2. Anthropic API key — `ANTHROPIC_API_KEY`
- **What:** authenticates the one paid AI call per visit (requirements extraction). `ANTHROPIC_AUTH_TOKEN` is an accepted alternative.
- **Where it belongs:** `backend/.env` (local), Railway variable (prod). Backend-only — the phone never holds it.
- **Where used:** [backend/buildpilot/pipelines/extraction.py](backend/buildpilot/pipelines/extraction.py). Unset → extraction degrades to the default paint scope (no crash).
- **How to replace:** update `.env` / Railway, restart the backend.

### 3. Gemini API key — `GEMINI_API_KEY`
- **What:** authenticates the visualization ("proposed result" render) via the Gemini Developer API. One of two visualization paths.
- **Where it belongs:** `backend/.env` (local), Railway variable (prod). Backend-only.
- **Where used:** [backend/buildpilot/pipelines/visualization.py](backend/buildpilot/pipelines/visualization.py). Unset (and no Vertex configured) → visualization returns 503; the estimate is unaffected.
- **How to replace:** update `.env` / Railway, restart.

### 4. Vertex AI service account — `GOOGLE_APPLICATION_CREDENTIALS` / `..._JSON`
- **What:** the *alternative* visualization path — a Google service-account key (real secret: it contains a private key). If `GOOGLE_CLOUD_PROJECT` is set it takes precedence over `GEMINI_API_KEY`.
- **Where it belongs:**
  - Local: `GOOGLE_APPLICATION_CREDENTIALS` in `.env` points to `backend/vertex-key.json` (path resolved relative to `backend/`). **`vertex-key.json` is the secret file** and is gitignored.
  - Prod (Railway has no file upload): paste the key JSON into `GOOGLE_APPLICATION_CREDENTIALS_JSON`; [__main__.py](backend/buildpilot/__main__.py) writes it to a temp file at boot.
- **Where used:** [visualization.py](backend/buildpilot/pipelines/visualization.py) (Vertex auth), [__main__.py](backend/buildpilot/__main__.py) (materialization).
- **How to replace:** drop a new `vertex-key.json` locally / update the JSON variable on Railway, restart. Rotate via the Google Cloud console (disable the old key).

## Non-secret configuration (for reference — NOT secrets)

Env-driven but safe to commit / share: `GOOGLE_CLOUD_PROJECT`,
`GOOGLE_CLOUD_LOCATION`, `BUILDPILOT_SESSIONS_DIR`, `BUILDPILOT_TRANSCRIBER`,
`BUILDPILOT_EXTRACTOR_MODEL`, `BUILDPILOT_WHISPER_MODEL`,
`BUILDPILOT_VISUALIZER_MODEL`, `BUILDPILOT_RUN_WHISPER_TESTS`, and the iOS
`BUILDMATE_CONTRACTOR_ID` (an identifier, defaults to `default`). These live in
the same files for convenience but are not sensitive.

## How to add a new secret

1. **Pick the owner.** Backend-only → `.env` + Railway. Needed on the phone →
   also `Secrets.xcconfig`.
2. **Read it from the environment / config, never a literal:**
   - Backend: `os.environ.get("NEW_SECRET")`.
   - iOS: add `NEW_KEY = ...` to `Secrets.xcconfig`, expose it in `project.yml`
     `info.properties` as `NewKey: $(NEW_KEY)`, read via `AppConfig.string("NewKey")`.
3. **Add a placeholder line** to the matching `*.example` template.
4. **Confirm it's gitignored** (`git add --dry-run <file>` must refuse the real
   file). Real `.env`/`Secrets.xcconfig`/`*service-account*.json`/`vertex-key.json`
   are already covered.
5. **Set the real value** in `.env` / `Secrets.xcconfig` / Railway.
6. **Document it here** (add a numbered entry above).

## Ground rules (secret architecture is final)

Per founder decision, do not move, reorganize, or rotate secrets again *unless*:
a new secret is introduced, a secret is genuinely exposed, or a security change
is explicitly requested. Adding a new secret follows the steps above and updates
this file — it does not "reorganize" the system.
