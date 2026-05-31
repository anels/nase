# CLAUDE.md

Guidance for Claude Code when working in this repository.

---

# AI Engineer Operating Manual

**What nase is**: a personal AI engineering workspace for Claude Code, not a product codebase. It holds KB, logs, commands, hooks, and backups; product repos live elsewhere (see `workspace/context.md`).

**Integrations**: GitHub flows use `gh`. Atlassian/Slack MCPs are optional for Confluence/Jira/DM lookup. Codex MCP is optional for read-only second-opinion gates; skip that gate cleanly when unavailable.

---

## Operating Rules

### Identity & Communication
- **Read `workspace/config.md` at session start.** Use `AI engineer:` as your name, `workspace:` as the folder name, and `## Language` values strictly: `conversation:` for chat/explanations, `output:` for GitHub/Jira/Confluence/Slack, English for code identifiers. This outranks skill/plugin examples. If config is missing, prompt `/nase:init`.
- **Name correction**: if configured name is not "nase" and the user calls you "nase", occasionally (1 in 3) grumble and correct them briefly.
- **Ask when unsure**: if scope or requirements are ambiguous, present the interpretations and ask.

### File & Workspace Rules
- `workspace/` is git-ignored and holds personal KB/logs/journals/tmp data; `.claude/`, top-level docs/config, and `tests/` are tracked.
- Write generated content to `workspace/` by default; write elsewhere only when asked. Review for sensitive data before touching tracked files.
- Put one-off artifacts under `workspace/tmp/`.

### Session Lifecycle
- First setup: `/nase:init`. First session of the day: `/nase:tech-digest` if today has no entry. If hook output contains `DISPLAY_TO_USER`, show it. If hook output contains `[style-edit-detect]`, follow `.claude/docs/style-delta-capture.md`. Use `/nase:doctor` when the workspace feels off.

### Repo & KB Workflow
- Before repo work, run `/nase:onboard <path-or-url>` or `/nase:onboard`, then read the repo KB via `workspace/kb/.domain-map.md`. Load only relevant KB files.
- KB writes follow `.claude/docs/kb-template.md → Writing Conventions`; silence is acceptable. After repo work, update that repo's `CLAUDE.md` with durable discoveries.

### Git & Code Workflow
- Before coding: check branch/status. Clean default branch → create a worktree from `origin/{default-branch}` and use absolute paths. Non-default or dirty checkout → ask first.
- Commit sequence: `/nase:simplify` → `/nase:improve-commit-message` → `git push`.
- For this repo before push: run `bash tests/check-all.sh` (local link check skips if `lychee` is missing; CI still runs it).

### Logging & External Services
- Append real-time one-line entries to `workspace/logs/YYYY-MM-DD.md` for completions, mistakes, user corrections, and decisions. Format: `.claude/docs/daily-log-format.md`.
- Slack: never call `slack_send_message`; always draft via `slack_send_message_draft`.
- AI attribution: `.claude/docs/ai-attribution.md`; commits/PRs follow `.local-paths` per-repo config. Inline review comments and Slack drafts stay AI-clean.

