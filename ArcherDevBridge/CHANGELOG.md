## 0.6.13 — Manual Gate ROADMAP Reconcile Fix
- Fixed accepted retry runs updating their retry ID instead of the canonical ROADMAP task.
- Manual release acceptance now moves the original task to `DONE_WAIT_BASE` and persists it immediately.
- Added startup recovery for 0.6.12: `MANUAL_RELEASE_ACCEPTED` + stale queue state is reconciled without rerunning Codex/Astra/tests.
- BASE remains unconfirmed until explicit Git Inspector confirmation.
- Preserved 0.6.12 structured-marker precedence and manual release safety gate.

# Archer Dev Bridge 0.6.12 — Structured Gate Precedence / Manual Release Check

- Structured Astra final markers now override historical stdout/stderr/report text.
- Stale `NU1301` evidence can no longer replace a current explicit blocker.
- Exported UI/profile automation blockers route to `WAITING_MANUAL_RELEASE_CHECK / NEEDS_REVIEW`.
- Manual release acceptance records user confirmation and runs only Git + package manifest/hash safety checks.
- Read-only review cannot falsely satisfy a manual exported-build requirement.
- Existing 0.6.11 T020 `BLOCKED_ENVIRONMENT` runs with structured manual-review evidence are migrated on startup to `NEEDS_REVIEW / WAITING_MANUAL_RELEASE_CHECK`; no new T020 retry is required.
- Existing BASE, Git, self-destruct and no-auto-commit protections are preserved.

## 0.6.11 — Operator outcome split

- `NEEDS_FIX`, `NEEDS_REVIEW` and `BLOCKED_ENVIRONMENT` are separate states.
- Environment blockers suppress source repair.

# ArcherDevBridge 0.6.4-r7

- Fixed retry button logic: selected failed queue task now enables retry even when global last-cycle is DONE.
- Retry of the same failed task is allowed over its own dirty working tree.
- Retry prompt explicitly preserves valid unfinished changes and forbids reset/clean.
- Queue status is updated after retry completion.
- Clean Git remains strict for new tasks; dirty bypass is limited to explicit retry flow.

# Archer Dev Bridge 0.6.4-r2

- Hotfix updater: terminate stale hidden ArcherDevBridge.ps1 PowerShell core before launching the new version.
- Prevent stale single-instance mutex from causing UI_READY timeout and rollback.
- Harden Add to Queue handler: unexpected queue errors are caught and shown instead of terminating the GUI.
- No gameplay/project files are changed by this update.

# Archer Dev Bridge — changelog

## 0.6.1-r3 — GUI launch handshake / clean setup fix
- Исправлен launcher: PowerShell ядро запускается в STA без видимой консоли и с полным stdout/stderr логированием.
- Launcher ждёт подтверждение `ui-ready.json`; если окно не появилось, показывает реальную ошибку вместо молчаливого успеха.
- Окно Bridge адаптируется к рабочей области экрана и принудительно активируется при первом показе.
- Добавлен single-instance mutex ядра.
- Clean Setup проверяет не просто процесс, а фактическое подтверждение показа GUI.
- Ярлык Desktop и Start Menu ведёт только на `ArcherDevBridge.exe`.

# Archer Dev Bridge v0.6.1

## Shortcut & Update Reliability Fix

- Установщик создаёт ярлык **Archer Dev Bridge** на фактическом рабочем столе Windows через Known Folder API, включая перенаправленный/OneDrive Desktop.
- Ярлык ведёт только на графический `ArcherDevBridge.exe`.
- Ярлык меню «Пуск» пересоздаётся при каждом обновлении.
- Установщик пытается корректно закрыть открытое окно Archer Dev Bridge перед заменой файлов и ждёт освобождения каталога.
- При невозможности заменить файлы установка считается неуспешной; ложного сообщения «установлено» больше нет.
- После установки проверяется существование `ArcherDevBridge.exe` и обоих ярлыков.
- Все функции 0.6.0 сохранены.

# Changelog

## 0.6.0 — Stability & Recovery

