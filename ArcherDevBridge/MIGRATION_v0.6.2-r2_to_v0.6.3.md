# Migration 0.6.2-r2 → 0.6.3

## Git Inspector: Diff & BASE

0.6.3 extends the PowerShell 5.1-safe Git Inspector without changing the core task pipeline.

- `СРАВНИТЬ` shows staged/unstaged diff for the selected file in a GUI window.
- `ОТКРЫТЬ ФАЙЛ` opens the selected working-copy file with its Windows-associated application.
- `ВОССТАНОВИТЬ` is limited to an unstaged tracked file and always requires confirmation. It never removes untracked/new files and never uses `git reset --hard`.
- `СОЗДАТЬ BASE COMMIT` is an explicit user-only action. It refuses conflicts, detached HEAD and pre-existing staged changes, checks Git author identity, then commits the complete current working tree as `BASE before Archer task <timestamp>`.
- Bridge never creates commits automatically and never pushes them.
