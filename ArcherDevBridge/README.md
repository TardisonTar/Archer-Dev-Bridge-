ArcherDevBridge 0.6.13 — Manual Gate ROADMAP Reconcile Fix.

## 0.6.13 — Manual Gate ROADMAP Reconcile Fix

- Manual Release acceptance now resolves retry IDs back to the original ROADMAP task.
- Successful manual acceptance immediately persists `DONE_WAIT_BASE`, even when the next task is not yet queued.
- Startup repairs already-accepted 0.6.12 runs whose queue row is still `BLOCKED_ENVIRONMENT`.
- BASE confirmation remains explicit and separate. No task rerun is required for the repaired T020 state.

ArcherDevBridge 0.6.10 — Git Inspector BASE confirmation fix on top of the 0.6.9 safety core.


## 0.6.12 — Structured Gate Precedence / Manual Release Check

- `OPERATOR_RESULT / OPERATOR_REVIEW / SOURCE_STATUS / RELEASE_STATUS / BLOCKER / REPAIR_SOURCE` from Astra's structured final response have priority over historical log text.
- Stale `NU1301` mentions are fallback evidence only and cannot overwrite an explicit current blocker.
- `EXPORTED_UI_PROFILE_GATE_UNAVAILABLE` routes to `NEEDS_REVIEW` with stage `WAITING_MANUAL_RELEASE_CHECK`.
- After the user manually verifies the exported EXE, `ПРИНЯТЬ GATE` records confirmation and rechecks Git plus package manifest/hash integrity without re-running the whole 312-test suite.
- Existing 0.6.11 blocked T020 runs are re-read on startup; when the saved structured final says `EXPORTED_UI_PROFILE_GATE_UNAVAILABLE` with source PASS, Bridge promotes them directly to manual review without rerunning T020.
- `REVIEW ONLY` remains read-only and cannot replace the required physical UI/profile verification.

# Archer Dev Bridge v0.6.1-r3 — Stability & Recovery

Archer Dev Bridge — Windows GUI-оркестратор для разработки Godot 4 .NET/C# через Codex CLI. Ветка 0.6 объединяет Astra Operator, subagents, строгий Quality Gate, восстановление после сбоев и безопасное управление жизненным циклом задач.




## 0.6.10 — CLEAN Git BASE Confirmation Fix

- Git Inspector keeps the BASE action enabled even when the working tree is already CLEAN.
- On CLEAN Git the button reads `ПОДТВЕРДИТЬ BASE` and explicitly accepts the current HEAD as the ROADMAP BASE without creating an empty commit.
- On DIRTY Git it remains `СОЗДАТЬ BASE COMMIT`.
- Queue reconciliation happens before BASE lookup, so recovered `DONE/PASS` → `DONE_WAIT_BASE` state is handled in the same click.
- Existing Git safety and the 0.6.9 always-available self-destruct cancel behavior are preserved.

## 0.6.9 — Always-Available Self-Destruct Cancel

- `ОТМЕНА САМОУНИЧТОЖЕНИЯ` всегда остаётся активной: во время диагностики, BUSY, UI recovery, после уже выполненной отмены и в обычном idle-состоянии.
- Отмена идемпотентна: повторное нажатие безопасно и повторно фиксирует запрет автозакрытия/updater rollback.
- После первой отмены в текущем процессе действует sticky guard: `РАЗОБРАТЬСЯ`, Health Monitor и восстановление UI не могут снова взвести локальный countdown.
- Флаг `cancel-self-destruct.flag` повторно синхронизируется с UI/таймером, чтобы состояние не расходилось.
- Новый запуск Bridge по-прежнему намеренно начинает новый 30-секундный countdown.

## 0.6.8 — Roadmap Gate Recovery & Completion Signal

- Исправлен дефект 0.6.7: `DONE/PASS + CLEAN Git` больше не считается достаточным для запуска дочернего roadmap-этапа. Теперь требуется **явно подтверждённый BASE** (`baseConfirmed=true`).
- При обновлении с 0.6.7 зависимая задача, ошибочно ушедшая в `FAIL/BLOCKED` без изменений, автоматически возвращается в `WAITING_BASE`, а предыдущий `DONE/PASS` этап — в `DONE_WAIT_BASE`.
- Если Git уже CLEAN, кнопка `СОЗДАТЬ BASE COMMIT` может принять текущий HEAD как BASE без создания пустого commit.
- Перед запуском дочернего этапа Bridge добавляет в prompt доверенное orchestration-evidence: предыдущий Gate PASS, явный BASE, BASE HEAD и CLEAN Git. Astra не должна повторно спрашивать подтверждение зависимости.
- `OPERATOR_RESULT: BLOCKED` при отсутствии изменений и полностью PASS локальной проверке классифицируется как orchestration precondition; пустой auto-repair больше не запускается.
- Добавлен постоянный **СИГНАЛ ЗАВЕРШЕНИЯ**: зелёный для PASS/DONE, жёлтый для NEEDS_REVIEW, красный для FAIL/BLOCKED/ABORTED. Интерфейс мигает до ручного нажатия `УБРАТЬ СИГНАЛ`.
- Галочка `СИГНАЛ ЗАВЕРШЕНИЯ` полностью отключает эту функцию и сохраняется в `settings.json`.

