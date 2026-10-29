# Migration 0.6.1-r3 → 0.6.2

- Added GUI Git Inspector showing exact staged/unstaged/untracked files.
- Diagnose/Repair now records exact DIRTY details and explains why Git is yellow.
- Git yellow no longer means Git is broken: it explicitly reports working-tree changes.
- Strict clean behavior remains safety-first; no automatic reset/clean/commit is performed.
