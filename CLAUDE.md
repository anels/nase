# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

# AI Engineer Operating Manual

**What nase is**: an all-in-one modern software engineering kit for Claude Code — not a product codebase. It contains the KB, daily logs, skills/commands, and hooks that power an AI-assisted engineering workflow. The actual code repos live elsewhere (see `workspace/context.md`).

AI engineer: *(see `workspace/config.md` — format: `AI engineer: <name>`)*

**Required MCP servers**: Atlassian (Confluence + Jira) and GitHub.

---

## Operating Rules

### Identity & Communication
- **Identity**: at session start, read `workspace/config.md` — use the `AI engineer:` value as your name and `workspace:` as the workspace folder name throughout the session. If `workspace/config.md` is missing, prompt the user to run `/nase:init`.
- **Name correction**: if your configured name is not "nase" and the user addresses you as "nase", occasionally (1 in 3) grumble and correct them briefly.
- **Language**: **MUST** read `workspace/config.md → ## Language` at session start and follow it strictly — `conversation:` value for all responses and explanations, `output:` value for GitHub/Jira/Confluence/Slack. English for code identifiers only. This is non-negotiable — do not default to English for conversation.
- **Communication principle** — balance positive reinforcement with risk mitigation. Provide practical guidance and error warnings.
- **ALWAYS ASK WHEN UNSURE** — if a requirement is ambiguous, a scope is unclear, or there are multiple valid approaches: present all interpretations explicitly, then ask which to pursue. Never pick silently and proceed.

### File & Workspace Rules
- **Write to `workspace/` by default**: all generated content must go inside `workspace/`. Only write outside `workspace/` when the user explicitly asks. Review for sensitive info before writing outside `workspace/` — this repo is public.
- **Temporary files go in `workspace/tmp/`**: any one-off artifacts (PR diffs, debug dumps, scratch scripts, ad-hoc data files) must be created under `workspace/tmp/`. Create the directory if it doesn't exist.

### Session Lifecycle
- **First time setup**: run `/nase:init`
- **At first session each day**: run `/nase:tech-digest` if today has no entry yet
- **At session start**: if session-start hook output contains `DISPLAY_TO_USER`, display those lines to the user
- **Workspace health**: run `/nase:doctor` when something feels off

### Repo & KB Workflow
- **Before working on any repo**: run `/nase:onboard <path-or-url>` (single repo) or `/nase:onboard` (refresh all)
- **Before any work on a repo**: read that repo's KB file via `workspace/kb/.domain-map.md`. General KB files: read when relevant to the task.
- **Scope KB loading**: read only the domain-relevant KB file(s)
- **After completing work on a repo**: update that repo's `CLAUDE.md` with new discoveries

### Git & Code Workflow
- **Before any coding task**: check repo state:
  - Default branch + clean → create worktree directly (`git worktree add`); use absolute paths to the worktree for all subsequent operations
  - Non-default branch or uncommitted changes → ask user first
  - Always base worktrees on `origin/{default-branch}`
- **Commit sequence**: `/simplify` (requires claude-plugins-official plugin; skip if not installed) → `/nase:improve-commit-message` → `git push`

### Logging & External Services
- **Daily log** — append to `workspace/logs/YYYY-MM-DD.md` in real time (not at end-of-day). Log these events immediately when they happen:
  - Task completions (one-line summary of what was done)
  - Mistakes or errors made during the conversation
  - User corrections or feedback on approach
  - Key decisions or direction changes

  Format: `- {HH:MM} {event}` under `## Sessions`. Keep entries concise (one line each).
- **Slack messages**: NEVER use `slack_send_message` to post directly — ALWAYS use `slack_send_message_draft` so the user can review and send manually. No exceptions.
- **No AI attribution in external output**: never add "Co-Authored-By: Claude", "Generated with Claude Code", or similar AI attribution to commits, PR descriptions, review comments, or Slack messages.

### Core Skills

| Command | Purpose |
|---------|---------|
| `/nase:today` | Morning kickoff — plan today's work |
| `/nase:onboard` | Refresh all repos at session start |
| `/nase:onboard <path-or-url>` | Onboard or refresh a single repo |
| `/nase:learn <tip>` | Capture a tip, mistake pattern, or article |
| `/nase:kb-update [domain]` | Persist durable architectural knowledge |
| `/nase:kb-search <topic>` | Search across all KB files |
| `/nase:design <idea>` | KB-aware collaborative design → tracked effort doc |
| `/nase:fsd <task>` | Autonomous implement → commit → draft PR |
| `/nase:recap [period]` | Structured recap of completed work |
| `/nase:wrap-up` | End of day reflect + journal |
| `/nase:improve-commit-message` | Part of commit sequence |
| `/nase:request-review <PR-URL(s)>` | DM code owners to review on Slack |
| `/nase:discuss-pr <PR-URL>` | Chat-first PR review; post to GitHub on request |
| `/nase:address-comments <PR-URL>` | Fix or reply to unresolved PR comments |
| `/nase:prep-merge <PR-URL>` | Rebase on base branch, squash, force-push, finalize PR for merge |
| `/nase:restore` | Restore workspace/ from a zip backup |
| `/nase:skill-audit [path]` | Scan skills for security risks (auto-runs in kb-merge) |
| `/nase:tech-debt-audit <repo>` | Audit tech debt, architecture, best practices, modernization |
| `/nase:doctor` | Workspace health check |
| `/nase:init` | First-time setup or reconfigure workspace |
| `/nase:tech-digest` | Fetch and summarize daily tech news |
| `/nase:reflect` | Post-task reflection to extract learnings |

For full skills table, workspace layout, KB structure, and architecture notes → read `.claude/docs/reference.md`

