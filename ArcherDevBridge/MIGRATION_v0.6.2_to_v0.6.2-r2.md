# Migration 0.6.2 → 0.6.2-r2

Hotfix for Windows PowerShell 5.1 compatibility in Git Inspector / System Health Monitor.

- Replaced the generic `List[object]` collection used by Git Inspector with a normal PowerShell array.
- Removed the `@($genericList)` conversion that can trigger `Argument types do not match` under Windows PowerShell 5.1.
- Git Inspector parsing errors now degrade only the Git detail to a yellow fallback instead of breaking the entire Health Monitor.
- Health Monitor now writes the failing script location to the operator log when an unexpected exception occurs.
- No project files, Git history, credentials, or external tools are modified by this migration.
