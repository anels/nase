---
name: nase:doctor
description: Run a self-diagnostic check to verify the workspace is properly configured and healthy. Use when something feels off — hooks not firing, backup warnings, after a migration, or proactively before a new sprint.
---

## Checks

<workflow>

<parallel>

<!-- Why: without a valid git repo, hooks and relative paths break -->
### 1. Git repository
```bash
git rev-parse --show-toplevel
```
- Pass: repo root resolved cleanly
- Fail: not inside a git repository

<!-- Why: hooks drive session logging, backup, and todo tracking — missing or broken scripts silently disable automation -->
### 2. Hook scripts
- Check `.claude/hooks/session-start.sh` exists
- Check `.claude/hooks/stop-backup.sh` exists
- Check `.claude/hooks/stop-todos.sh` exists
- Check `.claude/hooks/track-skill.sh` exists
- Check `.claude/hooks/worktree-log.sh` exists
- Run `bash -n` on each: `session-start.sh`, `stop-backup.sh`, `stop-todos.sh`, `track-skill.sh`, `worktree-log.sh`
- Pass: all files exist and pass syntax check
- Fail: missing or syntax error (report which)

<!-- Why: settings.json wires hooks to lifecycle events — a missing reference means the hook never fires -->
### 3. Hook configuration (settings.json)
```bash
python3 -m json.tool .claude/settings.json > /dev/null 2>&1 || python -m json.tool .claude/settings.json > /dev/null 2>&1
```
- Check `.claude/settings.json` exists and is valid JSON
- Check SessionStart hook command contains `session-start.sh`
- Check Stop hook command contains `stop-backup.sh`
- Check Stop hook command contains `stop-todos.sh`
- Check PostToolUse hook command contains `track-skill.sh`
- If `worktree-log.sh` exists in `.claude/hooks/`, verify it is referenced in `.claude/settings.json`. If neither the file nor the reference exists, that's OK (optional hook). If the file exists but is NOT referenced, report as warning
- Pass: valid JSON + all scripts referenced
- Fail: file missing / invalid JSON / scripts not wired up

<!-- Why: without a backup target, the Stop hook has nowhere to sync workspace/ — data loss risk -->
### 4. Backup configuration
- Check `.local-paths` exists at workspace root and has a `backup-target=` entry
- Read the `backup-target=` value — verify path is non-empty and not `/`, `$HOME`, or `/c`
- Check if the target directory exists and appears writable (`ls {target}`)
- Pass: file exists, `backup-target=` entry present, path looks safe, target accessible
- Warn: target directory does not exist yet (will be created on first Stop hook)
- Fail: not configured, empty path, or dangerous path

<!-- Why: confirms the last Stop hook run actually succeeded — catches silent failures -->
### 5. Last backup status
- Read last line of `workspace/logs/.backup-status` (if exists)
- Pass: last entry contains `[OK]`
- Warn: file does not exist (Stop hook has never run or workspace/logs/ missing)
- Fail: last entry contains `[ERROR]` or `[WARNING]`

<!-- Why: workspace/ holds all session data, KB, and logs — missing directories cause silent failures in other commands -->
### 6. workspace/ structure
Check for presence of key paths:
- `workspace/context.md`
- `workspace/kb/general/`
- `workspace/kb/projects/`
- `workspace/kb/cross-project/`
- `workspace/tasks/lessons.md`
- `workspace/logs/`
- Pass: all present
- Partial: some missing (list which)
- Not initialized: workspace/ does not exist

<!-- Why: git and 7z are hard external dependencies — git for hooks/workflow, 7z for zip backups -->
### 7. Required tools
```bash
command -v git
command -v 7z
command -v jq
```
- Pass: git, 7z, and jq all found
- Warn: 7z missing — zip backups will fail (install with `brew install p7zip` on macOS, `apt install p7zip-full` on Linux, or `scoop install 7zip` on Windows)
- Warn: jq missing — skill usage tracking (`track-skill.sh`) will silently fail (install with `brew install jq` on macOS, `apt install jq` on Linux, or `scoop install jq` on Windows)
- Fail: git missing

<!-- Why: missing command files mean broken /nase:* skills — catches accidental deletions or incomplete installs -->
### 8. Command files
- Scan `.claude/commands/nase/` for all `.md` files (including `workspace/` subdirectory)
- Also check `workspace/skills/*.md` for work-specific skills (these are referenced by `.claude/settings.local.json` command entries)
- Report total count
- Build the expected list dynamically by reading file names from the directory — do NOT hardcode a list. This way new skills are automatically included in future checks.
- Cross-reference against the skill names registered in `.claude/settings.json` (under `permissions.allow` or hook configs) — flag any registered skill whose `.md` file is missing
- **Stale thin wrappers**: for each `.claude/commands/nase/workspace/*.md` file, read it and check if the `workspace/skills/{name}.md` file it points to still exists. Flag any wrapper whose target skill file is missing — these are dead references left over after a skill was deleted.

</parallel>

</workflow>

## Output Format

---
**Workspace Doctor — {date}**

| # | Check | Status | Notes |
|---|-------|--------|-------|
| 1 | Git repo | OK / FAIL | {workspace root path} |
| 2 | Hook scripts | OK / FAIL | {details or "all 5 OK"} |
| 3 | settings.json | OK / FAIL | {details} |
| 4 | Backup config | OK / WARN / FAIL | {target path or issue} |
| 5 | Last backup | OK / WARN / FAIL | {timestamp and result} |
| 6 | workspace/ structure | READY / PARTIAL / EMPTY | {missing paths if any} |
| 7 | Tools | OK / WARN / FAIL | {git + 7z + jq status} |
| 8 | Commands | {N} found | {missing from settings.json if any} |

**Result: {X}/8 checks passed**

**Action items:**
- {one actionable line per failed or warned check, in priority order}
---

If everything passes, suggest: "Workspace is healthy. Run `/help` for a command overview, `/onboard` to refresh all repos, or `/onboard <repo-path>` to add a new repo."

For structural issues (missing config, first-time setup), suggest `/nase:init`.
