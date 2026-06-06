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

A personal AI engineering workbench for Claude Code:

- **Per-repo KB** — `workspace/kb/projects/<repo>.md` plus shared `workspace/kb/general/`; `/nase:onboard` populates them and tasks load only relevant files.
- **30+ slash commands** — daily kickoff, onboarding, design, implementation, PR review, KB hygiene, wrap-up. See [Available commands](#available-commands).
- **Hooks** — block destructive git and guard high-risk external writes, back up `workspace/`, log `/nase:*` usage, and run validation helpers. See [Hooks at a glance](#hooks-at-a-glance).
- **Offline PR evals** — `evals/pr-review/` contains deterministic output-shape checks for high-frequency PR/review workflows.

`workspace/` content persists locally and is auto-backed-up. The kit (`.claude/`, `CLAUDE.md`, `README.md`, `docs/`) lives in git; your content stays local.

Architecture details live in [`docs/architecture.md`](docs/architecture.md).

Run the PR/review eval schema check locally:

```bash
python3 .claude/scripts/pr-review-eval.py validate evals/pr-review/evals.json
```

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

- `/nase:design` handles complex tasks: KB context, 2–3 approaches, tradeoffs, tracked effort doc. Skip it for simple fixes.
- `/nase:fsd` handles code → test → fix → commit → push → draft PR. For large features use **Direct with Phase isolation**; for hard TDD use **Yes** at the TDD prompt.
- Optional Codex gates run where configured and skip cleanly otherwise.
- Reviewer discovery uses KB → git history → CODEOWNERS, then stages Slack DM drafts.
- Review feedback is handled interactively: obvious fixes applied, ambiguous comments discussed one by one.

```
/nase:onboard <repo>          # load repo context into KB
/nase:design <task>            # (complex tasks) explore approaches → effort doc
  review and iterate             # discuss tradeoffs, refine until approved
  /nase:design --grill <slug>    # (optional) stress-test the plan one question at a time
/nase:fsd <task>               # implement → test → commit → push → draft PR
/nase:request-review <PR-URL>  # find right reviewers, stage Slack DM drafts
  ⏳ wait for feedback
/nase:address-comments <PR-URL> # discuss or auto-fix each comment → push → current failed gate check
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

### Setup & health

| Command | Purpose |
|---------|---------|
| `/nase:init [name]` | First-time setup: set AI name, configure backup & language, initialize `workspace/`; offers to restore from backup on fresh init |
| `/nase:doctor` | Self-diagnostic: verify hooks, backup config, workspace/ structure, tools |
| `/nase:help` | Show usage guide and command overview |

### Knowledge base

| Command | Purpose |
|---------|---------|
| `/nase:onboard` | Refresh ALL already-onboarded repos from `workspace/context.md` (run at session start) |
| `/nase:onboard <path-or-url>` | Onboard or refresh a single repo (local path or GitHub URL) |
| `/nase:tech-digest [--force] [--dry-run] [--since Nd|YYYY-MM-DD] [--section name] [--sources name,url]` | Fetch latest tech news with source links, cache skips, actionable workflow notes, and concrete follow-up options → `workspace/kb/general/tech-trends.md` |
| `/nase:kb-update [domain]` | Update knowledge base with session learnings |
| `/nase:kb-search <topic>` | Search across all KB files by topic, keyword, or pattern; supports `in:general/projects/ops/cross-project`, tag/date/confidence, `mentions:<path>`, capped previews, `--full`, and `--max-entry-lines` |
| `/nase:kb-review [scope]` | Review, organize, and consolidate KB — deduplicate, cross-reference, surface stale content |
| `/nase:kb-gap-detect [opts]` | Scan recent daily logs + lessons for knowledge-gap signals (uncertainty, doc lookups, SME teachings), cluster by topic, cross-check against KB, propose drafts for missing topics |
| `/nase:kb-teamshare [path]` | Export selected KB files and workspace skills as a portable, sanitized directory for teammates |
| `/nase:kb-merge [path]` | Import and merge a teammate's shared KB into your local `workspace/kb/` |

### Learning & reflection

| Command | Purpose |
|---------|---------|
| `/nase:today` | Morning kickoff: auto-sync PR/Jira statuses, surface proactive Need Attention items from KB/logs/tasks/Jira/Slack, optionally offer concrete next actions, then show focus + priorities + blockers. Supports `--verbose` for uncapped lists |
| `/nase:learn [tip\|url]` | Capture a tip, article URL, or GitHub repo → deep research → write to relevant KB file, then offer concrete follow-up options. Example: `async void is dangerous in C#` → general KB |
| `/nase:reflect [task]` | Post-task reflection |
| `/nase:extract-skills` | Analyze current session → extract reusable patterns as files under `workspace/skills/` |
| `/nase:wrap-up [force]` | End-of-day routine: reflect → learn → extract-skills → kb-update → journal entry → `workspace/journals/YYYY-MM-DD.md` |

### Design & implementation

| Command | Purpose |
|---------|---------|
| `/nase:design <idea>` | KB-aware design — research context, explore 2–3 approaches with tradeoffs, write tracked effort doc to `workspace/efforts/`. Supports `--grill` (stress-test), `--review` (re-evaluate), `--auto` (end-to-end design pass) |
| `/nase:fsd <task>` | Full Self-Develop — ask options upfront (including phase isolation and strict TDD), then run implement → build → test (fix loop) → simplify → commit → push → draft PR → cleanup |

### Git workflow

| Command | Purpose |
|---------|---------|
| `/nase:simplify [scope]` | Simplify recently modified code while preserving behavior; part of the standard pre-commit sequence before `/nase:improve-commit-message` |
| `/nase:improve-commit-message` | Rewrite last commit message to conventional commits format |
| `/nase:request-review <PR-URL(s)>` | Find reviewers (KB → git history → CODEOWNERS) and stage Slack DM drafts |
| `/nase:discuss-pr <PR-URL>` | KB-driven PR review discussion in chat; reads & engages existing review comments (+1/reply/discuss), drafts inline comments for manual posting, triggers KB update on confirmed findings |
| `/nase:address-comments <PR-URL>` | Auto-fix or discuss unresolved PR comments 1-by-1, then push, check current PR gates once, fix mechanical failures only, resolve, and capture learnings to KB |
| `/nase:prep-merge <PR-URL>` | After multiple review iterations, commit history gets messy and PR title/description drift from the final state — rebase on the target branch, squash commits, verify comments resolved, rewrite PR title/description to match what was actually delivered, then optionally un-draft and request review |

### Reporting

| Command | Purpose |
|---------|---------|
| `/nase:recap [week\|last week\|month\|last month\|YYYY-MM-DD to YYYY-MM-DD]` | Structured recap of work over a period (weekly Mon–Sun, monthly 1st–last day) → full recap auto-saved to `workspace/recaps/`; chat shows compact summary (Stats + Overview + Suggestions). Pass `--verbose` for full inline output |
| `/nase:estimate-eta <task>` | Effort estimate |
| `/nase:stats [N\|Nd\|week\|month\|all\|YYYY-MM-DD to YYYY-MM-DD]` | Workspace usage statistics with GitHub-style heatmap, tiered skill usage, and summary counters printed inline |
| `/nase:skill-usage [--window N] [--top N]` | Skill invocation frequency × recency from `workspace/stats/skill-usage.jsonl`; flags deprecation candidates (0 uses in `N` days, default 60) → `workspace/stats/skill-usage-YYYY-MM-DD.md` |

### Security & maintenance

| Command | Purpose |
|---------|---------|
| `/nase:skill-audit [path]` | Scan skill files for security risks — command injection, data exfiltration, prompt injection, unsafe file ops; auto-runs during `/nase:kb-merge` |
| `/nase:tech-debt-audit <repo>` | Audit tech debt, architecture health, best-practices compliance, and modernization opportunities → `workspace/kb/projects/tech-debt/{repo}-tech-debt.md` |

### Backup & restore

| Command | Purpose |
|---------|---------|
| `/nase:restore` | Restore `workspace/` from a zip backup (lists available backups, lets you pick one) |

---

## Hooks at a glance

Hooks run on Claude Code lifecycle events. `PreToolUse:Bash` rejects known destructive git patterns before execution: direct or wrapped `git reset --hard`, `clean -f`, `branch -D`, unsafe alias injection, hook/signing bypass flags, protected-branch pushes to any remote, and remote branch deletion. This is defense-in-depth, not a full shell sandbox.

External-write hooks block direct Slack sends, require a fresh prompted Jira write token, and stop oversized Confluence page writes before they can truncate. Use Slack drafts, explicit Jira confirmation, or a `workspace/tmp/` Confluence patch when those guards fire.

Other hooks: `SessionStart` creates today's log and reports backup status; `UserPromptSubmit` nudges `[STYLE-DELTA]` capture for style corrections and records slash commands; `Stop` backs up `workspace/`; `PostToolUse:Skill` logs `/nase:*`; `PreToolUse:Edit|Write|MultiEdit` fact-forces the first source-file edit per session; `PostToolUse:Edit|Write` shellchecks edited `.sh`; worktree removal logs lifecycle; `PreCompact` rotates old lessons/efforts.

Full table with behavior details: [`docs/architecture.md` — Hooks that gate tool calls](docs/architecture.md#hooks-that-gate-tool-calls).

The `Stop` hook reads `backup-target` from `.local-paths` (set by `/nase:init`). If the file doesn't exist, the hook silently skips.

---

## Workspace structure

```
nase/
  .claude/             kit — slash commands, hooks, scripts, settings (tracked in git)
  docs/                deeper docs (architecture, internals)
  tests/               CI gates
  CLAUDE.md            AI identity + operating rules (tracked)
  README.md            this file
  .local-paths         machine-specific paths — backup target, repo paths (not tracked)
  workspace/           your content — KB, logs, journals, skills, tasks (not tracked)
```

| Path | In git? | Reason |
|------|---------|--------|
| `.claude/`, `docs/`, `CLAUDE.md`, `README.md`, `tests/` | Yes | Shared kit + docs |
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
