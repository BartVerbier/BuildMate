# PROJECT_STRUCTURE

## Repository Layout

```text
Build Pilot/
├── backend/            # Local backend service and processing logic
│   ├── buildpilot/     # Python package: models and pipeline interfaces
│   ├── tests/          # Backend test suite (pytest)
│   └── pyproject.toml  # Packaging, dependencies, pytest config
├── docs/               # Product specification and implementation planning
├── iphone/             # iPhone application source (capture spike docs for now)
├── samples/            # Real capture fixtures: CapturedRoom JSON, session examples
├── AGENTS.md           # Cross-tool agent instructions (shared standard)
├── CLAUDE.md           # Claude Code entry point; imports AGENTS.md
└── IMPLEMENTATION_PLAN.md
```

Folders are added when they carry real content, not in advance. Earlier
drafts of this document listed `prototype/`, `prompts/`, and `research/`;
they will be created if and when something real needs to live there.

## Intended Use of Each Area

- backend/: server-side processing, data handling, and estimate generation logic
- docs/: founder spec, architecture notes, planning, and implementation decisions
- iphone/: the primary iPhone client application
- samples/: real capture data and example payloads used as test fixtures

## Implementation Notes

The repository should remain organized so that:
- product docs stay separate from implementation code
- sample assets are easy to discover and reuse
- code and documentation never drift apart — doc updates ship in the same
  change as the code they describe