## 0.6.7 — Roadmap Queue

- `ROADMAP: ждать BASE предыдущего этапа` связывает новые этапы в безопасную цепочку.
- Следующий этап хранится как `WAITING_BASE` и не запускается, пока предыдущий не прошёл Gate, ручную проверку и BASE commit.
- Успешный этап с зависимыми задачами становится `DONE_WAIT_BASE`; BASE commit переводит его в `DONE` и разблокирует только непосредственный следующий этап.
- На каждом запуске Bridge сверху мигает красная лампа с 30-секундным обратным отсчётом. До нажатия `ОТМЕНА САМОУНИЧТОЖЕНИЯ` запуск task/plan/gate/retry заблокирован.

## Штатный цикл

`TASK → PREFLIGHT → ASTRA OPERATOR → explorer → worker → reviewer → BUILD → TESTS → GODOT → GIT/SAFETY → STRICT GATE → HUMAN REVIEW`

Автоматический task-cycle не делает commit/push и оставляет изменения для человеческого просмотра. Начиная с 0.6.3 Git Inspector может создать BASE commit только по явному нажатию пользователя.

## Что нового в 0.6.0

- **EXE-first workflow**: пользователь запускает `ArcherDevBridge.exe`, установка/обновление — через графический `ArcherDevBridge_Setup_v0.6.1.exe`. Пользовательские `.cmd` больше не нужны.
- **Run Schema v2**: современные task-run отделены от legacy/history, diagnose/plan/verify не подменяют «последний цикл».
- **Полный Run Logging**: задача, context, Codex command/stdout/stderr/final, build/tests/Godot, Git, failure summary, change map и итоговый gate сохраняются в каталоге run.
- **Run Integrity Manifest**: `run-manifest.sha256` фиксирует SHA-256 артефактов завершённого run.
- **STOP**: активный процесс и его дочерние процессы можно остановить из GUI. Результат — `ABORTED`, а не ложный FAIL.
- **Watchdog**: зависший Codex/Build/Test/Godot автоматически останавливается по настраиваемому тайм-ауту.
- **Crash Recovery**: незавершённый run после закрытия Bridge/Windows распознаётся как `INTERRUPTED`.
- **Run Lock**: одновременно не допускается второй writer-cycle.
- **Single Instance Guard**: EXE-launcher не открывает второй GUI поверх уже работающего Bridge.
- **Preflight**: до Codex проверяются проект, `project.godot`, права записи, свободное место, Git и Codex Auth.
- **Task-scoped Rollback**: откат только файлов конкретного run через точечный `git restore --staged --worktree`; новые untracked-файлы удаляются только если они перечислены в change-map. `git reset --hard` не используется.
- **Retry failed stage**: Quality Gate можно повторить без повторного Codex-этапа; кодовый этап создаёт отдельный retry-run.
- **Change Map**: количество добавленных/изменённых/удалённых/новых файлов и полный список сохраняются для каждого task-run.
- **Sensitive File Guard**: изменения `.env`, `*.key`, `*.pem`, `*.pfx`, `secrets.json`, `credentials.json` и сходных credential-файлов вызывают Safety Stop.
- **Staging Guard**: staged changes после работы агента считаются нарушением workflow и вызывают Safety Stop.
- **Diagnostics Bundle**: одной кнопкой собирается ZIP с Health Monitor и последним современным run.
- **Run retention**: GUI позволяет задать число хранимых runs и лимит объёма и безопасно очищать старые логи.
- **Read-only Plan Mode**: Astra может изучить репозиторий и сформировать план без `workspace-write`.
- **Run Dashboard**: количество современных PASS/FAIL/OTHER отображается в шапке.
- **Расширенные статусы**: `DONE`, `FAIL`, `ABORTED`, `INTERRUPTED`, `BLOCKED`, `SAFETY_STOP`.

## Astra Operator

