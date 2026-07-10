# PROJECT_STRUCTURE

## Repository Layout

```text
Build Pilot/
├── backend/                    # Local backend service (Python)
│   ├── buildpilot/
│   │   ├── models/             # Versioned session contract (metric, EUR)
│   │   ├── pipelines/          # measurement / transcription / extraction / estimator
│   │   ├── pipeline.py         # Orchestrator with degradation policy
│   │   ├── session_store.py    # Session-directory storage (no database)
│   │   ├── server.py           # FastAPI app (port 8787)
│   │   └── config.py           # Hard-coded V1 company profile
│   ├── tests/                  # pytest suite (+ fixtures/, incl. synthetic room)
│   ├── sessions/               # Runtime session directories (gitignored)
│   └── pyproject.toml
├── docs/                       # Product specification and decisions
├── iphone/
│   └── BuildPilot/
│       ├── project.yml         # XcodeGen spec (xcodeproj is generated)
│       └── Sources/            # SwiftUI app: capture, upload, estimate review
├── samples/                    # Real capture fixtures (CapturedRoom JSON)
├── AGENTS.md                   # Cross-tool agent instructions (shared standard)
├── CLAUDE.md                   # Claude Code entry point; imports AGENTS.md
└── IMPLEMENTATION_PLAN.md
```

Folders are added when they carry real content, not in advance.

## Implementation Notes

- Generated artifacts (`.xcodeproj`, `backend/sessions/`, caches) are
  gitignored; specs and sources are committed.
- Product docs stay separate from implementation code.
- Code and documentation never drift apart — doc updates ship in the same
  change as the code they describe.
