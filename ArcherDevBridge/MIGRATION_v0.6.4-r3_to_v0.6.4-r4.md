# 0.6.4-r3 → 0.6.4-r4

Hotfix: UTF-8 Codex prompt transport.

- Redirected Codex stdin is now written as raw UTF-8 bytes (no BOM), bypassing Windows PowerShell 5.1 OEM/ANSI StreamWriter encoding.
- Bridge text artifacts are written as UTF-8 without BOM.
- If Codex fails before producing a final response, OPERATOR_REVIEW is marked SKIPPED instead of a misleading NEEDS_FIX/unknown.
- UTF-8 transport failures are classified as CODEX_INPUT_ENCODING and do not trigger the automatic project repair cycle.
- No gameplay or project files are changed by this Bridge update.
