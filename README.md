# nase — Not A(i) Software Engineer

A [Claude Code](https://claude.ai/code) workspace template for an AI engineer working across multiple backend repositories. Gives you slash commands for onboarding repos, tracking knowledge, generating reports, and auto-backing up your work — all inside Claude Code.

> **Name origin**: "nase" sounds like 那谁 (*nà shuí*) in Chinese — the casual "hey, whatsyourname" you say when summoning someone whose name you can't be bothered to remember: *"oi, whatsyourname, come take care of this."* A fitting name for an AI you summon to handle engineering tasks.

> **Requires:** Claude Code CLI. All `/nase:*` commands are Claude Code slash commands — they won't work in other tools.

---

## Why nase?

Most Claude Code setups are a collection of prompts. nase is a **persistent AI engineer** — it has an identity, remembers what it learned yesterday, knows your repos, and improves its own skills over time.

### The core idea: a teammate that grows

Every session, nase reads your knowledge base, stays up to date with tech news in your stack, and logs what it did. Every time you solve a hard problem, you can capture it — as a lesson, as a KB entry, or as a new slash command for future use. The workspace gets smarter the longer you use it.

### What makes it different

| Other setups | nase |
|---|---|
| Stateless — Claude forgets everything between sessions | Persistent KB survives session resets; loaded on demand |
| Generic prompts for any task | Opinionated workflow for backend engineers (`.NET`, `Azure`, `Spark`, `K8s`) |
| Manual context management | Auto-onboards repos, auto-backs up work, auto-digests tech news |
| You write the commands | Commands write new commands (`/nase:extract-skills`) |
| One assistant, one task | Named AI identity with daily lifecycle: morning → work → wrap-up → backup |

### Highlights

**🧠 Persistent knowledge base**
Each repo gets its own `work/kb/projects/<repo>.md`. Stack-level patterns go in `work/kb/general/`. Knowledge is loaded surgically — only the relevant domain file is read, keeping context lean.

**📰 Tech digest on autopilot**
`/nase:tech-digest` fetches your configured sources (blogs, changelogs, HN), filters for your stack, and prepends a dated digest to `tech-trends.md`. Entries older than 30 days are archived automatically.

**🔁 Daily workflow out of the box**
- Morning: `/nase:today` — what to focus on, what's blocked
- Work: `/nase:onboard <repo>` before touching any repo; `/nase:learn <url>` to ingest an article mid-session
- Evening: `/nase:wrap-up` — fully autonomous: reflect → learn → extract-skills → kb-update → daily-report, written to `work/journals/`

**📦 Auto-backup with hooks**
A `Stop` hook runs at every session end, syncing `work/` to your configured backup path (OneDrive, local drive, etc.). An atomic staging strategy with in-place copy ensures the backup is never left in a broken state — even on cloud-synced drives.

**🛠️ Skills that write skills**
`/nase:extract-skills` analyzes the current session, identifies reusable patterns, and saves them as pattern files under `work/skills/`. These are user-specific and gitignored — the workspace literally programs itself, and the patterns stay private to your workspace.

**📖 Learn from anything**
`/nase:learn` accepts plain text, a GitHub repo URL, or an article URL. For URLs, it fetches the content, filters for relevance to your stack, extracts concrete learnings, shows them to you for review, then writes to both `lessons.md` and the appropriate KB domain file.

---

## Prerequisites

- **Claude Code CLI** — [install guide](https://docs.anthropic.com/en/docs/claude-code)
- **Git** — required for hooks and report commands

### Required MCP servers

Two MCP integrations are expected for full functionality:

| MCP | Used for | Setup |
|-----|----------|-------|
| **Atlassian** (Confluence + Jira) | `/nase:onboard` reads Confluence docs; Jira ticket lookup in session logs and reports | [Atlassian MCP](https://github.com/atlassian/mcp-atlassian) |
| **GitHub** | PR links in reports; code review commands | [GitHub MCP](https://github.com/github/github-mcp-server) |

Configure both in your Claude Code `settings.json` (or `settings.local.json`) under `mcpServers` before running `/nase:init`.

---

## What's in this template

```
nase/
  .claude/
    commands/nase/      ← Claude Code slash commands (pre-built)
      init.md
      doctor.md
      help.md
      today.md
      onboard.md
      tech-digest.md
      kb-update.md
      learn.md
      reflect.md
      extract-skills.md
      wrap-up.md
      daily-report.md
      weekly-report.md
      monthly-report.md
      estimate-eta.md
      restore.md
    hooks/              ← Hook scripts (called by settings.json)
      session-start.sh
      stop-backup.sh
    settings.json       ← Claude Code hooks (SessionStart + Stop)
  CLAUDE.md             ← AI identity + operating rules (loaded by Claude Code automatically)
  README.md             ← this file
```

> `work/` is **not** part of the template. It holds your project-specific content and is created when you run `/nase:onboard` for the first time.

---

## Getting started

### 1. Clone and open in Claude Code
```bash
git clone https://github.com/anels/nase.git my-workspace
cd my-workspace
claude  # open Claude Code in this directory
```

### 2. Initialize the workspace
In Claude Code, run:
```
/nase:init
```
This sets your AI engineer name, configures the backup location, and creates the `work/` skeleton. The workspace name is auto-derived from the actual folder name and saved to `work/config.md` — no manual config needed.

### 3. Onboard your first repo
```
/nase:onboard C:\path\to\your\repo
/nase:onboard https://github.com/Org/RepoName
```
Accepts a local path (Windows or Git Bash format) **or** a GitHub URL (`https://` / `git@`). When given a URL, the repo name is extracted and matched against paths already in `work/context.md` — no cloning, no network calls.

This will:
- Explore the repo and create `work/kb/projects/<repo>.md`
- Add the repo to `work/context.md`
- Prompt once for a backup location (stored in `.backup-target`)

### 4. Start your first session
```
/nase:tech-digest
```
Fetches the latest tech news for your stack → `work/kb/general/tech-trends.md`.

Then each morning:
```
/nase:today
```
And at end of day:
```
/nase:wrap-up
```

---

## Available commands

**Setup & Health**

| Command | Purpose |
|---------|---------|
| `/nase:init [name]` | First-time setup: set AI name, configure backup, initialize `work/` |
| `/nase:doctor` | Self-diagnostic: verify hooks, backup config, work/ structure, tools |
| `/nase:help` | Show usage guide and command overview |

**Knowledge Base**

| Command | Purpose |
|---------|---------|
| `/nase:onboard <path-or-url>` | Onboard a new repo (local path or GitHub URL) + configure backup on first run |
| `/nase:tech-digest` | Fetch latest tech news → `work/kb/general/tech-trends.md` |
| `/nase:kb-update [domain]` | Update knowledge base with session learnings |

**Learning & Reflection**

| Command | Purpose |
|---------|---------|
| `/nase:today` | Morning kickoff: today's focus + priorities + blockers |
| `/nase:learn [tip\|url]` | Capture a tip, or feed a URL (article/repo) → auto-extract learnings → `work/tasks/lessons.md` + relevant KB file |
| `/nase:reflect [task]` | Post-task reflection |
| `/nase:extract-skills` | Analyze current session → extract reusable patterns as files under `work/skills/` (gitignored; user-specific) |
| `/nase:wrap-up [force]` | End-of-day routine: fully autonomous — reflect → learn → extract-skills → kb-update → daily-report, output written to `work/journals/YYYY-MM-DD.md` |

**Git Workflow**

| Command | Purpose |
|---------|---------|
| `/nase:improve-commit-message` | Rewrite last commit message to conventional commits format |
| `/nase:update-changelog [version] [from <ref>] [to <ref>]` | Generate or update `CHANGELOG.md` by analyzing actual code changes between two git refs |

**Reporting**

| Command | Purpose |
|---------|---------|
| `/nase:daily-report` | Today's AI-assisted work summary |
| `/nase:weekly-report` | Week-in-review across all repos |
| `/nase:monthly-report` | Monthly recap (includes KB freshness audit) |
| `/nase:estimate-eta <task>` | Effort estimate |

**Backup & Restore**

| Command | Purpose |
|---------|---------|
| `/nase:restore` | Restore `work/` from backup |

---

## Automatic hooks (no action needed)

| Hook | When | What it does |
|------|------|--------------|
| `SessionStart` | Every new Claude Code session | Creates `work/logs/YYYY-MM-DD.md` if missing; alerts if last backup had an error or target is unreachable; archives tech digest entries older than 30 days; suggests `/nase:reflect` if you made commits today; prompts `/nase:weekly-report` if >7 days since last |
| `Stop` | Every session end | Appends today's commit summary to the daily log; warns if no session notes were written; syncs `work/` → backup target (in-place, OneDrive-compatible); writes status to `work/logs/.backup-status` |

The `Stop` hook reads `.backup-target` at the workspace root (set by `/nase:onboard`). If the file doesn't exist, it silently skips.

> **Initialization order**: Run `/nase:onboard` before the first `Stop` hook fires — the hook needs `.backup-target` to exist. The `SessionStart` hook creates the daily log immediately and works without any setup.

---

## `work/` structure (after initialization)

```
work/
  config.md               ← AI engineer name + workspace name (gitignored, managed by /nase:init)
  context.md              ← repo list + domain patterns (rich reference, not just quick-recall)
  tech-digest-config.md   ← personal sources + filter topics for /nase:tech-digest (edit to customize)
  kb/
    .domain-map.md    ← project-domain → kb file mappings (managed by /nase:onboard)
    projects/         ← one file per repo (architecture, constraints, patterns)
    general/
      workflow.md     ← commit rules, PR process, coding principles
      debugging.md    ← debugging techniques, past root causes
      <your-stack>.md ← patterns for your primary stack (e.g. dotnet.md, spark-scala.md — customize to match your tech)
      tech-trends.md  ← monthly rolling tech digest (auto-appended by /nase:tech-digest)
      tech-trends-archive-YYYY.md  ← entries older than 30 days (auto-archived)
  logs/               ← daily work logs + .backup-status (auto-managed by hooks)
  journals/           ← end-of-day wrap-up files (written by /nase:wrap-up, one per day)
  skills/             ← auto-extracted reusable patterns (written by /nase:extract-skills; gitignored)
  tasks/
    lessons.md        ← accumulated lessons from /nase:learn and /nase:reflect
    todo.md           ← current task tracking
```

`.backup-target` is at the **workspace root** (not inside `work/`) so it survives a `work/` deletion or restore scenario.

`work/` is git-ignored — it never gets committed.

---

## Keeping the template updated

The template layer (`.claude/`, `CLAUDE.md`, `README.md`) is tracked by git. Your work content (`work/`) is git-ignored and stays local.

### Improve the template as you work
When you refine a skill or discover a better workflow, commit the template change:
```bash
git add .claude/commands/nase/kb-update.md
git commit -m "feat(kb-update): add spark-streaming domain mapping"
git push
```

### Pull template updates into an existing workspace
```bash
git pull
```
`work/` is git-ignored — the pull only updates template files, never your content.

### What goes in git vs. what stays local

| Path | In git? | Reason |
|------|---------|--------|
| `.claude/` | Yes | Shared workflow improvements |
| `CLAUDE.md` | Yes | Identity + operating rules |
| `README.md` | Yes | Usage guide |
| `.backup-target` | No | Personal backup path; git-ignored |
| `work/` | No | Project-specific; git-ignored |

---

## Customizing for your stack

- **Add new kb domains**: create `work/kb/general/<domain>.md` and run `/nase:onboard` or edit `work/kb/.domain-map.md` directly
- **Add new repo**: run `/nase:onboard <path-or-url>` — accepts a local path or GitHub URL; creates the kb entry and updates `work/context.md`
- **Change tech news sources or filter topics**: edit `work/tech-digest-config.md`
- **Change AI identity or workspace name**: run `/nase:init` or edit `work/config.md` directly (`AI engineer:` and `workspace:` fields)
- **Change backup location**: edit `.backup-target` at the workspace root (one line, bash-format path)

> **Input formats**: `/nase:onboard` accepts Windows paths (`C:\foo\bar`), Git Bash paths (`/c/foo/bar`), and GitHub URLs (`https://github.com/Org/Repo` or `git@github.com:Org/Repo.git`). GitHub URLs are resolved to local paths via `work/context.md` — no cloning or network access required. If using WSL, provide local paths in Linux format directly.
