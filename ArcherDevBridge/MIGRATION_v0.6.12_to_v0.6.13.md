# Archer Dev Bridge 0.6.12 -> 0.6.13

- Fixes Manual Release Gate -> ROADMAP status synchronization.
- Retry run IDs such as `T020R091856` are resolved back to their canonical queue task (`T020`) using saved lineage and a safe retry-ID fallback.
- A successful Manual Release Gate now persists the ROADMAP row as `DONE_WAIT_BASE` when BASE has not yet been confirmed.
- On startup, an already accepted 0.6.12 Manual Release Gate with a stale `BLOCKED_ENVIRONMENT` queue row is reconciled automatically to `DONE_WAIT_BASE`; T020 does not need to run again.
- `baseConfirmed` remains false until the user explicitly creates/confirms BASE in Git Inspector.
- No project/game files are modified by this Bridge update. No automatic commit/push/reset/clean/rebase behavior is added.
