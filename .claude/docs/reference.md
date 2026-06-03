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
    track-skill.sh   ← runs at PostToolUse (Skill): records /nase:* invocations to
                       workspace/stats/skill-usage.jsonl for /nase:stats reporting; same-second
                       dedup in script prevents double-counting
    track-skill-prompt.sh ← runs at UserPromptSubmit: records slash-command invocations
                       that bypass PostToolUse:Skill
    worktree-log.sh  ← runs at WorktreeRemove: appends timestamped removal entry to
                       today's daily log
    slack-send-guard.sh ← blocks direct Slack sends; use drafts
    jira-write-guard.sh ← token-gates Jira mutation tools
    confluence-size-guard.sh ← blocks oversized Confluence page writes
    edit-typecheck.sh ← (opt-in) runs at PostToolUse:Edit for .cs/.ts/.tsx files:
                       looks up repo in workspace/tmp/.typecheck-commands, runs quick
                       type-check (e.g. dotnet build --no-restore). 30s timeout.
                       Disabled by default — enable via /update-config.
  settings.json      ← hook registrations (SessionStart + Stop + UserPromptSubmit + PreToolUse + PostToolUse + WorktreeRemove)
.local-paths         ← machine-specific paths: backup-target + repo local paths (key=/path format)
                       lives at workspace root (NOT inside workspace/); managed by /nase:init
workspace/               ← entirely git-ignored; never committed
  config.md          ← format: AI engineer: <name> / workspace: <folder-name> / backup_retention: <policy> / ## Language (conversation + output)  (managed by /nase:init)
  journals/          ← end-of-day wrap-up files (written by /nase:wrap-up, one per day)
  scripts/           ← utility scripts (e.g. deploy-uptime-kuma.ps1, stats-collect.sh)
```

---

## Knowledge Base Structure

```
workspace/                   ← entirely git-ignored; never committed
  context.md              ← repo list + domain patterns
  tech-digest-config.md   ← personal sources + filter topics + output sections for /nase:tech-digest
  kb/
    .domain-map.md        ← project-domain → kb file mappings (managed by /nase:onboard)
    projects/
      <your-repo>.md           ← one file per repo (created by /nase:onboard)
      tech-debt/               ← tech debt audit reports (created by /nase:tech-debt-audit)
      decisions/               ← PR decisions & incident logs
    general/
      workflow.md              ← protocols, coding principles, PR rules
      debugging.md             ← debugging techniques, past root causes
      <your-stack>.md          ← general patterns for your primary stack (e.g. dotnet.md, spark-scala.md)
      tech-trends.md           ← rolling 30-day tech digest (auto-managed by /nase:tech-digest)
      tech-trends-archive-YYYY.md ← entries older than 30 days (auto-archived)
    cross-project/
      <topic>.md               ← work-related knowledge not tied to a single repo
    ops/
      <deployment-type>.md     ← ops runbooks by deployment type (see workspace/kb/.domain-map.md for known types)
  skills/
    {name}.md             ← auto-extracted reusable patterns (written by /nase:extract-skills; gitignored)
  efforts/
    {slug}.md             ← design docs with lifecycle tracking (written by /nase:design)
    done/                 ← completed/closed efforts (auto-moved by /nase:today status sync)
  tasks/
    lessons.md            ← accumulated lessons from /nase:learn and /nase:reflect
    todo.md               ← current task tracking
  journals/
    YYYY-MM-DD.md         ← end-of-day wrap-up output (written by /nase:wrap-up)
  stats/
    skill-usage.jsonl     ← append-only JSONL: {skill, ts} per /nase:* invocation (auto-written by hook)
    skill-usage-YYYY-MM-DD.md ← detailed skill usage report (written by /nase:skill-usage)
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
- **One-pass** (wrap-up): runs non-Jira/non-style-delta-gate steps without pausing — reflect → learn → extract-skills → kb-update → style-delta → journal entry, writes output to `workspace/journals/YYYY-MM-DD.md` (overwrites if exists); edit the file afterward as needed.
In both cases, start executing immediately. Reserve deliberation for synthesis steps (writing summaries, identifying patterns).

**Concurrency rule**: independent sub-tasks MUST be dispatched in a single message with multiple Agent/tool calls — never serialized. Sequential execution is only valid when step B's input depends on step A's output.
</execution_style>

---

## Search Strategy (when exploring a repo)

