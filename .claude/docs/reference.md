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
                       surfaces backup warnings, suggests /nase:reflect when commits exist
    stop-todos.sh    ← runs at Stop (before backup): surfaces pending todos from workspace/tasks/todo.md
    stop-backup.sh   ← runs at Stop: appends commit summary to daily log, creates timestamped
                       zip backup of workspace/ (via 7z), applies retention cleanup, warns if notes missing
    track-skill.sh   ← runs at PreToolUse + PostToolUse (Skill): records /nase:* invocations to
                       workspace/stats/skill-usage.jsonl for /nase:stats reporting; dual-hook for
                       better coverage (PostToolUse alone misses some invocations); same-second
                       dedup in script prevents double-counting
    worktree-log.sh  ← runs at WorktreeCreate/WorktreeRemove: appends timestamped
                       entry to today's daily log
  settings.json      ← hook registrations (SessionStart + Stop + PostToolUse + WorktreeCreate/Remove)
.backup-target       ← single line, bash-format path (e.g. /c/Users/me/OneDrive/backup/nase-backup)
                       lives at workspace root (NOT inside workspace/); managed by /nase:init
workspace/               ← entirely git-ignored; never committed
  config.md          ← format: AI engineer: <name> / workspace: <folder-name> / backup_retention: <policy>  (managed by /nase:init)
  journals/          ← end-of-day wrap-up files (written by /nase:wrap-up, one per day)
  scripts/           ← utility scripts (e.g. deploy-uptime-kuma.ps1, stats-collect.sh)
```

---

## Knowledge Base Structure

```
workspace/                   ← entirely git-ignored; never committed
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
    ops/
      <deployment-type>.md     ← ops runbooks by deployment type (see workspace/kb/.domain-map.md for known types)
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
- **Data gathering** (doctor, stats): collect all data first, then present — execute deterministically.
- **Interactive** (kb-update, onboard): gather context automatically, then pause at marked checkpoints for user input.
- **Autonomous** (wrap-up): runs all steps without pausing — reflect → learn → extract-skills → kb-update → journal entry, writes output to `workspace/journals/YYYY-MM-DD.md` (overwrites if exists); edit the file afterward as needed.
In both cases, start executing immediately. Reserve deliberation for synthesis steps (writing summaries, identifying patterns).
</execution_style>

---

## Search Strategy (when exploring a repo)

- **Semantic search first**: use semantic/content search to understand unfamiliar code before reading files
- **Exact search for symbols**: once you know what you're looking for, use exact grep/ripgrep for precise location
- **Read only what's needed**: avoid reading entire large files — read the specific symbols or sections relevant to the task

---

## Skills — Full Reference

See the [Available commands table in README.md](README.md#available-commands) for the full list of `/nase:*` commands with descriptions.

---

## Key Decisions & Architecture Notes
<!-- Format: ### YYYY-MM-DD — {topic} -->
<!-- Appended by /nase:learn or /nase:reflect when prompted -->

### 2026-03-12 — Skill usage tracking restored to PostToolUse (track-skill.sh)
`track-skill.sh` fires on `PostToolUse:Skill` and appends `{"skill":"<name>","ts":"<ISO8601>"}` to `workspace/stats/skill-usage.jsonl`. The previous attempt to use `UserPromptSubmit` (`track-command.sh`) was reverted because it could not reliably detect the exact skill name invoked — regex parsing of user messages is fragile. PostToolUse provides the exact Skill tool call input, which is the authoritative source for `/nase:*` invocations. Stats are surfaced by `/nase:stats`.

### 2026-03-19 — Zip-based backup with retention
`stop-backup.sh` creates timestamped zip archives (`nase-backup-YYYYMMDD-HHMMSS.zip`) via `7z a -tzip` (`scoop install 7zip`). Retention policy (`count:N` or `days:N`) from `backup_retention:` in `workspace/config.md` (default: `count:100`). Old flat-copy backups are auto-migrated on first run. Restore (`restore.md`) lists available zip backups and extracts with `unzip`. Supersedes earlier flat-copy and rsync approaches.
