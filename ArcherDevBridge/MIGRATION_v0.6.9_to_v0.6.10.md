# Migration 0.6.9 → 0.6.10

- Git Inspector no longer disables the BASE action when the working tree is CLEAN.
- On a CLEAN tree the button is shown as `ПОДТВЕРДИТЬ BASE` and accepts the current HEAD as the explicit ROADMAP BASE without creating an empty commit.
- On a DIRTY tree the same control remains `СОЗДАТЬ BASE COMMIT` and preserves the existing explicit commit workflow.
- ROADMAP queue reconciliation now runs before BASE candidate lookup, so one click is enough even when a recovered parent still shows DONE/PASS instead of DONE_WAIT_BASE.
- Existing Git safety remains unchanged: no automatic commit/push/reset/rebase/clean; staged/conflict states are handled by the existing guarded dialog path.
