# 0.6.4-r4 → 0.6.4-r5

Critical startup hotfix.

- Restores UTF-8 BOM on `ArcherDevBridge.ps1`, required for reliable Windows PowerShell 5.1 parsing of the Russian/non-ASCII UI source.
- Retains the r4 raw UTF-8 Codex stdin transport fix.
- No project/game data is changed by the update.
