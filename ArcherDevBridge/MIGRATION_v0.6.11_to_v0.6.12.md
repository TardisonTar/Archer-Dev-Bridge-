# Archer Dev Bridge 0.6.11 -> 0.6.12

- Structured Astra markers now have strict precedence over historical stdout/stderr/report text.
- Old NU1301 mentions can no longer overwrite a current explicit `BLOCKER` / `RELEASE_STATUS`.
- `EXPORTED_UI_PROFILE_GATE_UNAVAILABLE` and equivalent desktop-verification blockers become `WAITING_MANUAL_RELEASE_CHECK / NEEDS_REVIEW`, not source/environment failure.
- `ПРИНЯТЬ GATE` for manual release review asks for an explicit exported-build checklist confirmation, then runs only Git + manifest/package integrity checks instead of repeating the full test suite.
- `REVIEW ONLY` cannot replace the manual exported-build check.
- No automatic commit/push/reset/clean/rebase behavior was added.

- Existing 0.6.11 T020 runs misclassified as `BLOCKED_ENVIRONMENT` are migrated on startup when their saved structured final requires manual exported-UI verification; rerunning T020 is not required.