- **Semantic search first**: use semantic/content search to understand unfamiliar code before reading files
- **Exact search for symbols**: once you know what you're looking for, use exact grep/ripgrep for precise location
- **Read only what's needed**: avoid reading entire large files — read the specific symbols or sections relevant to the task

---

## Shared Docs (`.claude/docs/`)

| Doc | Purpose |
|-----|---------|
| `build-test-loop.md` | Build → test → fix loop used by `fsd`, `address-comments`, `prep-merge` |
| `citation-validator.md` | Validate Jira, GitHub, Confluence, and source-file references before report-like skills mark saved artifacts as trusted |
| `cli-tooling.md` | Optional CLI tool selection, availability probing, install mapping, and skill integration rules |
| `closing-block.md` | TLDR + tint closing block for `today` / `wrap-up` outputs |
| `confidential-marker.md` | `[CONFIDENTIAL]` routing tag rules so sensitive daily-log lines stay out of KB, recap, export, and report flows |
| `commit-push-pattern.md` | Stage → secrets scan → commit → improve → push sequence |
| `confluence-adf-pattern.md` | Confluence page update rules: full body requirement, `inlineCard` for Jira links, `hardBreak`, draft pages, content preservation |
| `content-hash-cache.md` | SHA-based change detection to skip unchanged content while periodically re-analyzing stale cache entries (used by `onboard`, `tech-digest`) |
| `codex-review.md` | Optional Codex MCP contract for read-only second-opinion review, verification, tech-debt, and mutual-grill passes |
| `cross-repo-validation.md` | Cross-repo outbound/inbound contract validation algorithm used by `onboard` Step 6 |
| `daily-log-format.md` | Standardized log entry format and canonical skill tags |
| `external-mutation-policy.md` | Cross-skill rule: every Slack / Jira / Confluence / GitHub / ADO / cloud mutation goes through draft-first or `AskUserQuestion`. Reference from any mutation-capable skill. |
| `skill-authoring-contract.md` | Behavior rules for skill authors: language preflight, external mutation, ADO CLI doctrine, bash hygiene, anti-overlap, subagent context. Read before adding a new skill. Enforced by `tests/check-skill-doctrine.sh`. |
| `style-delta-capture.md` | Capture user corrections to drafted Slack/PR/external-doc text as `[STYLE-DELTA]` log lines and consolidate them into approved `communication-style.md` edits during `wrap-up` |
| `design-auto-mode.md` | Algorithm for `--auto` end-to-end design mode of `/nase:design` |
| `design-grill-mode.md` | Algorithm for `--grill` stress-test mode of `/nase:design` |
| `design-review-mode.md` | Algorithm for `--review` re-evaluation mode of `/nase:design` |
| `fsd-phase-decomposition.md` | Full "Direct with Phase isolation" algorithm for `fsd` Phase 3.7 — complexity precheck, state file format, subagent prompt template, TDD gate block |
| `fsd-pre-impl-greps.md` | Pre-implementation grep checks for `fsd` Phase 3 (lint config, similar functions, test patterns) |
| `github-queries.md` | Shared GraphQL queries for PR data (reviews, comments, checks) |
| `jira-lifecycle.md` | Jira MCP patterns: cloudId resolution, fetch/search/transition, confirmation rules, graceful degradation |
| `azure-pipeline-kb-extract.md` | Azure Pipeline YAML capture rules + KB-write spec (Step 4.5) used by `onboard` Steps 3d/4.5 |
| `kb-relationship-graph.md` | Cross-file relationship graph algorithm + output shape (hubs, orphans, clusters, missing reciprocal links) used by `kb-review` Step 3b |
| `kb-teamshare-file-processing.md` | File processing pipeline for `kb-teamshare` Step 4 — path stripping (4a), internal link rewriting (4b), privacy classification (4c), output language translation (4d) |
| `kb-template.md` | Template + Writing Conventions for new repo KB files (used by `onboard`, `learn`, `kb-update`, `kb-review`) |
| `language-config.md` | Canonical algorithm for loading conversation vs output language |
| `ms-learn-grounding.md` | Read-only verification of Azure / .NET / Microsoft SDK claims via the `ms-learn` MCP server. Used by `onboard` Step 3j; conditional on a Microsoft-stack trigger. |
| `lessons-format.md` | Canonical format for `workspace/tasks/lessons.md` entries (header, body, signal-to-noise rules) |
| `pr-creation-pattern.md` | PR template discovery, description drafting, title rules |
| `pr-input-guard.md` | Input validation for skills that take a PR URL |
| `pr-review-verification.md` | Five-check verification list for PR review skills (AI-reviewer audit, cross-ref, diff-vs-HEAD) |
| `reference.md` | This file — workspace layout, KB structure, architecture notes |
| `repo-resolution.md` | Resolve GitHub URLs / repo names to local paths via `.local-paths` |
| `slack-draft-style.md` | Style checklist for Slack drafts: no greetings, bullets for tech content, English-only in public/non-CN DMs, `pls` over `please`; references `workspace/communication-style.md` for full profile |
| `verification-matrix.md` | Verification evidence matrix used by `fsd` and `discuss-pr` to declare task done |
| `workspace-data-gathering.md` | Load journals/logs/tasks within a date range (used by `recap`, `wrap-up`) |
| `worktree-pattern.md` | Safe worktree creation with `EnterWorktree` avoidance |
| `workspace-runtime-config.md` | Runtime config registry rules for org/project/page/model/tool names used by workspace skills |
| `workspace-write-guard.md` | Staging, diff, and mtime/hash guard for durable workspace writes |

