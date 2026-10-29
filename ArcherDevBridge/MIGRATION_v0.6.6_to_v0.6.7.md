# Archer Dev Bridge 0.6.6 → 0.6.7

## Roadmap Queue

0.6.7 adds dependency-aware roadmap tasks. Enable **ROADMAP: ждать BASE предыдущего этапа** before adding sequential stages.

- the first ready stage is `QUEUED`;
- later stages become `WAITING_BASE` and keep `DEPENDS=<previous task>`;
- a successful stage with dependents becomes `DONE_WAIT_BASE`;
- the queue stops and never starts the dependent stage automatically;
- after human review, **СОЗДАТЬ BASE COMMIT** marks the completed stage `DONE` and unlocks only its direct dependent task;
- strict Clean Git remains required for normal stages;
- targeted repair inheritance from 0.6.6 is unchanged.

## Self-Destruct countdown

Every Bridge launch now starts a 30-second visible safety countdown in the header. The red Archer lamp blinks until **ОТМЕНА САМОУНИЧТОЖЕНИЯ** is pressed. Development/verification start controls remain locked while the countdown is armed. If the timer reaches zero with no active work, Bridge closes itself. Active work is never killed by this local timer.

Existing settings, runs and queue data under `%LOCALAPPDATA%\ArcherDevBridge` are preserved and migrated automatically.
