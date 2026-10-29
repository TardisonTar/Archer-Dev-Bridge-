# Migration v0.4.1 → v0.5.0

- Настройки v0.4.1 автоматически читаются из `%LOCALAPPDATA%\ArcherDevBridge\settings.json` и мигрируются в schemaVersion 3.
- Для старой конфигурации 0.4 основной operator model автоматически переключается на `gpt-6-astra`, reasoning — `medium`.
- Путь проекта, Godot, Codex, Git и .NET сохраняется.
- OpenAI API planner/reviewer остаётся выключенным, если пользователь явно не включал его.
- Codex API-auth в 0.5 блокируется по умолчанию. Для штатного режима выполните `codex login` через ChatGPT.
- При первом запуске Bridge создаёт/обновляет три пользовательских subagent-профиля в `%USERPROFILE%\.codex\agents\`.
- Quality Gate стал строгим: обязательный SKIPPED/NOT_AVAILABLE теперь блокирует PASS.
