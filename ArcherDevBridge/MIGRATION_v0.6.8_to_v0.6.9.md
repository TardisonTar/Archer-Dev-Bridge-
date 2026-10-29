# Archer Dev Bridge 0.6.8 → 0.6.9

0.6.9 hardens the self-destruct cancellation path.

The **ОТМЕНА САМОУНИЧТОЖЕНИЯ** button is now always enabled. It remains clickable while diagnostics are running, while the UI is BUSY, after UI recovery, and after cancellation has already succeeded. Repeated clicks are safe and simply reassert the cancellation.

Once cancellation succeeds in the current Bridge process, a sticky in-process guard plus `cancel-self-destruct.flag` prevent `РАЗОБРАТЬСЯ`, Health Monitor or UI recovery from re-arming the 30-second auto-close timer.

A completely new Bridge launch still starts a fresh 30-second countdown; this preserves the original launch-safety design.
