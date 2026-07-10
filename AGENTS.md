# AGENTS.md

## Project overview

Build Pilot is an AI-assisted site visit tool for painting contractors. The current scope is intentionally narrow: V1 supports painting companies only and focuses on turning a room scan plus conversation into a draft estimate.

## Source of truth

Before changing product behavior or architecture, read the documentation in the docs folder first:
- [docs/FOUNDER_SPEC.md](docs/FOUNDER_SPEC.md)
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [docs/TECH_STACK.md](docs/TECH_STACK.md)
- [docs/ROADMAP.md](docs/ROADMAP.md)
- [docs/PROJECT_STRUCTURE.md](docs/PROJECT_STRUCTURE.md)
- [docs/DECISIONS.md](docs/DECISIONS.md)
- [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md)

## Working principles

- Keep the product simple and local-first for V1.
- Prefer Apple-native technologies for capture and measurement.
- Favor deterministic logic over unnecessary abstraction.
- Keep AI integration modular and replaceable.
- Do not expand beyond painting-company scope unless the docs explicitly change.

## Repository guidance

- Keep implementation work scoped to the planned milestones.
- Do not add production application code before the implementation plan is approved.
- Preserve the separation between product documentation, implementation planning, and code.
- When adding new files, place them in the most relevant existing top-level area.

## When making changes

- Prefer small, focused changes.
- Document significant architectural decisions in the docs folder.
- Keep comments and code clear and maintainable.
- Avoid premature optimization or over-engineering.
