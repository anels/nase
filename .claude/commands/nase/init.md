Initialize or reconfigure the nase workspace. Use for first-time setup, after cloning on a new machine, or when work/config.md is missing. Safe to re-run — all steps check for existing state before making changes. Nothing is overwritten without confirmation.

**Input:** $ARGUMENTS (optional: AI engineer name, e.g. `/init Alice`)

## Steps

### 0. Check current state
Before doing anything, read the current state:
- Derive workspace name: `basename $(git rev-parse --show-toplevel)`
- Read `work/config.md` if it exists — note current `AI engineer:` and `workspace:` values
- Check if `.backup-target` exists at workspace root
- Check if `work/context.md` exists (workspace already initialized indicator)

Report what was found:
- "Workspace: {folder-name} ({initialized / not yet initialized})"
- "AI name: {current name or 'not set'}"
- "Backup: {configured to {path} / not configured}"

### 1. Collect all inputs (AskUserQuestion)

Use the `AskUserQuestion` tool to collect inputs interactively. Users can pick a preset option or select "Other" to type a custom value.

**Question 1 — AI engineer name** (skip if $ARGUMENTS is non-empty):
```
question: "What should I call myself? (current: {name})"
header: "AI Name"
options:
  - label: "Keep '{name}'" , description: "No change"
  - label: "Other"         , description: "Type a custom name"
```

**Question 2 — Backup location:**

Only include "Keep current" as an option if `.backup-target` already exists and has a non-empty path. If no backup is configured yet, omit it — "Keep current: not configured" is a nonsensical choice.

```
question: "Where should work/ be backed up? (current: {path or 'not configured'})"
header: "Backup"
options:
  - label: "Keep current"                    , description: "{current path}"  ← omit if not configured
  - label: "~/Documents/{workspace-name}-backup" , description: "Default local location (uses actual folder name)"
  - label: "Other"                           , description: "Type a custom path"
```

**Apply changes after both answers:**
- **Workspace name**: always write/update `workspace: {folder-name}` in `work/config.md` (auto-derived, no user input)
- **AI name**: if changed, write/update `AI engineer:` line in `work/config.md`; update `currently **{old}**` in MEMORY.md
- **Backup**: if changed, convert Windows path to bash format (`C:\foo\bar` → `/c/foo/bar`); write to `.backup-target`; verify reachable with `mkdir -p {target} && ls {target}`
- If the answer matches current value, skip writing

### 2. Offer restore if backup has content

This step only applies on a **fresh init** — skip it entirely if `work/context.md` already exists locally (the workspace is already populated and a restore would be destructive, not helpful).

After the backup target is confirmed (new or unchanged), check whether it already contains data:

```bash
# Sentinel check — context.md indicates a valid nase backup
ls "{backup-target}/context.md" 2>/dev/null
```

If `work/context.md` does NOT exist locally AND the sentinel exists in the backup:
- Count the files: `find "{backup-target}" -type f | wc -l`
- Find the most recently modified file: `find "{backup-target}" -type f -printf '%T@ %p\n' | sort -n | tail -1`
- Show the user:
  > "Backup found at `{backup-target}` ({N} files, last modified {timestamp})."

Then ask:
```
question: "A backup exists at {backup-target}. Restore work/ from it now?"
header: "Restore from backup"
options:
  - label: "Yes — restore now"  , description: "Overwrites current work/ with the backup"
  - label: "No — skip"          , description: "Continue init without restoring"
```

**If user chooses Yes**: invoke `/nase:restore` — it handles snapshot, overwrite, and verification.
**If user chooses No**: continue with the remaining init steps as normal.

If the backup target does not contain `context.md` (empty or non-existent directory): skip this step silently.

### 3. Initialize automation metadata
- Check if `work/reports/.report-status` exists
- If not, create it with empty entries:
  ```
  weekly-report=
  monthly-report=
  ```
