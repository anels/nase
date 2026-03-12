# nase Reference Guide

This file contains reference material moved from CLAUDE.md to reduce per-message token usage.
Read this file on demand when you need details about workspace layout, skills, KB structure, or architecture notes.

---

## Workspace Layout

```
.claude/
  commands/nase/     ← all /nase:* skills (one .md file per command)
  hooks/
    session-start.sh ← runs at SessionStart: creates daily log, archives old tech digest,
                       surfaces backup warnings, suggests /nase:reflect when commits exist,
                       suggests /nase:weekly-report if >7 days since last
    stop-todos.sh    ← runs at Stop (before backup): surfaces pending todos from work/tasks/todo.md
    stop-backup.sh   ← runs at Stop: appends commit summary to daily log, syncs work/ →
                       backup target in-place (OneDrive-compatible), warns if notes missing
    track-skill.sh   ← runs at PostToolUse (Skill): records /nase:* invocations to
                       work/stats/skill-usage.jsonl for /nase:stats reporting
  settings.json      ← hook registrations (SessionStart + Stop + PostToolUse)
.backup-target       ← single line, bash-format path (e.g. /c/Users/me/OneDrive/backup/nase-backup)
                       lives at workspace root (NOT inside work/); managed by /nase:init
work/               ← entirely git-ignored; never committed
  config.md          ← format: AI engineer: <name> / workspace: <folder-name>  (managed by /nase:init)
  journals/          ← end-of-day wrap-up files (written by /nase:wrap-up, one per day)
  scripts/           ← one-off utility scripts (e.g. deploy-uptime-kuma.ps1)
```

---

## Knowledge Base Structure

```
work/                   ← entirely git-ignored; never committed
  context.md              ← repo list + domain patterns
  tech-digest-config.md   ← personal sources + filter topics for /nase:tech-digest
  kb/
    .domain-map.md        ← project-domain → kb file mappings (managed by /nase:onboard)
    projects/
      <your-repo>.md           ← one file per repo (created by /nase:onboard)
    general/
      workflow.md              ← protocols, coding principles, PR rules
      debugging.md             ← debugging techniques, past root causes
      <your-stack>.md          ← general patterns for your primary stack (e.g. dotnet.md, spark-scala.md)
      tech-trends.md           ← rolling 30-day tech digest (auto-managed by /nase:tech-digest)
      tech-trends-archive-YYYY.md ← entries older than 30 days (auto-archived)
  skills/
    {name}.md             ← auto-extracted reusable patterns (written by /nase:extract-skills; gitignored)
  tasks/
    lessons.md            ← accumulated lessons from /nase:learn and /nase:reflect
    todo.md               ← current task tracking
  journals/
    YYYY-MM-DD.md         ← end-of-day wrap-up output (written by /nase:wrap-up)
  stats/
    skill-usage.jsonl     ← append-only JSONL: {skill, ts} per /nase:* invocation (auto-written by hook)
    report-YYYY-MM-DD.md  ← detailed stats report (written by /nase:stats)
  logs/
    YYYY-MM-DD.md         ← daily work logs (auto-created by SessionStart hook)
    .backup-status        ← timestamped backup results (written by Stop hook)
  reports/
    .report-status        ← tracks last weekly/monthly report date (used by SessionStart to prompt)
    daily/
      YYYY-MM-DD.md       ← daily reports (written by /nase:daily-report)
    weekly/
      YYYY-MM-DD.md       ← weekly reports, Monday date as filename (written by /nase:weekly-report)
    monthly/
      YYYY-MM.md          ← monthly reports (written by /nase:monthly-report)
```

---

## Execution Style

<default_to_action>
When a command is triggered, execute the workflow steps directly.
Only pause for user input at explicitly marked checkpoints (e.g., "ask the user", "Pause").
Proceed through git commands, file reads, and data gathering without asking permission.
</default_to_action>

<execution_style>
Engineering commands fall into three categories:
- **Data gathering** (daily-report, weekly-report, doctor): collect all data first, then present — execute deterministically.
- **Interactive** (kb-update, onboard): gather context automatically, then pause at marked checkpoints for user input.
- **Autonomous** (wrap-up): runs all steps without pausing — reflect → learn → extract-skills → kb-update → daily-report, writes output to `work/journals/YYYY-MM-DD.md` (overwrites if exists); edit the file afterward as needed.
In both cases, start executing immediately. Reserve deliberation for synthesis steps (writing summaries, identifying patterns).
</execution_style>

