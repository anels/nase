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
- **7z or zip** - required for backups; 7z/7zz is also required to inspect and restore legacy `.7z` backups
- **jq** — required by hooks that parse Claude Code lifecycle JSON (`block-dangerous-git.sh`, external-write guards, `track-skill.sh`, telemetry hooks)
- **python3** - required by date-range helpers, transactional workspace restore, and tech-digest archival

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
- **Offline skill evals** - `evals/pr-review/` covers PR/review flows; `evals/core-workflows/` covers design, daily, learning, onboarding, incident, and deployment flows.

`workspace/` content persists locally and is auto-backed-up. The kit (`.claude/`, `CLAUDE.md`, `README.md`, `docs/`) lives in git; your content stays local.

Architecture details live in [`docs/architecture.md`](docs/architecture.md).

Run the offline eval schema checks locally:

```bash
python3 .claude/scripts/pr-review-eval.py validate evals/pr-review/evals.json
python3 .claude/scripts/pr-review-eval.py validate evals/core-workflows/evals.json
```

### Design principles

- **Deterministic guardrails beat prompt promises.** Prompt rules describe intent; hooks and tests enforce the dangerous edges: protected-branch pushes, destructive git, direct Slack sends, Jira mutations, oversized Confluence writes, shell-script regressions, and warn-only workspace quality drift.
- **Context is sliced, not dumped.** Commands read repo KB, domain maps, GitHub metadata, focused diffs, and script-filtered logs before pulling more files into context.
- **Knowledge stays reviewable.** Durable memory is plain Markdown under `workspace/kb/`, `workspace/tasks/`, `workspace/skills/`, and `workspace/journals/`; humans can inspect, edit, delete, and share it.
- **Review claims need evidence.** PR and audit workflows should back findings with source paths, diffs, tests, logs, or `gh`/`rg`/`ast-grep` output, then drop candidates that cannot be verified.
- **External writes stay human-triggered.** Slack uses drafts, Jira writes require a short-lived token after approval, Confluence writes are ADF/size-guarded, and GitHub/Azure/Kubernetes/Terraform CLI mutations require an approved payload-bound action manifest.
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
| `/nase:doctor` | Diagnose nase workspace configuration, hooks, backups, tools, and skill sync. Use for doctor, health check, hooks not firing, backup warnings, or after migration. |
| `/nase:help` | Show the nase command and hook guide. Use for help, show commands, what can you do, what skills are available, or how does nase work. |
| `/nase:init` | Initialize or reconfigure an idempotent nase workspace. Use for first-time setup, a new machine, missing workspace/config.md, init nase, configure, or bootstrap. |

### Knowledge base

| Command | Purpose |
|---------|---------|
| `/nase:kb-gap-detect` | Find missing KB topics from logs and lessons. Use for knowledge gap, find KB holes, or what should I document; use /nase:kb-review for stale or duplicate entries. |
| `/nase:kb-merge` | Import a teammate's shared KB with safe merge previews. Use for import KB, merge KB, merge shared KB, or after receiving a /nase:kb-teamshare export. |
| `/nase:kb-review` | Audit and organize KB files for duplicates, links, staleness, and lesson promotion. Use for review KB, organize notes, clean up KB, or periodic KB hygiene. |
| `/nase:kb-search` | Search KB files for topics, keywords, patterns, and related entries. Use for search KB, find in KB, or is X documented; use /nase:kb-update or /nase:learn to write. |
| `/nase:kb-teamshare` | Export sanitized KB files or workspace skills for teammates. Use for share my KB, export knowledge base, share skills, or package content for /nase:kb-merge. |
| `/nase:kb-update` | Persist durable knowledge tied to one repo. Use for update KB, add a repo constraint, or document an API contract; use /nase:learn for shared patterns. |
| `/nase:onboard` | Onboard or refresh repo context in the workspace KB. Use before repo work or for onboard, refresh KB, refresh all repos, add repo, a repo path, or a GitHub URL. |
| `/nase:tech-digest` | Fetch a sourced tech-news digest filtered to workspace topics. Use for tech news, tech digest, what's new, latest in AI, morning digest, or tech roundup. |

### Learning & reflection

| Command | Purpose |
|---------|---------|
| `/nase:extract-skills` | Extract reusable problem-solving patterns from the current session into nase skills. Use after non-trivial work or for extract pattern, save technique, or capture workflow. |
| `/nase:learn` | Research and save a tip, URL, repo, or cross-project pattern to KB. Use for remember this, learn from this, deep dive, or article URL. |
| `/nase:reflect` | Reflect on completed work and extract lessons. Use after a feature, bug fix, or debugging session, or for reflect, what went well, or post-mortem. |
| `/nase:today` | Build a live-status-checked daily plan from workspace, PR, Jira, Slack, and Confluence context. Use for today, morning kickoff, daily plan, standup, or what should I work on. |
| `/nase:wrap-up` | Capture end-of-day reflection, lessons, KB updates, and a journal entry. Use for wrap up, end of day, EOD, done for today, closing out, or summarize today. |

