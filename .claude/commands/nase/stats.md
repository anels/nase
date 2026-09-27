---
name: nase:stats
description: "Display workspace activity counts and charts inline. Use for show stats, how active am I, productivity, or 7/30/all-time activity; use /nase:recap for narrative."
argument-hint: "[7|30|week|month|all]"
category: Reporting
model: haiku
effort: low
---

**Input:** $ARGUMENTS - optional date spec accepted by `.claude/scripts/date-resolve.py`: `7` (default), `30`, `10d`, `week`, `month`, `all`, or `YYYY-MM-DD to YYYY-MM-DD`

## Steps

### 0. Language preflight (MUST run first, non-negotiable)

Follow `.claude/docs/language-config.md` → Minimum Step 0 block.

### 1. Determine time range

Parse $ARGUMENTS:
- `N`, `Nd`, or `last N days` → **last N days**
- `week` / `last week` → **previous Mon-Sun**
- `this week` → **current Monday to today**
- `month` / `last month` → **previous calendar month**
- `this month` → **first of current month to today**
- `all` → **from earliest log file date to today**
- `YYYY-MM-DD to YYYY-MM-DD` → **explicit inclusive range**
- Empty → ask using AskUserQuestion:

```
question: "What time range?"
header: "Stats Time Range"
options:
  - label: "Last 7 days"   , description: "Quick overview of the past week"
  - label: "Last 30 days"  , description: "Monthly activity summary"
  - label: "All time"       , description: "Full history from first log"
```

Anything unrecognized is still passed to the resolver; it warns and falls back to the last 7 days instead of failing.

Every Bash call starts a fresh shell, so a variable set in one fence is gone in the next. This flow spans four fences separated by an interactive gate, so it carries its state in a file that each later fence sources - the same pattern `/nase:restore` uses, with the state file under `workspace/tmp/` because nothing here rewrites `workspace/`. Resolve the dates and open that file in one call:

```bash
mkdir -p workspace/tmp
read -r START_DATE END_DATE <<< "$(python3 .claude/scripts/date-resolve.py '<spec>')"
STATS_DIR=workspace/tmp/stats-$START_DATE-$END_DATE
mkdir -p "$STATS_DIR"
printf 'START_DATE=%s\nEND_DATE=%s\nSTATS_DIR=%s\n' \
  "$START_DATE" "$END_DATE" "$STATS_DIR" > workspace/tmp/stats-state.env
```

`END_DATE` is always today. Do not use `mktemp -d` with a `trap … EXIT` here: the trap fires when its own Bash call ends, deleting the directory before the next step reads it. Step 5 removes `STATS_DIR` explicitly instead.

### 2. Scan data sources

Follow `.claude/docs/cli-tooling.md` for optional large-data aggregation. Probe with `python3 .claude/scripts/tool-availability.py --group data --group usage --format json`. Missing data tools must not block stats.

`.claude/docs/workspace-data-gathering.md` owns the collection algorithm and the confidential-session exclusions; `/nase:recap` reads the same doc over the same sources. Follow it for *what* to gather and how to exclude, and keep only the per-day CSV shaping below local to this skill.

Steps 1-3 below are a mechanical per-day sweep whose answer is a row of counts, not the file contents. For a range over 14 days delegate them to one **lookup** agent (`model=haiku`, `effort=low`, `tools=[Read, Grep, Glob, Bash]`, prompt prefixed with the `lookup` `prompt_prefix` from `.claude/roles.yaml`) and take back only the CSV path. Run them inline only for short ranges.

1. Source the state file, then collect into `$STATS_DIR`:

```bash
. workspace/tmp/stats-state.env
```

2. For each date in range:
   - **Sessions**: count entry bullets under the `## Sessions` heading of `workspace/logs/{date}.md`. Per `.claude/docs/daily-log-format.md`, a log file has exactly one `## Sessions` section and one `- {HH:MM} | {tag}: …` bullet per entry, so counting headings returns 0 or 1 per day and makes Sessions a duplicate of Active days. Count `^- [0-9][0-9]:[0-9][0-9] ` lines in that section instead.
   - **Commits**: `git -C {repo_path} log --since="{date}T00:00" --until="{date}T23:59" --oneline 2>/dev/null | wc -l`, summed across repos. Take `{repo_path}` only from `Name=path` entries in `.local-paths`; skip comment lines and skip `backup-target=`, which is a backup directory rather than a checkout.
   - **PRs**: collect PR URLs from the log, normalized to `{owner}/{repo}#{number}`. Hold the set, not a per-day count - the same PR is usually mentioned on several days, and summing per-day greps triple-counts it.