---

## Search Strategy (when exploring a repo)

- **Semantic search first**: use semantic/content search to understand unfamiliar code before reading files
- **Exact search for symbols**: once you know what you're looking for, use exact grep/ripgrep for precise location
- **Read only what's needed**: avoid reading entire large files — read the specific symbols or sections relevant to the task

---

## Skills — Full Reference

See the [Available commands table in README.md](README.md#available-commands) for the full list.

| Command | When to use |
|---------|------------|
| **Setup & Health** | |
| `/nase:init [name]` | First-time setup or reconfiguration |
| `/nase:doctor` | Something feels broken — check workspace health |
| `/nase:help` | Forgot a command name or want an overview |
| **Knowledge Base** | |
| `/nase:onboard <path-or-url>` | Adding a new repo to the KB (local path or GitHub URL) |
| `/nase:kb-update [domain]` | After learning something worth keeping |
| `/nase:tech-digest` | First session of the day (auto-prompted by rule above) |
| `/nase:learn [tip\|url]` | Capture a tip, web article, GitHub repo, or Confluence page → auto-extract learnings → `lessons.md` + KB |
| **Learning & Reflection** | |
| `/nase:today` | Morning kickoff — today's focus, priorities, blockers |
| `/nase:reflect [task]` | Post-task reflection — capture lessons from what just happened |
| `/nase:extract-skills` | Analyze current session → extract reusable patterns as personal skills → `work/skills/` |
| `/nase:wrap-up` | End of day — fully autonomous: reflect → learn → extract-skills → kb-update → daily-report |
| **Reporting** | |
| `/nase:daily-report` | Today's AI-assisted work summary |
| `/nase:weekly-report` | Week-in-review across all repos |
| `/nase:monthly-report` | Monthly recap (includes KB freshness audit) |
| `/nase:estimate-eta <task>` | Effort and ETA estimate for a task |
| `/nase:stats [7\|30\|all]` | Workspace usage statistics with heatmap |
| **Git Workflow** | |
| `/nase:improve-commit-message` | Rewrite last commit to conventional commits format (used in commit sequence) |
| `/nase:update-changelog [ver]` | Generate/update CHANGELOG.md from code diff between two refs |
| **Backup & Restore** | |
| `/nase:restore` | Restore `work/` from the configured backup location |

---

## Key Decisions & Architecture Notes
<!-- Format: ### YYYY-MM-DD — {topic} -->
<!-- Appended by /nase:learn or /nase:reflect when prompted -->

### 2026-03-10 — Skill usage tracking moved to UserPromptSubmit
`track-command.sh` fires on `UserPromptSubmit` and appends `{"skill":"<name>","ts":"<ISO8601>"}` to `work/stats/skill-usage.jsonl`. Replaced `PostToolUse:Skill` (`track-skill.sh`) which missed slash commands auto-injected into the conversation as `<command-name>` blocks — those bypass the Skill tool entirely, so no `PostToolUse` event fired. `UserPromptSubmit` fires on every user message, catching all `/nase:*` invocations regardless of how the skill content is loaded. Stats are surfaced by `/nase:stats`.

### 2026-03-06 — Fix backup mv failure on OneDrive
`stop-backup.sh` previously used `rm -rf $TARGET && mv $STAGING $TARGET`. OneDrive holds a handle on the directory entry even after `rm -rf`, causing `mv` to fail with "Permission denied". Fixed: keep `$TARGET` dir alive, clear its contents with `find -mindepth 1 -maxdepth 1 ! -name '.backup-lock' -exec rm -rf {} \;`, then `cp -rp $STAGING/. $TARGET/` in-place.

### 2026-03-02 — Remove rsync dependency
Backup sync (`stop-backup.sh`) and restore (`restore.md`) now use `rm -rf` + `cp -rp` instead of rsync.
rsync is unavailable on Windows without extra tooling; the new approach cleans the target first then copies,
achieving the same `--delete` semantics with standard Unix tools available in Git Bash.
