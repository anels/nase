Run a self-diagnostic check to verify the workspace is properly configured and healthy. Use whenever something feels off — hooks not firing, backup warnings, or after a machine migration. Run proactively before starting a new sprint or after updating skills.

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
- Run `bash -n` on each: `session-start.sh`, `stop-backup.sh`, `stop-todos.sh`, `track-skill.sh`
- Pass: all files exist and pass syntax check
- Fail: missing or syntax error (report which)

<!-- Why: settings.json wires hooks to lifecycle events — a missing reference means the hook never fires -->
### 3. Hook configuration (settings.json)
```bash
python -m json.tool .claude/settings.json > /dev/null
```
- Check `.claude/settings.json` exists and is valid JSON
- Check SessionStart hook command contains `session-start.sh`
- Check Stop hook command contains `stop-backup.sh`
- Check Stop hook command contains `stop-todos.sh`
- Check PostToolUse hook command contains `track-skill.sh`
- Pass: valid JSON + all scripts referenced
- Fail: file missing / invalid JSON / scripts not wired up

<!-- Why: without a backup target, the Stop hook has nowhere to sync work/ — data loss risk -->
### 4. Backup configuration
- Check `.backup-target` exists at workspace root
- If only found at legacy `work/.backup-target`: warn (should be migrated)
- Read contents — verify path is non-empty and not `/`, `$HOME`, or `/c`
- Check if the target directory exists and appears writable (`ls {target}`)
- Pass: file exists, path looks safe, target accessible
- Warn: target directory does not exist yet (will be created on first Stop hook)
- Fail: not configured, empty path, or dangerous path

<!-- Why: confirms the last Stop hook run actually succeeded — catches silent failures -->
### 5. Last backup status
- Read last line of `work/logs/.backup-status` (if exists)
- Pass: last entry contains `[OK]`
- Warn: file does not exist (Stop hook has never run or work/logs/ missing)
- Fail: last entry contains `[ERROR]` or `[WARNING]`

<!-- Why: work/ holds all session data, KB, and logs — missing directories cause silent failures in other commands -->
### 6. work/ structure
Check for presence of key paths:
- `work/context.md`
- `work/kb/general/`
- `work/kb/projects/`
- `work/tasks/lessons.md`
- `work/logs/`
- Pass: all present
- Partial: some missing (list which)
- Not initialized: work/ does not exist

<!-- Why: git is the only hard external dependency — everything else is built-in -->
### 7. Required tools
```bash
command -v git
```
- Pass: git found
- Fail: git missing

<!-- Why: missing command files mean broken /nase:* skills — catches accidental deletions or incomplete installs -->
### 8. Command files
- List all `.md` files in `.claude/commands/nase/`
- Report count
- Flag any of the expected core commands that are missing:
  `doctor`, `help`, `init`, `onboard`, `kb-update`, `tech-digest`, `restore`,
  `learn`, `reflect`, `extract-skills`, `estimate-eta`, `improve-commit-message`,
  `update-changelog`, `today`, `wrap-up`, `stats`

</parallel>

</workflow>

## Output Format

---
**Workspace Doctor — {date}**

| # | Check | Status | Notes |
|---|-------|--------|-------|
| 1 | Git repo | OK / FAIL | {workspace root path} |
| 2 | Hook scripts | OK / FAIL | {details or "both OK"} |
| 3 | settings.json | OK / FAIL | {details} |
| 4 | Backup config | OK / WARN / FAIL | {target path or issue} |
| 5 | Last backup | OK / WARN / FAIL | {timestamp and result} |
| 6 | work/ structure | READY / PARTIAL / EMPTY | {missing paths if any} |
| 7 | Tools | OK / FAIL | {git status} |
| 8 | Commands | {N}/19 found | {missing names if any} |

**Result: {X}/8 checks passed**

**Action items:**
- {one actionable line per failed or warned check, in priority order}
---

If everything passes, suggest: "Workspace is healthy. Run `/help` for a command overview or `/onboard <repo-path>` to add a repo."
