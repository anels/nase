---
name: nase:recap
description: Generate a structured recap of completed work plus actionable improvement suggestions. Use when asked to "recap", "review my work", "review progress", "summarize", "what did I do", or "show my progress" for a week or month. Prompts for period if not specified. Always ends with concrete next-period suggestions.
pattern: pipeline
sub-patterns: [fan-out]
---

**Input:** $ARGUMENTS

## Step 0 — Language preflight (MUST run first, non-negotiable)

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. If `workspace/config.md` is missing, default English and note it once at the top of the output.
Follow `.claude/docs/confidential-marker.md` — exclude `[CONFIDENTIAL]` daily-log lines from all recap inputs.
Follow `.claude/docs/citation-validator.md` — validate saved recap references before treating the recap as final.

## Step 1 — Resolve the date range

If $ARGUMENTS is blank, use the `AskUserQuestion` tool (single-select) before proceeding:

- question: "Recap which period?"
- header: "Recap Period"
- options:
  - "Last week" — Monday–Sunday of last week
  - "Last month" — 1st–last day of last month
  - "Custom range" — I'll enter the dates manually

If the user selects "Custom range", ask for the dates as a free-text follow-up: "Enter range as YYYY-MM-DD to YYYY-MM-DD". Validate dates match YYYY-MM-DD format; if invalid, re-prompt with the expected format. Accept and proceed.

If $ARGUMENTS is already provided, skip the prompt and resolve via script:

```bash
read -r START_DATE END_DATE <<< $(python3 .claude/scripts/date-resolve.py "$ARGUMENTS")
```

Supported specs: `last week`, `last month`, `this week`, `this month`, `YYYY-MM-DD to YYYY-MM-DD`. Fallback if python3 unavailable: compute manually using today's date.

Use **weekly format** for ranges ≤ 14 days; **monthly format** for ranges > 14 days.

## Steps 2–4 — Gather workspace data

Follow the shared data-gathering algorithm in `.claude/docs/workspace-data-gathering.md` with `SCOPE="range"` and the date range resolved in Step 1. Start from the compact scanner payload, then read raw source paths only when a truncated payload lacks required detail. Extract structured data (activity, tasks, lessons, KB updates, key decisions).

For long ranges or noisy logs, dispatch `nase-workspace-state-scanner` over independent date buckets or data categories in the same turn.
The main thread owns recap synthesis and file writes: merge the returned tables, apply the confidential-marker filter, validate citations, and write `workspace/recaps/` through the workspace write guard.

## Step 4.5 — Compute Stats from Logs

Follow `.claude/docs/cli-tooling.md` for optional aggregation. Probe with `python3 .claude/scripts/tool-availability.py --group data --group usage --format json`. Missing data tools are warning-only and should fall back to the grep pipeline below.

Resolve the log file list once with the helper script — emits only paths that exist (silently drops dates with no log file, avoiding grep errors on missing days):

```bash
LOG_FILES=$(python3 .claude/scripts/log-range.py "$START_DATE" "$END_DATE")
```

The helper handles cross-month ranges correctly (e.g. `2026-04-25` → `2026-05-05`) — do NOT expand the range inline; LLM expansion silently drops tail dates on multi-month spans. If `$LOG_FILES` is empty (no logs in range), skip the stats section entirely.

If the recap spans many log files or the logs are large, prefer `duckdb` to aggregate counts and top-N rows first. Use `qsv` for quick CSV sampling when that is enough; treat `mlr` / `jc` as advanced fallbacks only for formats where they clearly reduce parsing work. Feed only the aggregate table into the recap draft. Otherwise, run these greps against `$LOG_FILES`. Run all in parallel.

If `ccusage` is available, use `ccusage --json --since "$START_DATE" --until "$END_DATE"` to add a compact token/cost summary. Keep it separate from accomplishments; recap outcomes still come from logs, PRs, tasks, and KB updates.

