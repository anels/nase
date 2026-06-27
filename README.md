# nase — A personal AI engineering workspace for Claude Code
```

 ████████    ██████    █████   ██████
▒▒███▒▒███  ▒▒▒▒▒███  ███▒▒   ███▒▒███
 ▒███ ▒███   ███████ ▒▒█████ ▒███████
 ▒███ ▒███  ███▒▒███  ▒▒▒▒███▒███▒▒▒
 ████ █████▒▒████████ ██████ ▒▒██████
▒▒▒▒ ▒▒▒▒▒  ▒▒▒▒▒▒▒▒ ▒▒▒▒▒▒   ▒▒▒▒▒▒

```

A [Claude Code](https://claude.ai/code) workspace for AI-assisted engineering across multiple repos: repo memory, workflow commands, lifecycle hooks, daily logs, and backups.

> **Name origin**:
> **nase** can mean ***N***ot ***A*** ***S***oftware ***E***ngineer, ***N***ot ***A***I ***S***oftware ***E***ngineer, or the recursive ***N***ase is an ***A***ssistant for ***S***oftware ***E***ngineer. It also sounds like 那谁 (*nà shuí*) in Chinese — "hey, whatsyourname".

---

## Quick start

```bash
git clone https://github.com/anels/nase.git my-workspace
cd my-workspace
claude                        # open Claude Code in this directory
```

Then inside Claude Code:

```
/nase:init                    # set AI name, configure backup & language, create workspace/
/nase:onboard /path/to/repo   # onboard a repo (local path or GitHub URL)
/nase:onboard                 # refresh ALL already-onboarded repos from workspace/context.md
/nase:today                   # morning kickoff — what to focus on today
```

Run `/nase:help` anytime for the full command overview.

Optionally, add a shell alias to launch nase from anywhere:

<details>
<summary>bash / zsh (~/.bashrc or ~/.zshrc)</summary>

```bash
# Claude Code — nase workspace (adjust path to your clone location)
nase() { cd ~/my-workspace && claude "$@"; }
```

</details>

<details>
<summary>PowerShell ($PROFILE)</summary>

```powershell
# Claude Code — nase workspace (adjust path to your clone location)
function Invoke-NaseClaude { Set-Location "$HOME\my-workspace"; claude @args }
Set-Alias -Name nase -Value Invoke-NaseClaude
```

</details>

Then run `nase` from any terminal to open Claude Code in the workspace.

> **Tip**: `--dangerously-skip-permissions` auto-approves tool calls but removes Claude Code's confirmation layer. Keep it off unless you trust the local hooks and tests.

### Prerequisites

- **[Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)** — required
- **Git** — required for hooks and report commands
- **[GitHub CLI (`gh`)](https://cli.github.com/)** — required for PR metadata, diffs, reviews, and PR creation workflows
- **7z or zip + unzip** — required for backups and restore; install via `scoop install 7zip` or `brew install p7zip`
- **jq** — required by hooks that parse Claude Code tool-call JSON (`block-dangerous-git.sh`, external-write guards, `track-skill.sh`)
- **python3** — required by date-range helpers used in recap/stats/KB-gap flows; also used for tech-digest archival of entries older than 30 days

#### Recommended agent CLI tools

These are optional. nase still runs without them; `/nase:doctor` reports missing
tools as warnings so skills can fall back cleanly.

Baseline macOS install:

```bash
brew install ripgrep fd yq shellcheck shfmt
```

Useful daily add-ons:

```bash
brew install ast-grep gitleaks difftastic duckdb ccusage
```

Generate task-specific availability and Homebrew install commands:

```bash
python3 .claude/scripts/tool-availability.py --all --format table
python3 .claude/scripts/tool-availability.py --all --missing --install brew
```

Narrow tools such as `actionlint`, `semgrep`, `trivy`, `lychee`, `hadolint`,
`rga`, `qsv`, `http`, `grpcurl`, `markitdown`, `pandoc`, `poppler`, `qpdf`,
`magick`, and `hyperfine` are detectable by `/nase:doctor --deep`; install them
only when a workflow needs that evidence. Python-package tools such as
`markitdown` may show a non-Homebrew install hint in the availability table;
`--install brew` only prints Homebrew-installable formulas. Selection rules live
in `.claude/docs/cli-tooling.md`.

#### MCP servers

| MCP | Used for | Setup |
|-----|----------|-------|
| **Atlassian** (Confluence + Jira) | `/nase:onboard` reads Confluence docs; Jira ticket lookup in reports | [Atlassian MCP](https://github.com/atlassian/mcp-atlassian) |
| **Slack** | `/nase:request-review` — resolves GitHub handles to Slack users and stages DM drafts; direct sends are blocked by a hook | [Slack MCP](https://github.com/modelcontextprotocol/servers/tree/main/src/slack) |
| **Codex** | Optional read-only second-opinion gates; skipped cleanly when unavailable | `claude mcp add codex --scope user -- /Applications/Codex.app/Contents/Resources/codex mcp-server` |

Configure MCP servers in your Claude Code `settings.json` (or `settings.local.json`) under `mcpServers`. GitHub workflows use `gh` CLI by default.

---

## What nase is

A personal AI engineering workbench for Claude Code. It is organized like a
small kernel around Claude Code: Markdown commands define workflows, lifecycle
hooks gate risky tool calls, scripts provide deterministic checks, and
`workspace/` holds human-readable state.

- **Human-readable memory** — `workspace/kb/projects/<repo>.md` plus shared `workspace/kb/general/`; `/nase:onboard` populates them and tasks load only relevant files instead of dumping the whole repo into context.
- **30+ Markdown commands** — daily kickoff, onboarding, design, implementation, PR review, KB hygiene, wrap-up. See [Available commands](#available-commands).
- **Lifecycle hooks** — block destructive git and guard high-risk external writes, back up `workspace/`, log `/nase:*` usage, and run validation helpers. See [Hooks at a glance](#hooks-at-a-glance).
- **Evidence loops** — PR/review/audit commands require repo evidence, focused tests, explicit AI-provenance checks where relevant, and optional read-only Codex checks when configured.
- **Offline PR evals** — `evals/pr-review/` contains deterministic output-shape checks for high-frequency PR/review and audit workflows.

`workspace/` content persists locally and is auto-backed-up. The kit (`.claude/`, `CLAUDE.md`, `README.md`, `docs/`) lives in git; your content stays local.

Architecture details live in [`docs/architecture.md`](docs/architecture.md).

Run the PR/review eval schema check locally:

```bash
python3 .claude/scripts/pr-review-eval.py validate evals/pr-review/evals.json
```

### Design principles

- **Deterministic guardrails beat prompt promises.** Prompt rules describe intent; hooks and tests enforce the dangerous edges: protected-branch pushes, destructive git, direct Slack sends, Jira mutations, oversized Confluence writes, shell-script regressions, and warn-only workspace quality drift.
- **Context is sliced, not dumped.** Commands read repo KB, domain maps, GitHub metadata, focused diffs, and script-filtered logs before pulling more files into context.
- **Knowledge stays reviewable.** Durable memory is plain Markdown under `workspace/kb/`, `workspace/tasks/`, `workspace/skills/`, and `workspace/journals/`; humans can inspect, edit, delete, and share it.
- **Review claims need evidence.** PR and audit workflows should back findings with source paths, diffs, tests, logs, or `gh`/`rg`/`ast-grep` output, then drop candidates that cannot be verified.
- **External writes stay human-triggered.** Slack uses drafts, Jira writes require a short-lived token after approval, Confluence writes are ADF/size-guarded, and GitHub review posting happens only after explicit instruction.
- **Skills are files.** New workflow behavior should live as a command, shared doc, script, hook, or eval case, not as hidden state in one conversation.

---

## Use cases

### Your daily workflow

- `/nase:today` syncs PR/Jira status and plans focus; `/nase:wrap-up` captures learnings.
- `/nase:reflect` extracts fresh task lessons; wrap-up rolls them into KB updates and reusable skills.
- Hooks create daily logs and append commit summaries; `/nase:recap` turns them into reports.

```
/nase:today                    # morning: sync statuses, surface priorities, plan focus
/nase:onboard                  # refresh repo context for the day
  focused work                  # implement, review PRs, debug — whatever's on the list
/nase:reflect                  # after completing a task: extract learnings while fresh
  ... more work ...
/nase:wrap-up                  # evening: reflect → learn → extract-skills → kb-update → journal
```

### Implement a feature or fix

- `/nase:design` handles complex tasks: KB + external-doc research, 2–3 approaches, tradeoffs, a tracked junior-implementable effort doc. By default it runs an end-to-end auto pass (research → multi-persona grill → review) and asks any genuine human-input questions in one batch at the end; use `--interactive` to steer it turn by turn. Skip it for simple fixes.
- `/nase:fsd` handles code → test → fix → commit → push → draft PR. For large features use **Direct with Phase isolation**; for hard TDD use **Yes** at the TDD prompt.
- Optional Codex second-opinion gates run where configured and skip their Codex call cleanly otherwise; `/nase:fsd` and `/nase:address-comments` still run their local read-only verifier fallback for pre-push and review-thread safety.
- Reviewer discovery uses KB → git history → CODEOWNERS, then stages Slack DM drafts.
- Review feedback is handled interactively: obvious fixes applied, ambiguous comments discussed one by one.

```
/nase:onboard <repo>          # load repo context into KB
/nase:design <task>            # (complex tasks) default auto pass → junior-implementable effort doc
  answer end-of-run questions     # auto asks only what evidence couldn't resolve, batched at the end
  /nase:design --interactive <task>  # (optional) steer the design turn by turn instead
  /nase:design --grill <slug>    # (optional) multi-persona stress-test of the plan
/nase:fsd <task>               # implement → test → commit → push → draft PR
/nase:request-review <PR-URL>  # find right reviewers, stage Slack DM drafts
  ⏳ wait for feedback
/nase:address-comments <PR-URL> # deep-dive each unresolved comment → fix/reply → push → resolve threads
  ⏳ iterate until approved
/nase:prep-merge <PR-URL>      # rebase, squash, clean up, un-draft
  merge ✓
```

### Review someone else's PR

- Loads repo KB, Confluence context, and git history before drafting comments.
- Runs architecture, bugs, security, testability, and DRY/KISS passes, then synthesizes findings.
- Confirmed findings can be captured into KB. Inline comments are drafts until you ask to post.

```
/nase:onboard <repo>           # ensure KB is fresh for this repo
/nase:discuss-pr <PR-URL>      # deep analysis — architecture, bugs, security, patterns
                               #   produces inline comment drafts in chat
  review and edit drafts         # discuss findings, adjust comments
  post to GitHub when ready      # nase posts only on your explicit instruction
```

### Build and share knowledge

- Capture lessons, articles, and patterns into durable KB files.
- `/nase:extract-skills` turns repeated workflows into workspace-local commands.
- `/nase:kb-review` deduplicates, cross-references, and prunes stale entries.
- `/nase:kb-teamshare` exports sanitized KB + skills; teammates import with `/nase:kb-merge`.

```
/nase:learn <url-or-tip>       # capture an article, technique, or lesson
/nase:kb-update                # persist session learnings into KB
/nase:extract-skills           # analyze session → extract reusable patterns as workspace skills
/nase:kb-review                # periodically: deduplicate, cross-reference, clean up stale entries
/nase:kb-teamshare             # export sanitized KB + skills for teammates
/nase:kb-merge <path>          # import a teammate's shared KB into your workspace
```

### Track progress and report

- `/nase:recap` generates weekly/monthly summaries from logs, commits, and task completions.
- `/nase:estimate-eta` gives calibrated estimates from KB + history.
- `/nase:stats` shows skill/workspace activity from hook-collected data.

---

## Available commands

<!-- This section is generated from `.claude/commands/nase/*.md` frontmatter. -->
<!-- Run: `python3 .claude/scripts/command_catalog.py --root . --format readme` -->

### Setup & health

| Command | Purpose |
|---------|---------|
| `/nase:doctor` | Run a self-diagnostic check to verify the workspace is properly configured and healthy. Use when something feels off — hooks not firing, backup warnings, after a migration, or proactively before a new sprint. Triggers: 'doctor', 'check workspace', 'diagnose nase', 'verify config', 'health check', 'workspace doctor', 'is nase healthy'. |
| `/nase:help` | Display a usage guide for this AI engineer workspace. Use when asked "what commands are available?", "how does nase work?", "help", "show commands", "what can you do?", "what skills do you have?", or for an overview of skills and hooks. |
| `/nase:init` | Initialize or reconfigure the nase workspace. Use for first-time setup, after cloning on a new machine, or when workspace/config.md is missing. Safe to re-run — idempotent. Triggers: 'init nase', 'setup workspace', 'configure nase', 'first-time setup', 'reconfigure workspace', 'bootstrap nase'. |

### Knowledge base

| Command | Purpose |
|---------|---------|
| `/nase:kb-gap-detect` | Scan daily logs and lessons for missing KB topics, cluster gaps, and propose additions. Use for knowledge gap, find KB holes, or what should I document. Read-only by default; complements /nase:kb-review, which finds stale or duplicate entries. |
| `/nase:kb-merge` | Import and merge a teammate's shared knowledge base into your own workspace KB — intelligently merges overlapping files, shows a diff preview before writing, and updates the domain map. Use when asked "import KB", "merge KB", "import knowledge base", "merge shared KB", or after receiving a KB export from /nase:kb-teamshare. |
| `/nase:kb-review` | Review, organize, consolidate KB files — dedup, cross-ref, surface stale content, promote lessons. Use weekly/monthly as KB hygiene, when KB feels messy, or after several /nase:learn entries. Triggers: 'review KB', 'organize notes', 'clean up KB', 'what's in my KB'. |
| `/nase:kb-search` | Search all KB files for a topic, keyword, or pattern. Use to find documented context, verify whether something is already in the KB, or discover related entries. Triggers: search KB, find in KB, or is X in the KB. Read-only; use /nase:kb-update or /nase:learn to add entries. |
| `/nase:kb-teamshare` | Export KB files or learned workspace skills for teammates with sanitization and portable links. Use for share my KB, export KB, export knowledge base, share skills, or packaging content for /nase:kb-merge. |
| `/nase:kb-update` | Persist durable repo-specific knowledge — architecture, constraints, API contracts, naming conventions tied to one codebase. Example: 'the Insights repo requires OrderBy before Skip in EF queries' → /kb-update. For general or cross-project patterns, use /nase:learn instead. Triggers: 'update KB', 'add to knowledge base', 'document this pattern'. |
| `/nase:onboard` | Onboard or refresh project repos in the workspace knowledge base. Without arguments, refreshes ALL already-onboarded repos from workspace/context.md. With a repo path or GitHub URL, onboards or refreshes that single repo. Run before EVERY work session. Use when starting work on any repo, or when asked to "onboard", "refresh KB", "refresh all repos", "add repo", or "update knowledge base". |
| `/nase:tech-digest` | Fetch and summarize latest tech news from configured sources, filtered to workspace topics, with source links, caching, actionable adoption notes, and concrete follow-up actions when useful. Supports --force, --dry-run, --since, --section, and --sources. Triggers: 'tech news', 'tech digest', 'what's new', 'morning digest', 'tech roundup', 'latest in AI', 'today's news'. |

### Learning & reflection

| Command | Purpose |
|---------|---------|
| `/nase:extract-skills` | Analyze the current session and extract reusable problem-solving patterns as new nase skills. Run at the end of any session where you solved a non-trivial problem or found a useful technique. Also triggers on "extract pattern", "save technique", "capture workflow". |
| `/nase:learn` | Deep-dive a tip, URL, repo, or cross-project pattern into structured KB knowledge. Use for remember this, save this tip, learn from this, deep dive on X, article URL, or general programming insights. For one-repo constraints, API contracts, or naming rules, use /nase:kb-update. |
| `/nase:reflect` | Run a structured post-task reflection to extract learnings and improve future performance. Use after completing a feature, fixing a bug, or finishing a debugging session — especially when something surprised you or went wrong. Also triggers on "reflect on this", "what went well", or "post-mortem". |
| `/nase:today` | Plan today's work — quick morning kickoff focused on what to do today, with proactive Need Attention items and optional concrete next actions from KB, logs, tasks, Jira, and Slack. Use at the start of each work session, or when asked "what should I work on?", "morning kickoff", "morning standup", "daily plan", "what's my plan for today?", "start of day", or "daily kickoff". |
| `/nase:wrap-up` | Run at end of day to capture reflection, lessons, KB updates, and a journal entry in one pass. Use when the user says "wrap up", "end of day", "EOD", "done for today", "closing out", or wants to summarize today's work. |

### Design & implementation

| Command | Purpose |
|---------|---------|
| `/nase:design` | KB-aware design — researches context (codebase, KB, official docs, dependency source, forums), explores 2-3 approaches with tradeoffs, writes a tracked, junior-implementable effort doc with a built-in ETA estimate. Design only, no code (use /nase:fsd to implement). Defaults to an end-to-end auto pass that asks any genuine human-input questions at the end. Supports `--interactive` (turn-by-turn flow), `--grill` (multi-persona stress-test), `--review` (re-evaluate), `--auto` (explicit auto pass). Triggers: 'design', 'brainstorm', 'plan feature', 'kickoff', 'I want to build', 'grill plan', 'auto design'. |
| `/nase:fsd` | End-to-end task workflow from plan to merged-ready draft PR; writes and pushes code after upfront options are confirmed. Use for fsd, full self-develop, just do it, run it autonomously, fire and forget, or feature/fix handoff. For design-only planning, use /nase:design. |

### Git workflow

| Command | Purpose |
|---------|---------|
| `/nase:address-comments` | Act on unresolved PR review comments with per-thread dossiers, code fixes or replies, push when code changed, and resolve approved threads. Use for address comments, fix review comments, handle PR feedback, resolve comments, or respond to reviewer. For first-pass read-only review, use /nase:discuss-pr. |
| `/nase:discuss-pr` | Read-only PR analysis that finds the product/repo problem, then checks logic, design, simpler options, security, and testability before drafting comments. Use for analyze PR, self-review, prepare review comments, review PR #N, or PR URL + review without posting. Use /nase:address-comments for existing feedback. |
| `/nase:improve-commit-message` | Analyze the last commit and rewrite its message following conventional commits / commitlint rules. Always invoke before git push — part of the standard commit sequence. Use when asked to "improve commit", "fix commit message", "amend commit", "clean up commit", "before push", or after committing code. Also invoked automatically by /nase:fsd and /nase:prep-merge. |
| `/nase:prep-merge` | Prepare a PR for merge — verify all comments resolved, squash commits, force-push, and update PR title/description. Use when given a PR URL and asked to prepare, clean up, squash, finalize, or get a PR merge-ready. Also triggers on "prep merge", "squash and push", "clean up PR", "ready to merge", "finalize PR", or any request to tidy a PR's commit history before merging. |
| `/nase:request-review` | Find PR reviewers and stage Slack DM drafts. Use with one or more PR URLs when asked to notify reviewers, request approval, or ping code owners. Reads CODEOWNERS and KB context, groups cherry-pick PRs per reviewer, and confirms before staging messages. |
| `/nase:simplify` | Simplify recently-modified code and remove AI-shaped slop while preserving behavior. Part of the standard commit sequence before /nase:improve-commit-message. Use when asked to "simplify", "clean up code", "refactor for clarity", "tidy up", "deslop", "anti-slop", or before any commit. Also invoked by /nase:fsd Phase 6. |

### Reporting

| Command | Purpose |
|---------|---------|
| `/nase:efforts` | Report all active efforts by lifecycle stage and status, flag PR/Jira drift, and count active vs done. Use for list my efforts, effort status, stalled work, or what am I working on. Read-only; use /nase:today to move completed efforts and /nase:stats for activity counts. |
| `/nase:estimate-eta` | Estimate the effort and ETA for a given task or feature request. Use whenever someone asks "how long will this take?", "when can we ship X?", "estimate this", or before committing to a timeline. |
| `/nase:kb-usage` | Read-only KB observability report: shows which skills used which KB files, top files/skills, access-source breakdown, and mapped KB files with no recent usage. Supports --window N\|all, --top N, and --verbose. |
| `/nase:recap` | Generate a structured recap of completed work plus actionable improvement suggestions. Use when asked to "recap", "review my work", "review progress", "summarize", "what did I do", or "show my progress" for a week or month. Prompts for period if not specified. Always ends with concrete next-period suggestions. |
| `/nase:skill-usage` | Report /nase:* skill usage from workspace/stats/skill-usage.jsonl with total, 30/7-day windows, last-used date, and deprecation candidates. Use for which skills do I use, skill stats, or deprecate skills. Read-only; writes a stats report. |
| `/nase:stats` | Display workspace usage statistics inline (no report file) — vertical column chart (per-day ≤14d, per-week >14d), tiered skill usage, and summary counters. For a structured narrative recap of completed work, use /nase:recap instead. Use when asked "show stats", "how active am I", "productivity", "how much have I done", or to review activity patterns over 7/30/all-time windows. |

### Security & maintenance

| Command | Purpose |
|---------|---------|
| `/nase:skill-audit` | Scan skill files for security risks — command injection, data exfiltration, prompt injection, unsafe file ops, supply chain threats, and credential exposure. Use before importing external skills, after /nase:kb-merge, or periodically as security hygiene. Triggers on: 'audit skills', 'scan skills', 'skill security', 'check skills for safety', or when importing untrusted skill files. |
| `/nase:tech-debt-audit` | Audit a repo for tech debt, architecture health, best-practice gaps, modernization options, and AI verification debt. Use during onboarding, before planning, or for what tech debt do we have, architecture review, best practices, AI verification debt, or modernization. |

### Backup & restore

| Command | Purpose |
|---------|---------|
| `/nase:restore` | Restore workspace/ from a zip backup. Use after a machine migration, accidental deletion, when workspace/ is out of sync with the backup, or when asked to "sync workspace/", "recover workspace", "restore from backup", or "pull backup". |

---

## Hooks at a glance

Hooks run on Claude Code lifecycle events. `PreToolUse:Bash` rejects known destructive git patterns before execution: direct or wrapped `git reset --hard`, `clean -f`, `branch -D`, unsafe alias injection, hook/signing bypass flags, protected-branch pushes to any remote, and remote branch deletion. This is defense-in-depth, not a full shell sandbox.

External-write hooks block direct Slack sends, require a fresh prompted Jira write token plus explicit body format, and stop oversized or non-ADF Confluence page writes before they can truncate or lose rich content. Use Slack drafts, explicit Jira confirmation, or a `workspace/tmp/` Confluence patch when those guards fire.

Other hooks: `SessionStart` creates today's log and reports backup status; `UserPromptSubmit` nudges `[STYLE-DELTA]` capture for style corrections and records slash commands; `Stop` backs up `workspace/`; `PostToolUse:Skill` logs `/nase:*`; `PostToolUse:Read` logs KB reads to `workspace/stats/kb-usage.jsonl`; `PreToolUse:Edit|Write|MultiEdit` fact-forces the first source-file edit per session; `PostToolUse:Edit|Write` shellchecks edited `.sh`; worktree removal logs lifecycle; `PreCompact` rotates old lessons/efforts.

Full table with behavior details: [`docs/architecture.md` — Hooks that gate tool calls](docs/architecture.md#hooks-that-gate-tool-calls).

The `Stop` hook reads `backup-target` from `.local-paths` (set by `/nase:init`). If the file doesn't exist, the hook silently skips.

---

## Workspace structure

```
nase/
  .claude/             kit — subagents, slash commands, hooks, scripts, settings (tracked; local settings/skills and generated wrappers ignored)
  docs/                deeper docs (architecture, internals)
  tests/               CI gates
  CLAUDE.md            AI identity + operating rules (tracked)
  README.md            this file
  .local-paths         machine-specific paths — backup target, repo paths (not tracked)
  workspace/           your content — KB, logs, journals, skills, tasks (not tracked)
```

| Path | In git? | Reason |
|------|---------|--------|
| `.claude/`, `docs/`, `CLAUDE.md`, `README.md`, `tests/` | Yes, except `.claude/settings.local.json`, `.claude/skills/`, and `.claude/commands/nase/workspace/` | Shared kit + docs; local settings/skills and generated wrappers stay local |
| `.local-paths` | No | Machine-specific paths |
| `workspace/` | No | Per-user content |

Full layout (kit + `workspace/`): [`docs/architecture.md` — Workspace layout](docs/architecture.md#workspace-layout).

---

## Configuration

The kit is tracked by git; `workspace/` is ignored and stays local. `git pull` updates only kit files.

**Customizing for your stack:**

- Add KB domains: create `workspace/kb/general/<domain>.md` and edit `workspace/kb/.domain-map.md`
- Add a repo: `/nase:onboard <path-or-url>`; refresh all with `/nase:onboard`
- Change tech news sources, topics, or output sections: edit `workspace/tech-digest-config.md`
- Change identity/language: edit `workspace/config.md` or rerun `/nase:init`
- Change backup retention: edit `backup_retention:` in `workspace/config.md` (e.g. `count:100` or `days:7`)
- Change backup target: edit `backup-target=` in root `.local-paths`

> **Input formats**: `/nase:onboard` accepts Unix/macOS/Windows/Git Bash paths and GitHub URLs. GitHub URLs resolve via `.local-paths`; no clone/network required.

**Contributing:**

Found a bug or have a suggestion? [Open an issue](https://github.com/anels/nase/issues).

---

## Further reading

- [`docs/architecture.md`](docs/architecture.md) — how nase is wired: hooks, feedback loops in skills, cross-repo awareness, model routing, full workspace layout
- [`CLAUDE.md`](CLAUDE.md) — operating rules loaded into every Claude Code session
- `.claude/commands/nase/*.md` — source for each slash command
- `.claude/docs/*.md` — shared algorithm docs referenced by skills (`kb-template`, `daily-log-format`, `repo-resolution`, `skill-contract`, etc.)