- Run Schema v2 и фильтрация legacy/history.
- «Последний цикл» учитывает только современные task-run; diagnose/verify/plan исключены.
- Полное сохранение Codex stdout/stderr/command/final и всех Quality Gate артефактов.
- Run Integrity Manifest SHA-256.
- STOP, watchdog, crash recovery и run lock.
- Single-instance EXE launcher.
- Preflight: диск, права записи, проект, Git, Auth.
- Task-scoped safe rollback без `git reset --hard`.
- Retry только упавшего/проверочного этапа.
- Change Map и сводка изменений каждого task-run.
- Staging Guard: staged changes → Safety Stop.
- Sensitive File Guard: credential/secret files → Safety Stop.
- Diagnostics Bundle ZIP.
- Настраиваемая очистка/retention run-логов.
- Read-only Astra Plan Mode.
- Run dashboard/metrics.
- Расширенные статусы DONE/FAIL/ABORTED/INTERRUPTED/BLOCKED/SAFETY_STOP.
- EXE-first пользовательский workflow; `.cmd` больше не используется как пользовательский установщик/launcher.
- Сохранены Archer Nakodil UI, фирменные лампы состояния, интернет-определение страны, Astra Operator/subagents, Auth Guard и Strict Quality Gate.

## 0.5.2 — Diagnostics & Run Logging

- Полное сохранение команды, stdout, stderr, exit code и final-message Codex.
- `run-state.json`, `failure-summary.txt`, `exception.txt` и расширенный gate summary.
- «РАЗОБРАТЬСЯ» анализирует последний development FAIL.

## 0.5.1 — Archer Status Lamps

- Фирменные зелёная/жёлтая/красная лампы Archer для System Health.

## 0.5.0 — Astra Operator Core

- Astra Operator + `archer_explorer`, `archer_worker`, `archer_reviewer`.
- ChatGPT Auth Guard, Task Queue, Strict Quality Gate, Safety Stop, Archer Nakodil UI.
- Страна по интернет/внешнему IP.

## 0.4.1

- System Health Monitor, «РАЗОБРАТЬСЯ», resolver путей Codex/Git/.NET.

## 0.4.0

- Выбор Codex model/reasoning, постоянные пути Godot/проекта, optional API planner/reviewer, Quality Gate/Godot smoke/Git checks.


## 0.6.2 — Git Inspector
- Exact Git DIRTY file classification in GUI.
- GIT ИЗМЕНЕНИЯ button.
- Diagnose report includes dirty file list and reason.
- No automatic destructive Git actions.

## 0.6.2-r2 — Health Monitor Hotfix
- Fixed `Argument types do not match` in System Health Monitor on Windows PowerShell 5.1 when the Git working tree is DIRTY.
- Git Inspector item collection is now PowerShell 5.1-safe.
- Added Git Inspector fallback so one parser problem cannot blank all health indicators.
- Added Health Monitor error-location logging for future diagnostics.

## 0.6.3 — Git Diff & Baseline
- Added GUI diff viewer for selected Git changes.
- Added Open File action from Git Inspector.
- Added guarded restore for an unstaged tracked file only, with explicit confirmation.
- Added explicit user-triggered BASE commit for accepting the current working copy as a clean starting point.
- BASE commit is blocked on conflicts, detached HEAD, existing staged changes, or missing Git identity.
- Automatic Bridge workflow still never commits or pushes.

## 0.6.4 — Operator Mode Patch
- Added `ASTRA + ONE CODEX` / `ASTRA + AI TEAM` selector.
- Default is ONE CODEX.
- ONE CODEX prompts explicitly prohibit subagent delegation.
- AI TEAM preserves explorer/worker/reviewer orchestration.
- Agent health no longer blocks ONE CODEX mode.
- Task/queue button labels reflect the active mode.
- Operator mode is saved in settings and run metadata/profile.

## 0.6.4-r3
- Critical updater rollback guard during active work.
- Cancel Self-Destruct button.
- UTF-8 no-BOM UI_READY handshake.

## 0.6.4-r4
- Critical UTF-8 stdin hotfix for Russian/non-ASCII Codex prompts on Windows PowerShell 5.1.
- Raw UTF-8 (no BOM) prompt bytes are written directly to Codex redirected stdin.
- Bridge text artifacts now use UTF-8 without BOM.
- Codex transport failures skip operator-review markers instead of reporting misleading NEEDS_FIX/unknown.
- UTF-8 transport failures are classified separately and do not trigger auto-repair.


