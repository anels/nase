---
name: nase:doctor
description: "Run a self-diagnostic check to verify the workspace is properly configured and healthy. Use when something feels off — hooks not firing, backup warnings, after a migration, or proactively before a new sprint. Triggers: 'doctor', 'check workspace', 'diagnose nase', 'verify config', 'health check', 'workspace doctor', 'is nase healthy', '检查工作区', '诊断'."
---

## Checks

### 0. Language preflight (MUST run first, non-negotiable)

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Missing `workspace/config.md` defaults to English AND becomes a finding in Check 7.
Read-only diagnostic. It references `.claude/docs/external-mutation-policy.md` only to verify guard wiring; it must not perform external mutations.

<workflow>

<parallel>

<!-- Why: without a valid git repo, hooks and relative paths break -->
### 1. Git repository
```bash
git rev-parse --show-toplevel
```
- Pass: repo root resolved cleanly
- Fail: not inside a git repository

<!-- Why: hooks drive session logging, backup, todo tracking, and destructive-command guardrails — missing or broken scripts silently disable automation -->
### 2. Hook scripts
- Check `.claude/hooks/session-start.sh` exists
- Check `.claude/hooks/stop-backup.sh` exists
- Check `.claude/hooks/stop-todos.sh` exists
- Check `.claude/hooks/track-skill.sh` exists
- Check `.claude/hooks/track-skill-prompt.sh` exists
- Check `.claude/hooks/worktree-log.sh` exists
- Check `.claude/hooks/block-dangerous-git.sh` exists
- Check `.claude/hooks/slack-send-guard.sh` exists
- Check `.claude/hooks/jira-write-guard.sh` exists
- Check `.claude/hooks/confluence-size-guard.sh` exists
- Check `.claude/hooks/pre-compact-archive.sh` exists
- Check `.claude/hooks/style-edit-detect.sh` exists
- Run `bash -n` on each required hook: `session-start.sh`, `stop-backup.sh`, `stop-todos.sh`, `track-skill.sh`, `track-skill-prompt.sh`, `worktree-log.sh`, `block-dangerous-git.sh`, `slack-send-guard.sh`, `jira-write-guard.sh`, `confluence-size-guard.sh`, `pre-compact-archive.sh`, `style-edit-detect.sh`
- If `.claude/hooks/edit-typecheck.sh` exists, run `bash -n` on it too, but treat it as optional/local
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
- Check PreToolUse hook command contains `block-dangerous-git.sh`
- Check PreToolUse hook command contains `slack-send-guard.sh` for `slack_send_message`
- Check PreToolUse hook command contains `jira-write-guard.sh` for Jira mutation tools
- Check PreToolUse hook command contains `confluence-size-guard.sh` for Confluence page writes
- Check PostToolUse hook command contains `track-skill.sh`
- Check PreCompact hook command contains `pre-compact-archive.sh`
- Check UserPromptSubmit hook command contains `track-skill-prompt.sh`
- Check UserPromptSubmit hook command contains `style-edit-detect.sh`
- Check WorktreeCreate does not wire `worktree-log.sh` (Claude Code expects WorktreeCreate hooks to create the worktree and print the path)
- Check WorktreeRemove hook command contains `worktree-log.sh`
- If `edit-typecheck.sh` exists in `.claude/hooks/`, do not require it in `.claude/settings.json`; it is optional/local.
- Pass: valid JSON + all required scripts referenced
- Fail: file missing / invalid JSON / scripts not wired up

<!-- Why: without a backup target, the Stop hook has nowhere to sync workspace/; unsafe targets can overwrite or recursively back up the workspace itself -->
### 4. Backup configuration
- Check `.local-paths` exists at workspace root and has a `backup-target=` entry
- Read the `backup-target=` value — verify path is non-empty and not `/`, `$HOME`, `/c`, or inside this repo's `workspace/` directory
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

<!-- Why: git, gh, jq, python3, and archive tools are hard external dependencies — git for repo context, gh for GitHub workflows, jq for hook JSON parsing, python3 for date/stat helpers, and 7z or zip+unzip for backups/restores -->
### 7. Required tools
```bash
command -v git
command -v gh
command -v jq
command -v python3
command -v 7z || { command -v zip && command -v unzip; }
```
- Pass: git, gh, jq, python3, and either 7z or zip+unzip all found
- Fail: jq missing — Bash safety hooks cannot parse Claude Code tool input and will block Bash calls by design; install jq before using skip permissions
- Fail: git missing
- Fail: python3 missing — date ranges, stats, recaps, and KB-gap helpers cannot run
- Warn: gh missing — GitHub PR metadata, diff, review, and PR creation workflows are unavailable (install from `https://cli.github.com/` or your package manager)
- Warn: gh installed but `gh auth status` fails — GitHub workflows may fail until `gh auth login` succeeds
- Warn: neither 7z nor zip+unzip found — workspace backups or restores will fail (install with `brew install p7zip` on macOS, `apt install p7zip-full` on Linux, or `scoop install 7zip` on Windows)

