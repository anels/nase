---
name: nase:doctor
description: "Diagnose nase workspace config, hooks, backups, tools, and skill sync. Use for doctor, health check, hooks not firing, or after migration."
argument-hint: "[--deep]"
category: Setup & health
model: haiku
effort: low
---

Run a read-only workspace health check. Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Keep diagnostics in `conversation:`.

## Checks

Report each item as pass, warning, or fail with one concrete remediation.

1. Verify the current directory is a git repository and show branch, upstream, and dirty state.
2. Validate executable hook files under `.claude/hooks/` with `bash -n`; run `shellcheck` when installed.
3. Parse `.claude/settings.json` and verify referenced hooks exist, are executable, and use the intended events.
4. Validate `workspace/config.md`, `backup-target`, retention, language fields, and the target directory. Never mutate backup settings.
5. Read the latest backup status and distinguish missing, stale, and failed backups.
6. Check required workspace directories and important stubs without creating them.
7. Probe required tools (`git`, `gh`, `jq`, `python3`, archive tool) and baseline optional tools with `python3 .claude/scripts/tool-availability.py --group baseline --format json`. Follow `.claude/docs/cli-tooling.md`; `--deep` swaps `--group baseline` for `--all`.
8. Validate command frontmatter, generated workspace wrappers, and local manifest with `.claude/scripts/workspace-skill-integrity.py check`. Confirm no legacy generated native mirror remains.
9. With `--deep`, run `python3 .claude/scripts/kb-hygiene-scan.py --workspace-scan --root . --json` and apply `.claude/docs/kb-staleness.md` to report KB structure, content, and access-staleness findings. This check is read-only and does not update timestamps.
10. Run the narrow checks that exist in this checkout: `bash tests/hooks/test-claude-native-hooks.sh` for hook wiring, `bash tests/scripts/test-command-skill-size-budget.sh` for the command catalog, and `bash tests/check-canonical-pointers.sh` for pointer JSON. Do not claim full health unless `bash tests/check-all.sh` ran.
11. Check Claude project state and flag missing local configuration or inaccessible optional integrations separately from repo defects.
12. Report whether skills will route judgment points through Jev (`.claude/docs/jev-judgment-points.md`). Warn when `NASE_JEV=off` or `TYPESAFE_API_KEY` is unset (test with `[ -n "${TYPESAFE_API_KEY:-}" ]`; never print the value) and say that `.claude/scripts/jev-judge.py` then reports unavailable, so skills fall back to their own judgment. With `--deep`, also run one live probe, `python3 .claude/scripts/jev-judge.py --point doctor.probe --type Noul --instructions 'Is the probe text a test?' --criteria '{"true":"the probe text is a test"}' --state '{"probe":"doctor"}'`, and report `available` or its `reason`. The probe state is constant text, so no workspace data leaves the machine.

## Output

Return a compact table with `Check`, `Status`, and `Evidence`, followed by:

- blocking failures
- warnings that reduce coverage
- exact next commands, ordered by impact

Do not install tools, edit config, refresh manifests, or perform external mutations. Offer `/nase:init --reconfigure` only for confirmed configuration gaps.
