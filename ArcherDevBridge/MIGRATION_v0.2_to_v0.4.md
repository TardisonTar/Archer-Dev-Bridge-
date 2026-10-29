# Миграция v0.2.0 → v0.4.0

1. Закройте Archer Dev Bridge.
2. Запустите `ArcherDevBridge_Setup_v0.4.0.cmd`.
3. Установщик обновит программу в `%LOCALAPPDATA%\Programs\ArcherDevBridge`.
4. `%LOCALAPPDATA%\ArcherDevBridge` не удаляется: там остаются настройки, quality-gate state и логи.
5. При первом запуске v0.4 автоматически переносит старые настройки v0.2 в `settings.json`.
6. Путь к проекту и Godot после этого сохраняются постоянно.

API key намеренно не сохраняется и не переносится.