<!-- Why: optional agent tools make search, parsing, and verification more deterministic; missing tools should warn, not fail, so task-specific packs do not block unrelated workflows -->
### 8. Agent CLI tools
Read `.claude/docs/cli-tooling.md` for the selection rules and fallback policy.

Baseline check:
```bash
python3 .claude/scripts/tool-availability.py --group baseline --format table
python3 .claude/scripts/tool-availability.py --group baseline --missing --install brew
```
- Pass: all baseline tools found
- Warn: one or more baseline tools missing. Report the missing tool names, the install command from `--missing --install brew`, and the degraded workflow impact from the table.
- Do not fail doctor solely because recommended tools are missing.
- If `$ARGUMENTS` contains `--deep`, also run:
  ```bash
  python3 .claude/scripts/tool-availability.py --all --format table
  ```
  Group output by the tool group column.

<!-- Why: missing command files mean broken /nase:* skills — catches accidental deletions or incomplete installs -->
### 9. Command files
- Scan `.claude/commands/nase/` for all `.md` files (including `workspace/` subdirectory)
- Also check `workspace/skills/*.md` for work-specific skills (these are referenced by `.claude/settings.local.json` command entries)
- Report total count
- Build the expected list dynamically by reading file names from the directory — do NOT hardcode a list. This way new skills are automatically included in future checks.
- Cross-reference against the skill names registered in `.claude/settings.json` (under `permissions.allow` or hook configs) — flag any registered skill whose `.md` file is missing
- **Stale thin wrappers**: for each `.claude/commands/nase/workspace/*.md` file, read it and check if the `workspace/skills/{name}.md` file it points to still exists. Flag any wrapper whose target skill file is missing — these are dead references left over after a skill was deleted.

<!-- Why: Claude Code project state (~/.claude/projects/<encoded-cwd>/) accumulates transcripts + config over time; large state slows session start and risks stale data. v2.1.126+ exposes `claude project purge` to clean it. -->
### 10. Claude Code project state
- Resolve project state directory: `~/.claude/projects/$(pwd | sed 's|[/.]|-|g')/` (CC encodes the absolute working-dir path by replacing **both** `/` and `.` with `-` — e.g., `/Users/jane.doe/repo` → `-Users-jane-doe-repo`).
- If the directory does not exist: report SKIP (first-time use, nothing to clean).
- If it exists, run `du -sh "$dir"` for total size and `find "$dir" -maxdepth 2 -name '*.jsonl' | wc -l` for transcript file count (jsonl files live one or two levels deep, alongside per-session subdirectories).
- Pass: size < 500 MB and transcript count < 500.
- Warn: size ≥ 500 MB **or** transcript count ≥ 500 — suggest previewing cleanup with `claude project purge --dry-run "$(pwd)"` (Claude Code v2.1.126+). Do NOT auto-run purge — it deletes all CC state for the project including transcripts. User must approve and run manually.
- Note: nase-01 backups include only `workspace/`; CC project state is separate and not part of nase backups, so purge is safe with respect to nase data.

</parallel>

</workflow>

## Output Format

---
**Workspace Doctor — {date}**

| # | Check | Status | Notes |
|---|-------|--------|-------|
| 1 | Git repo | OK / FAIL | {workspace root path} |
| 2 | Hook scripts | OK / FAIL | {details or "all required hooks OK"} |
| 3 | settings.json | OK / FAIL | {details} |
| 4 | Backup config | OK / WARN / FAIL | {target path or issue} |
| 5 | Last backup | OK / WARN / FAIL | {timestamp and result} |
| 6 | workspace/ structure | READY / PARTIAL / EMPTY | {missing paths if any} |
| 7 | Tools | OK / WARN / FAIL | {git + gh + jq + archive tool status} |
| 8 | Agent CLI tools | OK / WARN | {baseline present/missing; install command if any} |
| 9 | Commands | {N} found | {missing from settings.json if any} |
| 10 | CC project state | OK / WARN / SKIP | {size + transcript count, or "no state dir"} |

**Result: {X}/10 checks passed**

**Action items:**
- {one actionable line per failed or warned check, in priority order}
---

If everything passes, suggest: "Workspace is healthy. Run `/nase:help` for a command overview, `/nase:onboard` to refresh all repos, or `/nase:onboard <repo-path>` to add a new repo."

For structural issues (missing config, first-time setup), suggest `/nase:init`.
