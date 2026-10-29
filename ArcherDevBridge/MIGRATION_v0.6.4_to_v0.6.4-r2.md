# Migration 0.6.4 -> 0.6.4-r2

Hotfix only. Settings, task queue, runs and project data remain in LocalAppData and are preserved. The updater now stops both the GUI launcher and any hidden PowerShell core process before replacing the installation, preventing a stale single-instance mutex from blocking the new GUI.