---

## Utility Scripts (`.claude/scripts/`)

| Script | Purpose |
|--------|---------|
| `date-resolve.py` | Parse natural-language date specs (e.g. "last week", "30", "YYYY-MM-DD to YYYY-MM-DD") to a `START_DATE END_DATE` pair. Used by `recap`, `stats`. |
| `help-summary.py` | Render compact or verbose `/nase:help` output from README.md and workspace directories. Used by `help`. |
| `kb-domain-resolve.sh` | Resolve a repo name / domain key to its KB file path via `workspace/kb/.domain-map.md`. Used by `repo-resolution.md` callers. |
| `kb-search.sh` | Full-text + metadata search across KB files. Supports `in:`, `tag:`, `since:`, `confidence:`, `mentions:`, capped previews, `--full`, and `--max-entry-lines`; weighted relevance (header 2×, body 1×); fuzzy fallback. Used by `kb-search`. |
| `kb-gap-scan.sh` | Scan daily logs and lessons for KB-gap signals (uncertainty, doc lookups, SME teachings). Used by `kb-gap-detect`. |
| `kb-hygiene-scan.py` | Scan project KB files for stale timestamps, unsafe stale claims, broken repo-source references, and compaction candidates. Used by `onboard`. |
| `today-stats.py` | Emit a single date's session, token, and skill-usage counts as `key=value` lines. Used by `wrap-up` Step 4d. |
| `log-range.py` | Emit existing daily-log file paths for a date range (inclusive). Silently drops non-existent dates. Used by `recap` Step 4.5. |
| `stats-chart.py` | Render vertical ASCII column chart from `daily.csv`. Auto-picks per-day buckets (≤14 days) or per-week buckets (>14 days). Used by `stats` Step 3. |
| `tool-availability.py` | Probe optional CLI tools by group and emit table, JSON, or Homebrew install command. Used by `doctor` and optional tooling-aware skills. |

---

## Skills — Full Reference

See the [Available commands table in README.md](../../README.md#available-commands) for the full list of `/nase:*` commands with descriptions.

---

## Key Decisions & Architecture Notes
<!-- Format: ### YYYY-MM-DD — {topic} -->
<!-- Appended by /nase:learn or /nase:reflect when prompted -->

### 2026-03-12 — Skill usage tracking restored to PostToolUse (track-skill.sh)
`track-skill.sh` fires on `PostToolUse:Skill` and appends `{"skill":"<name>","ts":"<ISO8601>"}` to `workspace/stats/skill-usage.jsonl`. The previous attempt to use `UserPromptSubmit` (`track-command.sh`) was reverted because it could not reliably detect the exact skill name invoked — regex parsing of user messages is fragile. PostToolUse provides the exact Skill tool call input, which is the authoritative source for `/nase:*` invocations. Stats are surfaced by `/nase:stats`.

### 2026-03-19 — Zip-based backup with retention
`stop-backup.sh` creates timestamped zip archives (`nase-backup-YYYYMMDD-HHMMSS.zip`) via `7z a -tzip` (`scoop install 7zip`). Retention policy (`count:N` or `days:N`) from `backup_retention:` in `workspace/config.md` (default: `count:100`). Old flat-copy backups are auto-migrated on first run. Restore (`restore.md`) lists available zip backups and extracts with `unzip`. Supersedes earlier flat-copy and rsync approaches.