```bash
# PRs opened via FSD (unique PR URLs)
grep -hE "^\- [0-9]{2}:[0-9]{2} \| fsd:.*https" $LOG_FILES | grep -oE "https://github[^ \)]+" | sort -u | wc -l

# Address-comments sessions
grep -hcE "^\- [0-9]{2}:[0-9]{2} \| address-comments:" $LOG_FILES | awk -F: '{s+=$NF} END{print s}'

# Prep-merge sessions
grep -hcE "^\- [0-9]{2}:[0-9]{2} \| prep-merge:" $LOG_FILES | awk -F: '{s+=$NF} END{print s}'

# PRs deep-reviewed (review: tag lines)
grep -hE "^\- [0-9]{2}:[0-9]{2} \| review:" $LOG_FILES | grep -oE "[A-Za-z-]+#[0-9]+" | sort -u | wc -l

# Unique SRE ticket IDs
grep -hE "SRE-[0-9]+" $LOG_FILES | grep -oE "SRE-[0-9]+" | sort -u | wc -l

# SRE canceled vs resolved
grep -hE "(Canceled|Resolved)" $LOG_FILES | grep "SRE-" | grep -oE "(Canceled|Resolved)" | sort | uniq -c

# Repos onboarded or refreshed
grep -hE "^\- [0-9]{2}:[0-9]{2} \| onboard:" $LOG_FILES | grep -oE "\`[A-Za-z0-9_-]+\`" | sort -u | wc -l

# /nase:learn KB infusion events
grep -hcE "^\- [0-9]{2}:[0-9]{2} \| learn:" $LOG_FILES | awk -F: '{s+=$NF} END{print s}'

# Unique commit hashes (repo-wide, incl. teammates)
cat $LOG_FILES | grep -oE "^[0-9a-f]{7,10} " | sort -u | wc -l

# Commit breakdown by type (from unique hashes)
cat $LOG_FILES | grep -oE "^[0-9a-f]{7,10} (feat|fix|refactor|ci|docs|chore|test|perf|build)\(" | sort -u | grep -oE "(feat|fix|refactor|ci|docs|chore|test|perf|build)\(" | sort | uniq -c | sort -rn
```

Store the results as variables for use in the Stats section.

For **weekly recaps** (≤ 14 days): stats are useful but lighter-weight — omit the commit type breakdown if commit counts are low (< 20 unique hashes). Include all other metrics.

## Step 5 — Generate the recap

**Output rule** — the templates below describe the **file content** written to `workspace/recaps/{period}.md`. In chat, do NOT echo the full content (very long; the file is the canonical record). Chat output:
- **Default:** Stats table + Overview paragraph + Suggestions for Next Period section only.
- **`--verbose` in $ARGUMENTS:** dump full file content inline (same as file).

This keeps chat tokens low while preserving the full record on disk.

### Weekly format (≤ 14 days)

```markdown
# Recap — Week of {Mon YYYY-MM-DD}

## Stats

| Metric | Count |
|--------|-------|
| PRs opened (via /nase:fsd) | {N} |
| PRs with comments addressed | {N} sessions |
| PRs prep-merged | {N} sessions |
| PRs deep-reviewed | {N} |
| SRE tickets handled | {N} ({canceled} canceled, {resolved} resolved) |
| Repos onboarded / refreshed | {N} |
| /nase:learn KB infusions | {N} |
| Unique commits in logs¹ | {N} |

¹ Repo-wide (includes teammates' commits). {omit type breakdown if < 20 unique commits}

## Overview
{2–3 sentences: main focus, major outcomes, notable blockers or surprises}

## Day-by-Day

### {Weekday} YYYY-MM-DD
- {one bullet per significant task/outcome; include PR/ticket links}

(omit days with zero activity entirely)

## Tasks
**Completed:** {list with ticket/PR links}
**In Progress:** {list with current status}
**Blocked:** {list with blocker reason}

## Lessons Learned
{lessons added this period, grouped by category (workflow / code / debugging / ops / infra); "none" if empty}

## KB Updates
{KB file name: what was added — one line per file; "none" if nothing}

## Key Decisions
{notable architectural, workflow, or process decisions; "none" if nothing}

## Suggestions for Next Period
{see Step 6}
```