3. Write results to `$STATS_DIR/daily.csv` (format: `date,sessions,commits,prs`). The `prs` column carries first-mention-only counts, so the column sums to the size of the de-duplicated set.
4. Get skill rankings from `python3 .claude/scripts/today-stats.py --since "$START_DATE" --date "$END_DATE"`, which prints `total_invocations`, `unique_skills`, and one `skill <name> <count>` line per skill over the whole range. Every stamp in `workspace/stats/skill-usage.jsonl` is UTC, so a date-prefix match on `ts` puts an evening local session in the next day's bucket; the script buckets by local calendar day instead. Do not read the JSONL directly. `skill-usage-report.py` is the wrong tool here, because its `--window` only labels hot/cold tiers, its counts are all-time plus fixed 7d and 30d windows, and it always writes a report file this skill does not want.
5. Count knowledge entries from `workspace/tasks/lessons.md` matching the date range.
6. Count KB files touched by mtime (cross-platform): `python3 -c "import os,datetime; start=datetime.date.fromisoformat('$START_DATE'); print(sum(1 for f in __import__('glob').glob('workspace/kb/**/*.md',recursive=True) if datetime.date.fromtimestamp(os.path.getmtime(f))>=start))"` (avoids GNU-only `find -newermt` which fails on macOS). Label this as a touched-file activity signal, not proof of a durable knowledge update or read.

If the date range is large or `workspace/stats/skill-usage.jsonl` / `$STATS_DIR/daily.csv` has thousands of rows, prefer `duckdb` to aggregate before reading output into the model. Use `qsv` for quick CSV sampling when that is enough; treat `mlr` / `jc` as advanced fallbacks only for formats where they clearly reduce parsing work. Keep the model input to compact counts, top-N rows, and chart-ready CSV; never paste raw JSONL/CSV dumps into chat.

If `ccusage` is available, run it with `--json` for the same date window and include only compact coding-agent token/cost totals. Treat this as usage telemetry, not proof of completed work.

### 3. Build column chart

Delegate rendering to `.claude/scripts/stats-chart.py`. The script picks bucket granularity from the range:

- Range **≤ 14 days** → one column per **day** (weekday label).
- Range **> 14 days** → one column per **ISO week** (`W{week_number}` label), each column's value is the sum of sessions across days that fall in that week (partial first/last weeks counted only for in-range days).

```bash
. workspace/tmp/stats-state.env
CHART=$(python3 .claude/scripts/stats-chart.py \
  --daily-csv "$STATS_DIR/daily.csv" \
  --start "$START_DATE" --end "$END_DATE")
echo "$CHART"
```

`CHART` does not survive to the next fence either - read it from this call's output.

Bar fill is `█`; empty buckets show `░` under the label so silent days/weeks stay visible. Max 10 rows tall, with `0`, max, and up to two mid Y-axis labels at counts that actually appear. The script handles cross-platform date math - no need for shell date arithmetic.

Sample shape (per-day form):

```
 7 ┤        ██
 3 ┤  ██    ██    ██
 0 ┼────────────────────
      Thu  Fri  ░   Mon
       3    7   0   3
```

### 4. Print to chat (no report file)

Read AI name from `workspace/config.md` (`AI engineer:` line). Print everything inline - do NOT write a report file.

```
📊 {AI_NAME} Stats — {range label} ({START_DATE} ~ {END_DATE})

Active days: {N}/{total_days_in_range}
Sessions: {N}
Commits: {N}
PRs: {N}
Completed tasks: {N}/{completed+in_progress}
New knowledge: {N} entries
KB files touched (mtime signal): {N}

Skills (grouped by usage tier — easier to scan than a flat ranked list):
  - **Heavy** (≥50): {skill ×N | …}
  - **Steady** (10–49): {skill ×N | …}
  - **Light** (5–9): {skill ×N | …}
  - **Low** (2–4): {skill ×N | …}
  - **Rare** (1): {skill, skill, …}    ← omit ×N here; just comma-list

  Order within each tier: descending by count.
  Omit tiers that have no skills.
  If skill-usage.jsonl is empty/missing: "No data yet".
  Note: counts may undercount — PostToolUse hook doesn't fire for all invocations.

{column_chart}
```

Bar fill = `█`; empty bucket marker at row 0 = `░`. If all metrics are 0, display zeros - do not error.

### 5. Cleanup

```bash
. workspace/tmp/stats-state.env
rm -rf "$STATS_DIR" workspace/tmp/stats-state.env
```

### 6. Cross-check with `/usage` (Claude Code 2.1.149+)

The `skill-usage.jsonl` ledger records `requested`, `activated`, `tool_succeeded`, and `tool_failed` events. Rankings count `activated` events; prompt recognition and tool outcomes are diagnostic signals, not usage counts. Legacy records use the older bounded dedupe fallback. Claude Code 2.1.149+ also has `/usage` for current-window cost/token breakdowns.

If `claude --version` reports 2.1.149 or newer, append this line to the chat output:

```
Tip: run `/usage` for Claude Code's current-window breakdown (skills · subagents · plugins · per-MCP cost), especially if these numbers look off.
```

`/nase:stats` covers activity over time; `/usage` covers current limits and cost.

For a narrative summary instead of metrics, suggest `/nase:recap`.

## Notes

- **Deviates from `.claude/docs/skill-contract.md` rule 1 on purpose**: the whole output is a screenful of counts plus one chart, so a file would be a pointer to something shorter than the pointer's own summary. The chat block in Step 4 is the artifact. `/nase:recap` is the one that writes a file.
- The `Skills` tiers here (Heavy/Steady/Light/Low/Rare) are activity buckets for one range. `/nase:skill-usage` tiers the same ledger as Hot/Active/Cold/Inactive/Unused, which are lifecycle states over fixed windows. Two questions, two vocabularies - do not read one as the other.
