# Migration: 0.5.2 → 0.6.0

- Настройки, очередь и runs находятся в `%LOCALAPPDATA%\ArcherDevBridge` и сохраняются.
- Legacy run-каталоги не удаляются, но не считаются текущим циклом.
- Новые task-run используют schemaVersion 2.
- Пользовательский запуск выполняется через `ArcherDevBridge.exe`.
- Пользовательское обновление выполняется через `ArcherDevBridge_Setup_v0.6.0.exe`; `.cmd` больше не требуется.
- Codex API-auth и legacy API planner/reviewer остаются выключенными по умолчанию.
- Новые Safety Guards могут остановить задачу при staged changes или изменении credential-файлов.
