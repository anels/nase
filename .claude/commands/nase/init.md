---
name: nase:init
description: "Initialize or reconfigure the nase workspace. Use for first-time setup, after cloning on a new machine, or when workspace/config.md is missing. Safe to re-run — idempotent. Triggers: 'init nase', 'setup workspace', 'configure nase', 'first-time setup', 'reconfigure workspace', 'bootstrap nase'."
argument-hint: "[--reconfigure]"
pattern: pipeline
category: Setup & health
---

**Input:** $ARGUMENTS (optional: AI engineer name, e.g. `/nase:init Alice`)

## Steps

### 0. Check current state
Before doing anything, read the current state:
- Derive workspace name: `basename "$(git rev-parse --show-toplevel)"`
- Read `workspace/config.md` if it exists — note current `AI engineer:`, `workspace:`, and `## Language` section (`conversation:` and `output:` values)
- Check if `.local-paths` exists at workspace root and has a `backup-target=` entry
- Check if `workspace/context.md` exists (workspace already initialized indicator)

Report what was found:
- "Workspace: {folder-name} ({initialized / not yet initialized})"
- "AI name: {current name or 'not set'}"
- "Backup: {configured to {path} / not configured}"
- "Language: conversation={value or 'not set'}, output={value or 'not set'}"

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

Only include "Keep current" as an option if `.local-paths` already exists and has a non-empty `backup-target=` entry. If no backup is configured yet, omit it — "Keep current: not configured" is a nonsensical choice.

```
question: "Where should workspace/ be backed up? (current: {path or 'not configured'})"
header: "Backup"
options:
  - label: "Keep current"                    , description: "{current path}"  ← omit if not configured
  - label: "~/Documents/{workspace-name}-backup" , description: "Default local location (uses actual folder name)"
  - label: "Other"                           , description: "Type a custom path"
```

**Question 3 — Backup retention policy:**

```
question: "How many backups should be kept? (current: {value or 'count:100 (default)'})"
header: "Backup Retention"
options:
  - label: "count:100"  , description: "Keep the last 100 backups (default)"
  - label: "count:50"   , description: "Keep the last 50 backups"
  - label: "days:30"    , description: "Keep backups from the last 30 days"
  - label: "days:7"     , description: "Keep backups from the last 7 days"
  - label: "Other"      , description: "Type a custom policy (format: count:N or days:N)"
```

**Question 4 — Conversation language** (the language used when responding to the user):
```
question: "What language should I use in conversation? (current: {conversation value or '简体中文 (default)'})"
header: "Conversation Language"
options:
  - label: "简体中文"    , description: "Simplified Chinese"
  - label: "English"     , description: "English"
  - label: "日本語"      , description: "Japanese"
  - label: "Other"       , description: "Type a language name"
```

**Question 5 — Output language** (the language for external platforms: GitHub, Jira, Confluence, Slack, commits):
```
question: "What language should I use for external output (GitHub, Jira, Slack, etc.)? (current: {output value or 'English (default)'})"
header: "Output Language"
options:
  - label: "English"     , description: "English (recommended for international teams)"
  - label: "简体中文"    , description: "Simplified Chinese"
  - label: "Same as conversation" , description: "Use the conversation language for output too"
  - label: "Other"       , description: "Type a language name"
```

**Apply changes after all answers:**
- **Workspace name**: always write/update `workspace: {folder-name}` in `workspace/config.md` (auto-derived, no user input)
- **AI name**: if changed, write/update `AI engineer:` line in `workspace/config.md`; update `currently **{old}**` in MEMORY.md
- **Backup**: if changed, convert Windows path to bash format (`C:\foo\bar` → `/c/foo/bar`); write/update the `backup-target=` line in `.local-paths`; verify reachable with `mkdir -p {target} && ls {target}`
- **Retention**: write/update `backup_retention: {value}` line in `workspace/config.md` (e.g. `backup_retention: count:100` or `backup_retention: days:7`)
- **Language**: write/update the `## Language` section in `workspace/config.md` with `conversation: {value}` and `output: {value}`. If "Same as conversation" was chosen for output, write the actual conversation language value. If the section doesn't exist, append it after the last line.
- If the answer matches current value, skip writing