## 0.6.4-r5
- Critical startup fix: restored UTF-8 BOM on ArcherDevBridge.ps1 for Windows PowerShell 5.1.
- Kept raw UTF-8 redirected stdin for Codex prompts.
- Updater validates the PowerShell core BOM before launch.


## 0.6.4-r7
- Fixed stale BUSY state after failed queue runs.
- Added forced/deferred UI recovery and a 2s stale-BUSY watchdog.
- Added manual «РАЗМОРОЗИТЬ UI» control.
- Retry control is re-enabled after failed modern runs.

## 0.6.4-r8
- Detached Operator Log window.
- Main dashboard no longer embeds the live log panel.

## 0.6.5 — Verified Timeout Handling
- Distinguishes Codex timeout from project failure.
- Local PASS + watchdog => NEEDS_REVIEW instead of FAIL.
- Adds manual Gate accept, read-only Codex review, and reject workflow.
- Skips automatic repair after watchdog timeout.


## 0.6.6 — Repair Lineage & Dirty Inheritance
- Added parent-child lineage for targeted repair tasks.
- Strict Clean Git now permits DIRTY only for a targeted repair explicitly linked to its parent task.
- New unrelated tasks are still blocked by DIRTY Git.
- Legacy targeted-repair queue rows auto-migrate on startup.
- Stale RUNNING queue state recovers to BLOCKED instead of hanging forever.
- Queue normalizes any non-started RUNNING cycle to BLOCKED with a reason.
- Run state/meta now records `parentTaskId`, `taskType`, and `inheritedWorkingTree`.

## 0.6.7 — Roadmap Queue & Self-Destruct Countdown
- Added dependency-aware ROADMAP queue with `WAITING_BASE` / `DONE_WAIT_BASE` states.
- Added `DEPENDS` column and persisted dependency metadata.
- A successful roadmap stage pauses before the next stage and requires an explicit human BASE commit.
- BASE commit unlocks only the direct dependent task; no automatic next-stage launch.
- Existing clean HEAD can be explicitly accepted as BASE when the working tree is already clean.
- Added 30-second blinking red self-destruct countdown in the header on every launch.
- Task/plan/gate/retry starts are blocked until «ОТМЕНА САМОУНИЧТОЖЕНИЯ» is pressed.
- Countdown never kills an already active run; active work cancels the local close for safety.
- Preserved 0.6.6 repair lineage, inherited DIRTY safety and verified-timeout handling.


## 0.6.8 — Roadmap Gate Recovery & Persistent Completion Signal
- Fixed 0.6.7 roadmap dependency bug: child stages require explicit `baseConfirmed`, not merely parent DONE/PASS plus clean Git.
- Added startup recovery for 0.6.7 invalid dependent runs with no working-tree changes.
- Added trusted dependency evidence to Codex prompts after Bridge verifies prior Gate PASS, BASE confirmation, BASE HEAD and CLEAN Git.
- Added no-empty-repair guard for operator precondition blocks with zero changes and locally passing verification.
- Added persistent green/yellow/red completion flashing until explicit acknowledgement.
- Added `СИГНАЛ ЗАВЕРШЕНИЯ` setting and `УБРАТЬ СИГНАЛ` acknowledgement control.
- Preserved self-destruct launch lock, updater guard, repair lineage, verified-timeout handling and Git safety.


## 0.6.9 — Self-Destruct Cancel Hardening
- Cancel Self-Destruct button is always enabled, including BUSY/diagnostics/recovery states and after cancellation.
- Cancellation is idempotent and may be pressed repeatedly.
- Added sticky in-process disarm state so Diagnose/Health/UI recovery cannot re-arm auto-close after the user cancelled it.
- UI state re-synchronizes from `cancel-self-destruct.flag`.
- Fresh Bridge launch still arms the 30-second countdown by design.


## 0.6.10 — Git Inspector CLEAN BASE Confirmation
- Fixed disabled BASE control on a clean working tree.
- CLEAN Git now exposes `ПОДТВЕРДИТЬ BASE`, which accepts the current HEAD as the explicit ROADMAP BASE without an empty commit.
- DIRTY Git keeps the normal `СОЗДАТЬ BASE COMMIT` workflow.
- ROADMAP reconciliation runs before BASE candidate selection so recovered DONE/PASS states are confirmed in one click.
- Preserves 0.6.9 self-destruct cancellation hardening and all Git safety guards.
