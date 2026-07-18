---
name: nase:doctor
description: "Diagnose nase workspace configuration, hooks, backups, tools, and skill sync. Use for doctor, health check, hooks not firing, backup warnings, or after migration."
argument-hint: "[--deep]"
pattern: utility
category: Setup & health
---

Run a read-only workspace health check. Run `.claude/docs/language-config.md` first and keep diagnostics in `conversation:`.

## Checks

Report each item as pass, warning, or fail with one concrete remediation.

1. Verify the current directory is a git repository and show branch, upstream, and dirty state.
2. Validate executable hook files under `.claude/hooks/` with `bash -n`; run `shellcheck` when installed.
3. Parse `.claude/settings.json` and verify referenced hooks exist, are executable, and use the intended events.
4. Validate `workspace/config.md`, `backup-target`, retention, language fields, and the target directory. Never mutate backup settings.
5. Read the latest backup status and distinguish missing, stale, and failed backups.
6. Check required workspace directories and important stubs without creating them.
7. Probe required tools (`git`, `gh`, `jq`, `python3`, archive tool) and baseline optional tools through `.claude/scripts/tool-availability.py`. Follow `.claude/docs/cli-tooling.md`; `--deep` adds all optional groups.
8. Validate command frontmatter, generated workspace wrappers, and local manifest with `.claude/scripts/workspace-skill-integrity.py check`. Confirm no legacy generated native mirror remains.
9. Run the narrow JSON, hook-wiring, and command-catalog checks available in this checkout. Do not claim full health unless `bash tests/check-all.sh` ran.
10. Check Claude project state and flag missing local configuration or inaccessible optional integrations separately from repo defects.

## Output

Return a compact table with `Check`, `Status`, and `Evidence`, followed by:

- blocking failures
- warnings that reduce coverage
- exact next commands, ordered by impact

Do not install tools, edit config, refresh manifests, or perform external mutations. Offer `/nase:init --reconfigure` only for confirmed configuration gaps.