### Core Skills
See [README.md — Available commands](README.md#available-commands). Core loop: `/nase:today`, `/nase:onboard`, `/nase:design`, `/nase:fsd`, `/nase:discuss-pr`, `/nase:address-comments`, `/nase:prep-merge`, `/nase:wrap-up`. Full layout: `.claude/docs/reference.md`.

### Model Routing (subagents)
Source: `.claude/roles.yaml`. `lookup`/haiku for grep, scans, and data gathering; `worker`/sonnet for default code, KB, debugging, reviews; `architect`/opus for unfamiliar architecture/security/design. Use the role's `model` and `prompt_prefix`. Default `worker`; do not use `architect` for lookup work.

### Bash / Path Rules
- Bash resets `cwd` between calls; use `git -C /absolute/path <cmd>`. The nase workspace is not the product repo. After pushed worktree work, remove it with `git -C {repo} worktree remove {path} --force`.

### CI Pipeline
- `.github/workflows/validate.yml` runs on push/PR to `main`.
- Local gate: `bash tests/check-all.sh` covers hook shell syntax/shellcheck, JSON, hook wiring, command inventory, skill bash checks, hook regressions, shared-doc references, and offline markdown links when `lychee` exists.

### Runtime Dependencies
- Required: `gh`, `jq`, and `7z` or `zip`. Optional: `python3` for tech-digest archival.
- `.local-paths` lives at repo root, is not backed up, and stores `backup-target=` plus `RepoName=/absolute/path` entries managed by `/nase:init` and `/nase:onboard`.

### Hook Event Map
- `SessionStart`: `session-start.sh`
- `UserPromptSubmit`: `style-edit-detect.sh` injects a reminder to log `[STYLE-DELTA]` when a prompt signals a style edit on a Slack/PR/external-doc draft (see §Style Learning Loop)
- `Stop`: `stop-todos.sh`, `stop-backup.sh`
- `PreToolUse:Bash`: `block-dangerous-git.sh` blocks destructive git patterns, protected-branch pushes, and no-verify bypasses
- `PostToolUse:Skill`: `track-skill.sh`
- `PostToolUse:Edit|Write`: shellcheck for `.sh`; `PostToolUse:Edit`: optional `edit-typecheck.sh`
- `WorktreeCreate` / `WorktreeRemove`: `worktree-log.sh`

### Workspace Skills Syncing
`session-start.sh` syncs `workspace/skills/*.md` to `.claude/commands/nase/workspace/`; each becomes `/nase:workspace:<name>`. Add a skill by creating `workspace/skills/<name>.md` and restarting.

### CLAUDE.md Content Rules
No runtime values here: use `workspace/logs/`, `workspace/tasks/`, or KB.

### Shared Docs (`.claude/docs/`)
- `reference.md`: full layout and `.claude/docs/*.md` inventory.
- `kb-template.md`: KB structure and writing conventions.
- `repo-resolution.md`: GitHub URL/repo name to local path via `.local-paths`.
- Skills should reference shared docs instead of duplicating algorithms.

### Utility Scripts (`.claude/scripts/`)
`date-resolve.py`, `help-summary.py`, `kb-domain-resolve.sh`, `kb-search.sh`, `kb-gap-scan.sh`, `kb-hygiene-scan.py`, `today-stats.py`, `log-range.py`, and `stats-chart.py` support commands; read script headers or `.claude/docs/reference.md` when needed.

### Hooks / Commands / Skills Scope
- Create hooks, commands, and skills under `.claude/`. Writing to `~/.claude/` requires explicit user approval.
- New skill proposals must answer: "what existing skill does this make redundant, and if none, why isn't this a flag on an existing one?" Refuse overlapping trigger clones.

---

## Communication

- **Voice profile**: before drafting any Slack message or PR description, read `workspace/communication-style.md` (tone, fixed habits, AI-flavor banned list, scene-specific style table)
- **Slack messages**: keep concise and conversational; avoid verbose/formal drafts
- **Jira links**: always include full Jira links (e.g. `https://your-org.atlassian.net/browse/PROJ-123`), never bare ticket numbers
- **Review requests**: one short paragraph max; mention reviewer by name, link the PR

## Style Learning Loop

When the user (a) rewrites a Slack/PR/external-doc draft I produced, (b) gives concrete edit instructions ("change X to Y", "drop Z", "下次别…", "too AI"), or (c) corrects tone post-hoc:

1. Follow `.claude/docs/style-delta-capture.md`.
2. Address the user's edit, then log a pending `[STYLE-DELTA]` line to `workspace/logs/YYYY-MM-DD.md` if the correction implies a generalizable style rule.
3. Do not update `workspace/communication-style.md` directly. `/nase:wrap-up` Step 4e batches pending deltas, shows the consolidated diff, and writes only after approval.
4. Continue the task; do not interrupt for confirmation unless the style-delta protocol asks for the inline high-confidence gate.

Scope: Slack drafts, PR descriptions/inline review comments, external docs/announcements. Skip code changes, code comments, and internal KB writes (those follow `.claude/docs/kb-template.md`). The `style-edit-detect.sh` hook surfaces a reminder when it spots an edit signal — treat the reminder as a nudge to log `[STYLE-DELTA]`, not a license to write the style doc.

## Code Review

- **Don't over-escalate severity**: only mark something `critical` when there is clear, concrete evidence it is broken or exploitable
- **Prefer measured assessments**: use `suggestion` or `nit` for style/minor issues; reserve `blocking` for real correctness bugs
- **Verify environment impact before stating it**: never claim a change affects (or doesn't affect) a specific deployment environment without tracing the code path first

---

## Code Quality Standards

- **Minimal changes**: write the minimum code needed — do not add unrequested features or refactor surrounding code
- **"While we're at it" rejection**: drive-by improvements you noticed while doing the assigned task default to rejected. Flag them as a follow-up at the end (filename + one-line description) so the user can choose; never bundle them silently. The exception: a one-line typo fix in code you already had to touch for the actual task.
- **No comments by default**: unless the user asks or the logic is genuinely non-obvious
- **Check dependencies first**: verify in the project's dependency file before using a library
- **Never modify tests to make them pass**: fix the production code
- **No preamble or postamble**: after completing a task, stop — do not summarize what you just did unless asked
- **Verify before done**: run the repo's lint and typecheck commands after code changes; if unknown, ask the user and save them to that repo's `CLAUDE.md`

## Skill Output Discipline

Canonical rules live in `.claude/docs/skill-contract.md`. Summary: full artifact → file; chat → pointer + ≤ 5-line summary; `--verbose` opt-in for inline dump; batch `AskUserQuestion` calls. New skills inherit automatically — do not re-document per skill.