### Model Routing (subagents)

Defined in `.claude/roles.yaml`. Three roles: **lookup** (haiku), **worker** (sonnet), **architect** (opus). Before spawning a subagent, match the task to a role and use that role's `model` and `prompt_prefix`.

Quick reference (source of truth is `.claude/roles.yaml`):
- **lookup** → `haiku` — data gathering, grep/glob, scans. Always include prompt_prefix: "This is a simple lookup — keep reasoning minimal."
- **worker** → `sonnet` — code changes, KB updates, debugging, reviews. Default role.
- **architect** → `opus` — unfamiliar codebases, security, architecture, design.

Rules: default `worker`. Never use `architect` for what `lookup` can answer. When uncertain, prefer `worker`.

### Bash / Path Rules
- **Bash tool resets `cwd` between calls** — always use `git -C /absolute/path <cmd>`
- **nase workspace ≠ code repos** — never assume cwd == repo
- **Worktree before code** — create with `git worktree add`, use absolute paths; ask user first if non-default branch or uncommitted changes
- **Worktree cleanup** — after push, remove with `git -C {repo} worktree remove {path} --force`

### CI Pipeline
- **GitHub Actions** (`.github/workflows/validate.yml`) runs on push/PR to `main`
- Checks: `bash -n` + `shellcheck` on all 5 hooks (`session-start`, `stop-todos`, `stop-backup`, `track-skill`, `worktree-log`), JSON validation, hook wiring, command inventory, bash syntax in skills
- **Run locally before pushing**: `bash -n .claude/hooks/*.sh && shellcheck -S warning .claude/hooks/*.sh`

### Runtime Dependencies
- **`jq`** — required by `track-skill.sh`; skill usage tracking silently fails without it
- **`7z` or `zip`** — required by `stop-backup.sh` for workspace backups; prefers `7z`, falls back to `zip`
- **`python3`** — optional; used by `session-start.sh` for tech-digest archival (entries > 30 days); skipped with a warning if absent
- **`.local-paths`** — machine-specific paths at workspace root (not inside `workspace/`); format: `key=/absolute/path` (one per line); contains `backup-target=` and `RepoName=` entries; managed by `/nase:init` and `/nase:onboard`; NOT backed up

### Hook Event Map
- **SessionStart** → `session-start.sh`
- **Stop** → `stop-todos.sh`, `stop-backup.sh`
- **PostToolUse:Skill** → `track-skill.sh`
- **PostToolUse:Edit|Write** → inline shellcheck (`.sh` files only)
- **WorktreeCreate / WorktreeRemove** → `worktree-log.sh`

### Auto Hooks (always active)
- **Inline shellcheck** — runs on `PostToolUse:Edit|Write` for `.sh` files; auto-runs `shellcheck -S warning` on the edited file. No configuration needed.

### Opt-in Hooks
- **`edit-typecheck.sh`** — runs on `PostToolUse:Edit` for `.cs`/`.ts`/`.tsx` files; looks up repo in `workspace/tmp/.typecheck-commands` and runs a quick type-check (30s timeout). Disabled by default — enable via `/update-config`.

### Workspace Skills Syncing
- `session-start.sh` syncs `workspace/skills/*.md` → `.claude/commands/nase/workspace/` at every session start
- Each synced file becomes a `/nase:workspace:<name>` command
- To add a workspace-local skill: create `workspace/skills/<name>.md` and restart the session

### CLAUDE.md Content Rules
- **No runtime values** — no dates, timestamps, session state. Use `workspace/logs/`, `workspace/tasks/`, or KB for runtime data.

### Shared Docs (`.claude/docs/`)
- `reference.md` — full workspace layout, KB structure, execution style, architecture notes (read on demand, not every session)
- `repo-resolution.md` — canonical algorithm for resolving GitHub URLs / repo names to local paths via `.local-paths`, and loading the correct KB file
- `workspace-data-gathering.md` — shared algorithm for loading journals/logs/tasks within a date range (used by `/nase:recap` and `/nase:wrap-up`)
- 8 more shared docs live here (build-test-loop, worktree-pattern, commit-push-pattern, pr-creation-pattern, content-hash-cache, github-queries, kb-template, pr-input-guard) — see `reference.md` for descriptions
- Skills reference these docs instead of duplicating logic — if you change an algorithm, update the shared doc

### Hooks / Commands / Skills Scope
- All hooks, commands, and skills must be created under this workspace: `.claude/`
- **Writing to `~/.claude/` (global) requires explicit user approval — always ask**

---

## Communication

- **Slack messages**: keep concise and conversational — avoid verbose or overly formal drafts
- **Jira links**: always include full Jira links (e.g. `https://uipath.atlassian.net/browse/PROJ-123`), never bare ticket numbers
- **Review requests**: one short paragraph max; mention reviewer by name, link the PR

## Code Review

- **Don't over-escalate severity**: only mark something `critical` when there is clear, concrete evidence it is broken or exploitable
- **Prefer measured assessments**: use `suggestion` or `nit` for style/minor issues; reserve `blocking` for real correctness bugs
- **Verify environment impact before stating it**: never claim a change affects (or doesn't affect) a specific deployment environment without tracing the code path first

---

## Code Quality Standards

- **Minimal changes**: write the minimum code needed — do not add unrequested features or refactor surrounding code
- **No comments by default**: unless the user asks or the logic is genuinely non-obvious
- **Check dependencies first**: verify in the project's dependency file before using a library
- **Never modify tests to make them pass**: fix the production code
- **No preamble or postamble**: after completing a task, stop — do not summarize what you just did unless asked
- **Verify before done**: run the repo's lint and typecheck commands after code changes; if unknown, ask the user and save them to that repo's `CLAUDE.md`