Основной оператор — `gpt-6-astra`. Bridge поддерживает профили:

- `archer_explorer` — read-only анализ;
- `archer_worker` — реализация в workspace;
- `archer_reviewer` — независимое read-only ревью.

Astra должна возвращать маркеры `OPERATOR_RESULT` и `OPERATOR_REVIEW`; после этого Bridge независимо прогоняет локальный Quality Gate.

## Auth / API

Штатный режим — Codex CLI, авторизованный через ChatGPT account/plan usage. Codex API-auth блокируется по умолчанию и требует явного разрешения. Legacy API planner/reviewer выключен по умолчанию. API key Bridge не сохраняет.

## System Health Monitor

Фирменные лампы Archer:

- зелёная — полностью готово;
- жёлтая — работает с предупреждением;
- красная — блокирующая проблема.

Проверяются Godot, Codex, Auth, Git, .NET, Project, Tests, Agents, Astra, страна и последний современный task-run.

## Страна

Страна определяется через интернет по внешнему IP. Bridge использует только код страны для отображения; GPS/координаты не запрашиваются. При VPN/proxy отображается страна сетевого выхода. При недоступности сервиса статус становится жёлтым и регион Windows не подставляется.

## Хранилище

Настройки и runtime-данные сохраняются вне каталога программы:

- `%LOCALAPPDATA%\ArcherDevBridge\settings.json`
- `%LOCALAPPDATA%\ArcherDevBridge\task-queue.json`
- `%LOCALAPPDATA%\ArcherDevBridge\runs\`
- `%LOCALAPPDATA%\ArcherDevBridge\diagnostics\`

Поэтому обновление программы не должно удалять настройки, очередь или логи.

## Установка / обновление

Запускается только графический `ArcherDevBridge_Setup_v0.6.1.exe`. Он устанавливает программу текущему Windows-пользователю в `%LOCALAPPDATA%\Programs\ArcherDevBridge`, сохраняет пользовательские данные и запускает GUI. ZIP поставляется отдельно как техническая/резервная база.

## Safety

Bridge автоматически не выполняет `git commit`, `push`, `reset --hard`, `rebase`, `clean` и не переписывает историю Git. Единственное исключение — явная кнопка `СОЗДАТЬ BASE COMMIT` в Git Inspector 0.6.3; она требует подтверждения и никогда не делает push. Неожиданное изменение HEAD, staged changes или изменение credential-файлов переводят run в Safety Stop. Небезопасные действия не маскируются под автоматический repair.


## Windows integration 0.6.1

Установщик создаёт ярлыки на Desktop и в Start Menu, направленные на `ArcherDevBridge.exe`. Командная строка пользователю не требуется.


### 0.6.1-r3 startup diagnostics
Launcher writes `%LOCALAPPDATA%\ArcherDevBridge\launcher\launcher-last.log`, `core-stdout.log`, `core-stderr.log` and requires `ui-ready.json` before startup is considered successful.

### 0.6.2-r2 hotfix
This build fixes a Windows PowerShell 5.1 collection-binding regression introduced by 0.6.2 Git Inspector. A dirty Git tree no longer breaks the whole System Health Monitor.

### 0.6.3 Git Diff & BASE
Git Inspector can now show a selected file diff, open the file, restore only a safe unstaged tracked file after confirmation, or create an explicit BASE commit of the current working copy. BASE commit is never automatic, does not push, and is blocked when conflicts/staged changes/detached HEAD are detected.

### Operator mode (0.6.4)
Use `ASTRA + ONE CODEX` for the current stable workflow: Astra operates and one Codex execution performs repository analysis, implementation, self-review and returns control to Bridge for the independent Quality Gate. `ASTRA + AI TEAM` enables the optional subagent team.

## 0.6.4-r4 UTF-8 hotfix
Codex prompts are transported through redirected stdin as raw UTF-8 bytes without BOM. This prevents Windows PowerShell 5.1 OEM/ANSI encoding from corrupting Russian/non-ASCII task text.

### 0.6.5 verified-timeout workflow
If Codex hits the watchdog but Build, Tests, Godot smoke and Git Safety all pass, Bridge records `NEEDS_REVIEW` instead of running an automatic repair. Use `ПРИНЯТЬ GATE`, `REVIEW ONLY`, or `ОТКЛОНИТЬ` in System Health Monitor.


## 0.6.6 repair lineage
Targeted repair tasks can inherit the working tree of a failed/review task. This is scoped: strict Clean Git remains mandatory for unrelated new tasks. Queue lineage is persisted in `task-queue.json` and run metadata.
