# 0.6.4-r8 -> 0.6.5

- Codex watchdog timeout больше не запускает автоматический repair, если локальный Gate уже прошёл.
- Новый статус `CODEX_TIMEOUT_VERIFIED / NEEDS_REVIEW`.
- Кнопки GUI: `ПРИНЯТЬ GATE`, `REVIEW ONLY`, `ОТКЛОНИТЬ`.
- `ПРИНЯТЬ GATE` повторно запускает локальные Build/Tests/Godot/Git Safety перед DONE.
- `REVIEW ONLY` запускает Astra/Codex в read-only sandbox и не меняет проект.
- Старые FAIL из-за watchdog с полностью PASS gate автоматически переклассифицируются в NEEDS_REVIEW.
- Auto-repair на watchdog отключён, чтобы не тратить второй полный тайм-аут.
