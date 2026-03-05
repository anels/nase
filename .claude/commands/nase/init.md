Initialize or reconfigure the nase workspace.

Safe to re-run — all steps check for existing state before making changes. Nothing is overwritten without confirmation.

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

### 1–2. Collect all inputs (AskUserQuestion)

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
```
question: "Where should work/ be backed up? (current: {path})"
header: "Backup"
options:
  - label: "Keep current"                    , description: "{current path}"
  - label: "~/Documents/{workspace-name}-backup" , description: "Default local location (uses actual folder name)"
  - label: "Other"                           , description: "Type a custom path"
```

**Apply changes after both answers:**
- **Workspace name**: always write/update `workspace: {folder-name}` in `work/config.md` (auto-derived, no user input)
- **AI name**: if changed, write/update `AI engineer:` line in `work/config.md`; update `currently **{old}**` in MEMORY.md
- **Backup**: if changed, convert Windows path to bash format (`C:\foo\bar` → `/c/foo/bar`); write to `.backup-target`; verify reachable with `mkdir -p {target} && ls {target}`
- If the answer matches current value, skip writing

### 2.5. Initialize automation metadata
- Check if `work/logs/.report-status` exists
- If not, create it with empty entries:
  ```
  weekly-report=
  monthly-report=
  ```
- Show current values (if any)
- No user input needed — this file is updated automatically by /nase:weekly-report and /nase:monthly-report

### 3. Verify hook installation
Run these checks:
```bash
bash -n .claude/hooks/session-start.sh
bash -n .claude/hooks/stop-backup.sh
python -m json.tool .claude/settings.json > /dev/null
```
Also verify settings.json references both scripts (grep for `session-start.sh` and `stop-backup.sh`).

- If all pass: "Hooks: OK"
- If any fail: list what's wrong with fix instructions (e.g., "Re-run from a clean clone" or "Run /doctor for details")

### 4. Initialize work/ skeleton
Create the following structure if it does not already exist. Preserve existing files — only create missing ones.
```bash
mkdir -p work/kb/projects work/kb/general work/logs work/tasks
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

### 5. Run doctor
Invoke `/nase:doctor` to verify the complete workspace state.

### 5.5. Star on GitHub (optional)

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

### 6. Confirm and suggest next steps
Report a summary:
- AI name: {name}
- Backup target: {path}
- Hooks: {OK / issues found}
- work/: {ready / partially ready}

Suggest next steps based on what's missing:
- If no repos onboarded: "Run `/onboard <repo-path>` to add your first repository"
- If tech-trends.md is missing: "Run `/tech-digest` to bootstrap the tech news feed"
- If `.report-status` has no `weekly-report` date: "Run `/nase:weekly-report` to initialize the weekly report schedule"
- If doctor found issues: "Address the items listed by /doctor above"

## Notes
- This command is idempotent — safe to re-run after a machine migration or template update
- After re-running, the Stop hook will continue writing to the same `.backup-target`
- If migrating from an old workspace with `work/.backup-target`, move it to the workspace root and delete the old file