### Step 1b (Optional): Configure Integrations (Jira + Slack)

**Explicit gate** — invoke `AskUserQuestion` first; only proceed if the user opts in:

```
question: "Configure Jira and Slack integrations now? (auto-discovers cloudId; asks for channel list)"
header: "Integrations"
options:
  - label: "Yes — configure both"     , description: "Auto-discover Jira via Atlassian MCP; ask for Slack channels"
  - label: "Jira only"                 , description: "Skip Slack channel setup"
  - label: "Slack only"                , description: "Skip Jira auto-discovery"
  - label: "No — skip integrations"    , description: "Configure later by re-running /nase:init"
```

If the user picked **No — skip integrations**: skip Step 1b entirely. If they picked one of the partial options, run only the corresponding sub-step below. If they picked both: run the two sub-steps in parallel. Check Atlassian / Slack MCP connectivity before each.

Run these two sub-steps in parallel. Write results to the `## Jira` and `## Slack` sections of `workspace/config.md` (create sections if missing, update if already present).

**Jira — auto-discover:**
- Call Atlassian MCP `getAccessibleAtlassianResources` (no parameters needed)
- On success: extract `id` (→ `cloudId`) and `url` (→ `baseUrl`) from the first resource
- Write to `workspace/config.md`:
  ```
  ## Jira
  cloudId: {id}
  baseUrl: {url}
  ```
- Report: "Jira: configured (cloudId: {id})"
- If MCP unavailable or returns empty: report "Jira: MCP not connected — skipped (re-run `/nase:init` after connecting Atlassian MCP)" and skip

**Slack — ask for channels:**
- Read current `## Slack > channels` list from `workspace/config.md` (may be empty on first run)
- Suggest channel names derived from repo names in `.local-paths` (e.g. `{service-repo}` → `oncall-{service}`, `dev-{service}`) as starting point
- Use `AskUserQuestion`:
  ```
  question: "Which Slack channels should I monitor for pulse? (current: {list or 'none'})"
  header: "Slack Channels"
  options:
    - label: "Keep current"         , description: "{current list}"   ← omit if empty
    - label: "Use suggested"        , description: "{suggested list from repos}"
    - label: "Other"                , description: "Type comma-separated channel names"
  ```
- Write chosen channels to `workspace/config.md`:
  ```
  ## Slack
  channels:
    - {channel1}
    - {channel2}
  ```
- If Slack MCP unavailable: still save the channel list — it's just names, not IDs

### 2. Offer restore if backup has content (fresh init only)

Skip this step if `workspace/context.md` already exists locally — the workspace is populated and a restore would be destructive.

When `workspace/context.md` does NOT exist locally, delegate the entire restore offer to `/nase:restore` — it already owns backup detection, the user prompt, snapshot, overwrite, and verification. Calling it twice is harmless; the skill no-ops when no usable backup is present.

```
Invoke /nase:restore (it self-detects whether there is anything to restore and prompts the user if so).
```

After `/nase:restore` returns (or self-skips), continue with the remaining init steps. Do not re-implement the file-count / sentinel / prompt logic here — keep init focused on configuration, not restore.

### 3. Verify hook installation
Run these checks:
```bash
for f in .claude/hooks/*.sh; do bash -n "$f"; done
python3 -m json.tool .claude/settings.json > /dev/null 2>&1 || python -m json.tool .claude/settings.json > /dev/null 2>&1
```
If both `python` and `python3` fail, note "Python not available — JSON validation skipped" and continue.
Also verify settings.json references these required lifecycle hooks:
- `session-start.sh`
- `stop-backup.sh`
- `stop-todos.sh`
- `track-skill.sh`
- `track-skill-prompt.sh`
- `worktree-log.sh`
- `block-dangerous-git.sh`
- `slack-send-guard.sh`
- `jira-write-guard.sh`
- `confluence-size-guard.sh`
- `pre-compact-archive.sh`