### Design & implementation

| Command | Purpose |
|---------|---------|
| `/nase:design` | Research and write an implementation design without coding. Use for design, brainstorm, plan feature, kickoff, grill plan, or review a design. |
| `/nase:fsd` | Implement and verify a feature or fix through a draft PR. Use for fsd, just do it, run autonomously, fire and forget, or feature/fix handoff. |

### Git workflow

| Command | Purpose |
|---------|---------|
| `/nase:address-comments` | Resolve existing PR review feedback with fixes or replies. Use for address comments, fix review comments, handle PR feedback, or resolve threads. |
| `/nase:discuss-pr` | Deeply review a PR and draft evidence-backed inline findings. Use for analyze PR, review PR, self-review, or a PR URL; use /nase:address-comments for existing feedback. |
| `/nase:improve-commit-message` | Rewrite the latest commit message to match repo conventions. Use after committing, before push, or for improve commit, fix commit message, amend commit, or clean up commit. |
| `/nase:prep-merge` | Prepare a PR for merge by checking threads, history, verification, and metadata. Use with a PR URL only for explicit prep merge, squash and push, clean up, ready-to-merge, or finalize intent. |
| `/nase:request-review` | Find appropriate PR reviewers and stage Slack DM drafts. Use with PR URLs to request review, request approval, notify reviewers, or ping code owners. |
| `/nase:simplify` | Simplify recently modified code without changing behavior. Use before commit or for simplify, clean up code, refactor for clarity, tidy up, deslop, or anti-slop. |

### Reporting

| Command | Purpose |
|---------|---------|
| `/nase:effort-rollup` | Build a monthly delivery report from live PR and Jira state. Use for effort rollup, impact report, month in review, or what did I ship. |
| `/nase:efforts` | Reconcile active efforts with live PR and Jira state. Use for list my efforts, effort status, sync efforts, stalled work, or what am I working on. |
| `/nase:estimate-eta` | Estimate effort and ETA for a task or feature. Use for how long will this take, when can we ship, estimate this, or before committing to a timeline. |
| `/nase:kb-usage` | Report which skills use which KB files and which mapped files are unused. Use for KB usage, KB observability, top KB files, or unused KB entries. |
| `/nase:recap` | Generate a weekly or monthly work recap with improvement suggestions. Use for recap, review my work, review progress, what did I do, or summarize a period. |
| `/nase:skill-usage` | Report skill usage, outcomes, context hotspots, and deprecation candidates. Use for which skills do I use, skill stats, skill token cost, context hotspots, or deprecate skills. |
| `/nase:stats` | Display workspace activity counts and charts inline. Use for show stats, how active am I, productivity, or 7/30/all-time activity; use /nase:recap for narrative. |

### Security & maintenance

| Command | Purpose |
|---------|---------|
| `/nase:skill-audit` | Scan skills for injection, exfiltration, unsafe operations, supply-chain, and credential risks. Use for audit skills, skill security, or imported skills. |
| `/nase:tech-debt-audit` | Audit a repo for tech debt, architecture gaps, modernization, and AI verification debt. Use for tech debt audit, architecture review, or modernization. |

### Backup & restore

| Command | Purpose |
|---------|---------|
| `/nase:restore` | Restore workspace/ from a backup. Use after migration or deletion, when local state is out of sync, or for sync workspace, recover workspace, restore backup, or pull backup. |

---
## Hooks at a glance

Hooks run on Claude Code lifecycle events. `PreToolUse:Bash` rejects known destructive git patterns before execution: direct or wrapped `git reset --hard`, `clean -f`, `branch -D`, unsafe alias injection, hook/signing bypass flags, protected-branch pushes to any remote, and remote branch deletion. This is defense-in-depth, not a full shell sandbox.

External-write hooks block direct Slack sends, require a fresh prompted Jira write token plus explicit body format, stop oversized or non-ADF Confluence page writes, and reject raw GitHub/Azure/Kubernetes/Terraform CLI mutations. Use Slack drafts, explicit Jira confirmation, a `workspace/tmp/` Confluence patch, or an approved `external-write-action.py` manifest when those guards fire.

Other hooks: `SessionStart` creates today's log, reports backup status, and syncs local `workspace/skills` into generated `/nase:workspace:*` command wrappers; `UserPromptSubmit` records slash-command recognition, `UserPromptExpansion` records activation, and `PostToolUse:Skill` records tool outcome; `Stop` backs up `workspace/`; `StopFailure`, `PostToolUseFailure`, and `SubagentStop` write redacted bounded failure/subagent summaries; `PostToolUse:Read` logs KB reads to `workspace/stats/kb-usage.jsonl`; `PreToolUse:Edit|Write|MultiEdit` fact-forces the first source-file edit per session; `PostToolUse:Edit|Write` shellchecks edited `.sh`; worktree removal logs lifecycle; `PreCompact` rotates old lessons/efforts. `WorktreeCreate` is intentionally unwired because Claude Code expects that hook to create and print the worktree path.

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
