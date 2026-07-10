@AGENTS.md

## Claude Code-specific instructions

- Work milestone by milestone per IMPLEMENTATION_PLAN.md. After completing a
  milestone: explain what was built, why, alternatives, tradeoffs, and
  remaining risks — then STOP and wait for founder approval.
- Units are metric internally, permanently (docs/DECISIONS.md, Decision 9).
  Field names encode units (`_m2`, `_litres`, `_eur`). Never add imperial
  units anywhere except a display-layer conversion.
- The estimate engine is never AI. Only transcription and requirements
  extraction may use AI.
- Run the backend tests before presenting any milestone as done:
  `cd backend && ../.venv/bin/python -m pytest`
- When architecture changes, update every affected document in the same
  change. Code and docs must never drift apart.
