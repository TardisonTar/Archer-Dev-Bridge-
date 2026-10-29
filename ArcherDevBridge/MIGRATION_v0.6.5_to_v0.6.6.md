# Migration 0.6.5 → 0.6.6

- Adds queue lineage metadata: `taskType`, `parentTaskId`, `inheritedWorkingTree`, `parentRunDir`.
- Targeted repair tasks may inherit the dirty working tree of their failed/review parent without disabling strict Clean Git globally.
- New normal tasks remain blocked by dirty Git.
- Legacy repair rows are migrated automatically from task text such as `T003 ... TARGETED REVIEW FIX`.
- Stale queue rows left in `RUNNING` after a restart are recovered to `BLOCKED`.
- A cycle that returns without a terminal state is normalized from `RUNNING` to `BLOCKED`.
- Run metadata records repair lineage and inherited working tree state.
