---
paths:
  - ".claude/**"
  - "tests/**"
  - "CLAUDE.md"
  - "README.md"
---

# Workspace Maintenance

Rules for changing this repo's own commands, hooks, docs, scripts, and tests. They load when one of those files is read or edited.

## CI Pipeline

- Local gate: `bash tests/check-all.sh` (local `ruff`, `vermin` and `shellcheck` skip if missing; CI still runs all three). Run `bash tests/check-all.sh --links` separately for the optional local `lychee` check.
- Python lint config is `.ruff.toml` at the repo root. Every ignore there carries the reason it is ignored; add a rule to that list only with one, and prefer a scoped `# noqa: RULE - why` at the single site that needs it.
- `tests/check-boundary-terms.sh` enforces `workspace/context.md → Workspace Boundary Policy` over tracked files from the git-ignored `workspace/boundary-terms.txt`. It skips with a notice when that list is absent, and reports `path:line` with the term redacted. Replace a finding with a generic placeholder; never suppress the gate.
- If `tests/check-local-sensitive-artifacts.sh` fails, treat the named ignored artifact as sensitive and inspect only through locally redacted output. Prepare the exact local removal or credential rotation, but require separate named approval before either action, then rerun the gate. Never render the matched value, stage the artifact, or suppress the gate.

## Runtime Dependencies

- Required: `git`, `gh`, `jq`, and `python3` 3.10+. Backups require `7z` or `zip`; restoring legacy `.7z` archives requires `7z` or `7zz`.
- Optional agent tools are warning-only. Use `/nase:doctor` for the baseline set, `/nase:doctor --deep` for the full probe, and `.claude/docs/cli-tooling.md` before adding new tool-dependent skill behavior.
- `.local-paths` lives at repo root, is not backed up, and stores `backup-target=` plus `RepoName=/absolute/path` entries managed by `/nase:init` and `/nase:onboard`.

## Hooks, Skills, And Scope

- Hook registrations live in `.claude/settings.json`; hook behavior and file layout are summarized in `.claude/docs/reference.md`. Read those only when debugging or changing hooks.
- `session-start.sh` syncs `workspace/skills/*.md` to `.claude/commands/nase/workspace/`; each becomes `/nase:workspace:<name>`. It removes legacy generated native mirrors to avoid duplicate model invocation. Add a skill by creating `workspace/skills/<name>.md` and restarting.
- Create hooks, commands, and skills under `.claude/`. Writing to `~/.claude/` requires explicit user approval.
- New skill proposals must answer: "what existing skill does this make redundant, and if none, why isn't this a flag on an existing one?" Refuse overlapping trigger clones.

## References

- `CLAUDE.md` holds no runtime values; use `workspace/logs/`, `workspace/tasks/`, or KB.
- Skills reference shared docs instead of duplicating algorithms.
- When changing a shared helper, command field set, or workflow phase, update the helper, consuming command, shared reference doc, and focused regression test together; `tests/check-shared-doc-refs.sh` catches missing paths, not semantic drift.
