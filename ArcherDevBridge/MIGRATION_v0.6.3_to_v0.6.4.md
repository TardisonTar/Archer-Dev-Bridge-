# Migration 0.6.3 → 0.6.4

## Operator Mode

0.6.4 adds an explicit operator execution mode selector:

- `ASTRA + ONE CODEX` — default. Astra is the operator and sole coding agent; subagents are not invoked.
- `ASTRA + AI TEAM` — optional legacy/team mode using explorer/worker/reviewer subagents.

The selection is persisted in `settings.json`. Existing installations migrate to `ASTRA + ONE CODEX` by default.

In ONE CODEX mode the Agents health item stays green and reports that subagents are disabled/not required. The development and repair prompts explicitly prohibit spawning subagents.