`edit-typecheck.sh` is optional/local; syntax-check it if the file exists, but do not require it in settings.json.

- If all pass: "Hooks: OK"
- If any fail: list what's wrong with fix instructions (e.g., "Re-run from a clean clone" or "Run /nase:doctor for details")

### 4. Initialize workspace/ skeleton
Create the following structure if it does not already exist. Preserve existing files — only create missing ones.
```bash
mkdir -p workspace/kb/projects workspace/kb/projects/tech-debt workspace/kb/projects/decisions workspace/kb/cross-project workspace/kb/general workspace/kb/ops workspace/logs workspace/tasks workspace/journals workspace/skills workspace/stats workspace/recaps
```

Create stub files only if missing (do not overwrite existing content):
- `workspace/context.md`:
  ```markdown
  # Workspace Context

  ## Repos
  <!-- Added by /nase:onboard <repo-path> -->

  ## Domain Patterns
  <!-- Updated by /kb-update -->
  ```
- `workspace/kb/general/workflow.md` — header: `# Workflow & Protocols`
- `workspace/kb/general/debugging.md` — header: `# Debugging Techniques`
- `workspace/tasks/lessons.md` — header: `# Lessons Learned`
- `workspace/tasks/todo.md` — header: `# Tasks`
- `workspace/kb/ops/customer-support.md` — header and content:
  ```
  # Customer Support — Common Questions
  > Add common customer Q&A patterns here.
  ```
- `workspace/kb/ops/customer-issues.md` — header and content:
  ```
  # Customer Issues — Investigation Patterns
  > Add common investigation patterns and customer misunderstandings here.
  ```
- `workspace/tech-digest-config.md` — personal config for `/nase:tech-digest` (sources, filter topics, output sections); create with a minimal header and prompt the user to edit it before running `/nase:tech-digest`

Create `.local-paths` stub if missing (at workspace root, not inside `workspace/`):
```
# Machine-specific paths — managed by /nase:init and /nase:onboard
# Re-run /nase:init on each new machine to populate
# Format: key=/absolute/path
```

Report: "workspace/ structure: {N} directories and files created / already existed"

### 5. Run doctor
Invoke `/nase:doctor` to verify the complete workspace state.

### 6. Offer to star the repo
Ask the user:
```
question: "Enjoying nase? Want to star the repo on GitHub?"
header: "Star"
options:
  - label: "Yes — star it"  , description: "Star anels/nase on GitHub"
  - label: "No — skip"      , description: "Continue without starring"
```
If the user chooses Yes, star the repo via Bash — but guard for `gh` install + auth first so a fresh-machine init doesn't surface a noisy error:
```bash
if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI not installed — skipping star. Install from https://cli.github.com/ or your package manager"
elif ! gh auth status >/dev/null 2>&1; then
  echo "gh not authenticated — skipping star. Run: gh auth login"
else
  gh api -X PUT /user/starred/anels/nase && echo "starred ⭐" || echo "star failed (network or perms)"
fi
```

### 7. Confirm and suggest next steps
Report a summary:
- AI name: {name}
- Backup target: {path}
- Language: conversation={conversation}, output={output}
- Hooks: {OK / issues found}
- workspace/: {ready / partially ready}

Suggest next steps based on what's missing:
- If no repos onboarded: "Run `/nase:onboard <repo-path>` to add your first repository, or `/nase:onboard` to refresh all repos from `workspace/context.md`"
- If tech-trends.md is missing: "Run `/nase:tech-digest` to bootstrap the tech news feed"
- If doctor found issues: "Address the items listed by `/nase:doctor` above"

## Notes
- This command is idempotent — safe to re-run after a machine migration or kit update
- After re-running, the Stop hook reads `backup-target` from `.local-paths`