- Ensure directories exist: `work/reports/daily/`, `work/reports/weekly/`, `work/reports/monthly/`
- Show current values (if any)
- No user input needed — this file is updated automatically by /nase:weekly-report and /nase:monthly-report

### 4. Verify hook installation
Run these checks:
```bash
bash -n .claude/hooks/session-start.sh
bash -n .claude/hooks/stop-backup.sh
bash -n .claude/hooks/stop-todos.sh
bash -n .claude/hooks/track-skill.sh
python -m json.tool .claude/settings.json > /dev/null || python3 -m json.tool .claude/settings.json > /dev/null
```
If both `python` and `python3` fail, note "Python not available — JSON validation skipped" and continue.
Also verify settings.json references all four scripts (grep for `session-start.sh`, `stop-backup.sh`, `stop-todos.sh`, and `track-skill.sh`).

- If all pass: "Hooks: OK"
- If any fail: list what's wrong with fix instructions (e.g., "Re-run from a clean clone" or "Run /doctor for details")

### 5. Initialize work/ skeleton
Create the following structure if it does not already exist. Preserve existing files — only create missing ones.
```bash
mkdir -p work/kb/projects work/kb/general work/logs work/tasks work/journals work/skills work/stats
```

Create stub files only if missing (do not overwrite existing content):
- `work/context.md`:
  ```markdown
  # Workspace Context

  ## Repos
  <!-- Added by /onboard <repo-path> -->

  ## Domain Patterns
  <!-- Updated by /kb-update -->
  ```
- `work/kb/general/workflow.md` — header: `# Workflow & Protocols`
- `work/kb/general/debugging.md` — header: `# Debugging Techniques`
- `work/tasks/lessons.md` — header: `# Lessons Learned`
- `work/tasks/todo.md` — header: `# Tasks`
- `work/tech-digest-config.md` — personal config for `/nase:tech-digest` (sources, filter topics, output sections); create with a minimal header and prompt the user to edit it before running `/nase:tech-digest`

Report: "work/ structure: {N} directories and files created / already existed"

### 6. Run doctor
Invoke `/nase:doctor` to verify the complete workspace state.

### 7. Star on GitHub (optional)

This workspace lives at `https://github.com/anels/nase` — the known repo for nase.

Detect the remote URL and parse the owner/repo:
```bash
git remote get-url origin 2>/dev/null
```
- HTTPS: `https://github.com/owner/repo.git` → `owner/repo`
- SSH: `git@github.com:owner/repo.git` → `owner/repo`
- If no remote is configured, fall back to `anels/nase`

Ask the user:
> "Star `{owner}/{repo}` on GitHub? (yes/no)"

If **yes**:
```bash
# MSYS_NO_PATHCONV=1 prevents Git Bash from rewriting the leading slash as a filesystem path
MSYS_NO_PATHCONV=1 gh api --method PUT /user/starred/{owner}/{repo}
```
- Success (HTTP 204): report "⭐ Starred {owner}/{repo}."
- HTTP 404: report "Repo not found — it may be private or not yet created on GitHub."
- If `gh` is not installed or not authenticated: report "GitHub CLI not available — skipping star. Run `gh auth login` to enable this."

If **no**: skip silently.

### 8. Confirm and suggest next steps
Report a summary:
- AI name: {name}
- Backup target: {path}
- Hooks: {OK / issues found}
- work/: {ready / partially ready}

Suggest next steps based on what's missing:
- If no repos onboarded: "Run `/onboard <repo-path>` to add your first repository"
- If tech-trends.md is missing: "Run `/tech-digest` to bootstrap the tech news feed"
- If `work/reports/.report-status` has no `weekly-report` date: "Run `/nase:weekly-report` to initialize the weekly report schedule"
- If doctor found issues: "Address the items listed by /doctor above"

## Notes
- This command is idempotent — safe to re-run after a machine migration or template update
- After re-running, the Stop hook will continue writing to the same `.backup-target`
- If migrating from an old workspace with `work/.backup-target`, move it to the workspace root and delete the old file