### Monthly format (> 14 days)

```markdown
# Recap — {Month YYYY}

## Stats

| Metric | Count |
|--------|-------|
| PRs opened (via /nase:fsd) | {N} unique across {R} repos |
| PRs with comments addressed | {N} sessions · ~{U} unique PRs |
| PRs prep-merged | {N} sessions · ~{U} unique PRs |
| PRs deep-reviewed | {N} |
| SRE tickets handled | {N} unique ({canceled} canceled, {resolved} resolved) |
| Support questions handled | {N} |
| Repos onboarded / refreshed | {N} |
| /nase:learn KB infusions | {N} |
| Unique commits in logs¹ | {N} |

¹ Repo-wide (includes teammates' commits). Breakdown by type: `fix` N · `refactor` N · `ci` N · `chore` N · `docs` N · `test` N · `feat` N · `perf` N · `build` N.

## Overview
{3–4 sentences: main themes across the month, major outcomes, recurring blockers}

## Week 1 (Mon DD – Sun DD)
- {one bullet per significant task/outcome per day, or grouped by theme if dense}

## Week 2 (Mon DD – Sun DD)
...

## Week 3 / Week 4 ...
...

## Tasks
**Completed:** {list with ticket/PR links}
**In Progress:** {list with current status}
**Blocked:** {list with blocker reason}

## Lessons Learned
{grouped by category; "none" if empty}

## KB Updates
{KB file name: what was added — one line per file; "none" if nothing}

## Key Decisions
{notable decisions made this month; "none" if nothing}

## Suggestions for Next Period
{see Step 6}
```

## Step 6 — Suggestions for Next Period

This section is the forward-looking value of the recap — always generate it. 3–5 bullets, each specific enough to act on next period. Generic advice ("communicate better") is useless; name the actual task, pattern, or gap.

Draw from:
- **Blocked tasks**: what caused the block? Process gap, missing knowledge, waiting on someone?
- **Repeated lessons**: same category appearing more than once = a habit or system problem, not just bad luck
- **Deferred tasks**: if a task carried over from last period with no progress, name it and suggest a concrete unblocking action
- **KB gaps**: areas looked up repeatedly but not documented
- **Velocity imbalance**: if the period was dominated by reactive work (oncall, reviews), flag what got crowded out
- **Pain points from journals**: scan reflection sections ("What was harder than expected", "What I'd do differently") — these are direct signals of friction; suggest tooling, process, or habit fixes
- **Tech trends** (optional): if `workspace/kb/general/tech-trends.md` exists, skim it for anything directly relevant to problems encountered this period — a new tool or pattern that could reduce recurrence of a pain point. Only surface this if there's a concrete connection, not as a general "go read the digest" suggestion

```markdown
## Suggestions for Next Period

- {e.g. "Unblock #5 PROJ-1234: ping the owning team in Slack by Wed — it's been waiting 2 weeks"}
- {e.g. "Reserve 2h for #3 ADF CDC research — deferred 3 times, write even a rough draft"}
- {e.g. "Add Snowflake task failure patterns to KB — came up twice with no runbook"}
```

## Notes

- **Preserve all links** — PR URLs, Jira tickets, Confluence pages must appear verbatim.
- **Degrade gracefully** — use logs as fallback when journals are missing; skip days where both are absent.
- **No KB full-load** — only read specific KB files when needed to clarify journal content.
- **Output**: always write the full recap to `workspace/recaps/{period}.md` (e.g. `workspace/recaps/2026-W11.md` for weekly, `workspace/recaps/2026-03.md` for monthly). Ensure `workspace/recaps/` exists (create if missing). After writing, run `.claude/docs/citation-validator.md` against the saved recap file. Validate Jira ticket IDs and GitHub PR URLs; for source-file citations, validate relative to the repo that produced the claim when that repo is known. On any broken reference, gate on the validator's failure behavior before showing the recap as trusted. After validation, emit `Recap saved → workspace/recaps/{period}.md`, then follow the Step 5 chat output rule: default shows only Stats table + Overview + Suggestions; `--verbose` echoes the full file.
