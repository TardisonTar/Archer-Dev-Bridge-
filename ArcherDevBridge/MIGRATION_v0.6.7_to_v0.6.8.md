# Archer Dev Bridge 0.6.7 → 0.6.8

0.6.8 repairs the roadmap dependency gate introduced in 0.6.7.

If a child task was incorrectly started before explicit BASE acknowledgement and ended as FAIL/BLOCKED without changing the working tree, 0.6.8 restores it to `WAITING_BASE` and marks the completed parent as `DONE_WAIT_BASE`. Press **СОЗДАТЬ BASE COMMIT**; when Git is already CLEAN, Bridge accepts the current HEAD as the BASE without creating an empty commit. The direct child then becomes `QUEUED`.

A child task now starts only when all are true:

1. parent status is DONE/PASS;
2. `baseConfirmed=true`;
3. working tree is CLEAN;
4. current HEAD matches the recorded BASE HEAD when one is recorded.

Bridge also injects this verified evidence into the Astra/Codex task prompt so the coding agent does not stop to ask the user to reconfirm the previous gate.

Completion signaling is enabled by default. Green means PASS/DONE, yellow means review/warning, red means failure/block/abort. It continues blinking until **УБРАТЬ СИГНАЛ** is pressed. Disable the feature with **СИГНАЛ ЗАВЕРШЕНИЯ**.
