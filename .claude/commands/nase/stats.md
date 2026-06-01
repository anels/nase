---
name: nase:stats
description: Display workspace usage statistics inline (no report file) — vertical column chart (per-day ≤14d, per-week >14d), tiered skill usage, and summary counters. For a structured narrative recap of completed work, use /nase:recap instead. Use when asked "show stats", "how active am I", "productivity", "how much have I done", or to review activity patterns over 7/30/all-time windows.
---

**Input:** $ARGUMENTS — optional date spec accepted by `.claude/scripts/date-resolve.py`: `7` (default), `30`, `10d`, `week`, `month`, `all`, or `YYYY-MM-DD to YYYY-MM-DD`

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
- Contains `--from-skill` (called from another skill like wrap-up) → **last 7 days** (non-interactive default)
- Empty → ask using AskUserQuestion:

```
question: "What time range?"
header: "Stats Time Range"
options:
  - label: "Last 7 days"   , description: "Quick overview of the past week"
  - label: "Last 30 days"  , description: "Monthly activity summary"
  - label: "All time"       , description: "Full history from first log"
```

Anything unrecognized is still passed to the resolver; it warns and falls back to the last 7 days instead of failing. Once the spec is known, resolve dates via script:

```bash
read -r START_DATE END_DATE <<< $(python3 .claude/scripts/date-resolve.py "<spec>")
```

Fallback if python3 unavailable: compute manually. `END_DATE` is always today.

### 2. Scan data sources

Check if `workspace/scripts/stats-collect.sh` exists. If it does, run it:

```bash
bash workspace/scripts/stats-collect.sh "<start>" "<end>"
```

This script prints the path to a temp directory on stdout. Capture it and clean up after use:

```bash
TMPDIR_STATS=$(bash workspace/scripts/stats-collect.sh "<start>" "<end>")
trap 'rm -rf "$TMPDIR_STATS"' EXIT
```

It collects:
- Per-day stats (sessions, commits, PRs) → `$TMPDIR_STATS/daily.csv`
- Aggregate metrics → `$TMPDIR_STATS/env.sh`
- Skill usage rankings

<!-- Consider extracting to workspace/scripts/stats-collect.sh if this grows -->
**If the script does NOT exist**, collect data inline:
1. Create a temp directory: `TMPDIR_STATS=$(mktemp -d)` and register cleanup: `trap 'rm -rf "$TMPDIR_STATS"' EXIT` (ensures cleanup even if the skill errors mid-execution)
2. For each date in range, count sessions from `workspace/logs/{date}.md` (count `## Session` headers), commits across all repos in `.local-paths` (for each `{repo_path}` in `.local-paths`: `git -C {repo_path} log --since="{date}T00:00" --until="{date}T23:59" --oneline 2>/dev/null | wc -l` — sum across all repos), and PRs (grep for PR URLs in the log).
3. Write results to `$TMPDIR_STATS/daily.csv` (format: `date,sessions,commits,prs`).
4. Read `workspace/stats/skill-usage.jsonl` for skill rankings (if exists).
5. Count knowledge entries from `workspace/tasks/lessons.md` matching the date range.
6. Count KB files modified (cross-platform): `python3 -c "import os,datetime; start=datetime.date.fromisoformat('$START_DATE'); print(sum(1 for f in __import__('glob').glob('workspace/kb/**/*.md',recursive=True) if datetime.date.fromtimestamp(os.path.getmtime(f))>=start))"` (avoids GNU-only `find -newermt` which fails on macOS).

### 3. Build column chart

Delegate rendering to `.claude/scripts/stats-chart.py`. The script picks bucket granularity from the range:

- Range **≤ 14 days** → one column per **day** (weekday label).
- Range **> 14 days** → one column per **ISO week** (`W{week_number}` label), each column's value is the sum of sessions across days that fall in that week (partial first/last weeks counted only for in-range days).

```bash
CHART=$(python3 .claude/scripts/stats-chart.py \
  --daily-csv "$TMPDIR_STATS/daily.csv" \
  --start "$START_DATE" --end "$END_DATE")
```

Bar fill is `█`; empty buckets show `░` under the label so silent days/weeks stay visible. Max 10 rows tall, with `0`, max, and up to two mid Y-axis labels at counts that actually appear. The script handles cross-platform date math — no need for shell date arithmetic.

Sample outputs (7-day per-day vs 30-day per-week):

```
23 ┤              ██
   │              ██
   │              ██
 7 ┤        ██    ██
   │        ██    ██
 3 ┤  ██    ██    ██    ██    ██
 0 ┼────────────────────────────
      Thu  Fri  ░   ░   Mon Tue Wed
       3    7   0   0   23  1   3
```

```
78 ┤  ██
   │  ██
51 ┤  ██        ██
46 ┤  ██  ██    ██
37 ┤  ██  ██    ██  ██  ██
 0 ┼────────────────────
      W17 W18 W19 W20 W21
      78  46  51  37  36
```

### 4. Print to chat (no report file)

Read AI name from `workspace/config.md` (`AI engineer:` line). Print everything inline — do NOT write a report file.

```
📊 {AI_NAME} Stats — {range label} ({START_DATE} ~ {END_DATE})

Active days: {N}/{total_days_in_range}
Sessions: {N}
Commits: {N}
PRs: {N}
Completed tasks: {N}/{completed+in_progress}
New knowledge: {N} entries
KB updates: {N} files

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

Bar fill = `█`; empty bucket marker at row 0 = `░`. If all metrics are 0, display zeros — do not error.

### 5. Cleanup

```bash
rm -rf "$TMPDIR_STATS"
```

### 6. Cross-check with `/usage` (Claude Code 2.1.149+)

The `skill-usage.jsonl` ledger is populated by `PostToolUse:Skill` (`track-skill.sh`) and `UserPromptSubmit` (`track-skill-prompt.sh`). Prompt/tool pairs for the same skill are deduped within a short window; unusual invocation paths may still be missed. Claude Code 2.1.149+ also has `/usage` for current-window cost/token breakdowns.

If `claude --version` reports 2.1.149 or newer, append this line to the chat output:

```
Tip: run `/usage` for Claude Code's current-window breakdown (skills · subagents · plugins · per-MCP cost), especially if these numbers look off.
```

`/nase:stats` covers activity over time; `/usage` covers current limits and cost.

For a narrative summary instead of metrics, suggest `/nase:recap`.
