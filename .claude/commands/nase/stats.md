---
name: nase:stats
description: Display workspace usage statistics with a GitHub-style activity heatmap. Use when asked "show stats", "how active am I", "productivity", "how much have I done", or to review activity patterns over 7/30/all-time windows.
---

**Input:** $ARGUMENTS — optional: `7` (default), `30`, or `all`

## Setup

Use `ToolSearch` to fetch `AskUserQuestion` before starting — it's a deferred tool used in Step 1 if the time range is not specified via $ARGUMENTS. Fetch it once here so it's available when needed.

## Steps

### 1. Determine time range

Parse $ARGUMENTS:
- `7` or `7d` or empty in non-interactive context → **last 7 days**
- `30` or `30d` → **last 30 days**
- `all` → **from earliest log file date to today**
- Anything else or empty → ask using AskUserQuestion:

```
question: "What time range?"
header: "Stats Time Range"
options:
  - label: "Last 7 days"   , description: "Quick overview of the past week"
  - label: "Last 30 days"  , description: "Monthly activity summary"
  - label: "All time"       , description: "Full history from first log"
```

Calculate `START_DATE` and `END_DATE` based on selection. `END_DATE` is always today.

For `all`, find the earliest log file: `ls workspace/logs/????-??-??.md 2>/dev/null | sort | head -1 | sed 's|.*/||; s|\.md$||'`

### 2. Scan data sources

Check if `workspace/scripts/stats-collect.sh` exists. If it does, run it:

```bash
bash workspace/scripts/stats-collect.sh "<start>" "<end>"
```

This script outputs all metrics to `$TMPDIR_STATS` (a temp directory — caller must clean up after use). It collects:
- Per-day stats (sessions, commits, PRs) → `$TMPDIR_STATS/daily.csv`
- Aggregate metrics → `$TMPDIR_STATS/env.sh`
- Skill usage rankings

Save `$TMPDIR_STATS` path for use in steps 3–5.

<!-- Consider extracting to workspace/scripts/stats-collect.sh if this grows -->
**If the script does NOT exist**, collect data inline:
1. Create a temp directory: `TMPDIR_STATS=$(mktemp -d)`
2. For each date in range, count sessions from `workspace/logs/{date}.md` (count `## Session` headers), commits across all repos in `.local-paths` (`git log --since="{date}T00:00" --until="{date}T23:59" --oneline | wc -l`), and PRs (grep for PR URLs in the log).
3. Write results to `$TMPDIR_STATS/daily.csv` (format: `date,sessions,commits,prs`).
4. Read `workspace/stats/skill-usage.jsonl` for skill rankings (if exists).
5. Count knowledge entries from `workspace/tasks/lessons.md` matching the date range.
6. Count KB files modified: `find workspace/kb -name "*.md" -newer` (approximate).

### 3. Build heatmap

Use the per-day session data from `$TMPDIR_STATS/daily.csv`. Read it into a lookup map by date, then iterate through all days in range.

Density characters (Unicode block chars — preferred):
- `░` = 0 sessions
- `▒` = 1 session
- `▓` = 2 sessions
- `█` = 3+ sessions

If the terminal or environment doesn't render Unicode block characters correctly (they appear as `?` or boxes), fall back to ASCII: `.` = 0, `+` = 1, `o` = 2, `#` = 3+. Update the legend accordingly.

**7-day format** — single column with a proportional bar (max 8 `█` characters, scaled to the highest session count in the range):

```
  Mon 03  █ ████████  (3)
  Tue 04  ▓ █████     (2)
  Wed 05  ▒ ██        (1)
  Thu 06  ░           (0)
  Fri 07  █ ████████  (3)
  Sat 08  ░           (0)
  Sun 09  ▒ ██        (1)
```

Bar length = `round(sessions / max_sessions * 8)`. If max_sessions is 0, all bars are empty.

**30-day / all format** — weekly rows, GitHub-style grid:

```
       W09  W10  W11  W12  W13
  Mon   ▒    █    ░    ▓    ▒
  Tue   █    ▓    ▒    ░    █
  Wed   ▓    ░    █    ▒    ▓
  Thu   ░    ▒    ▓    █    ░
  Fri   █    █    ░    ▒    ▓
  Sat   ░    ░    ░    ░    ░
  Sun   ░    ░    ░    ░    ░
```

Include legend: `░ = 0  ▒ = 1  ▓ = 2  █ = 3+`

Days with no log file are treated as 0 sessions (░).

To iterate dates cross-platform (macOS and Linux), use Python3 — already listed as a runtime dependency:

```shell
python3 -c "
import datetime
d = datetime.date.fromisoformat('$START_DATE')
end = datetime.date.fromisoformat('$END_DATE')
while d <= end:
    print(d.isoformat())
    d += datetime.timedelta(days=1)
" | while read -r current_date; do
    # look up sessions for current_date in daily.csv via awk
    :
done
```

### 4. Output chat summary

Read AI name from `workspace/config.md` (`AI engineer:` line).

Display in chat (≤25 lines):

```
📊 {AI_NAME} Stats — {range label} ({START_DATE} ~ {END_DATE})

Active days: {N}/{total_days_in_range}
Sessions: {N}
Commits: {N}
PRs: {N}
Completed tasks: {N}/{completed+in_progress}
New knowledge: {N} entries
KB updates: {N} files

Skills (ranked by usage):
  {skill1} ×{N}  |  {skill2} ×{N}  |  {skill3} ×{N}  |  ...
  Show ALL skills from the JSONL, ordered by invocation count (descending).
  Format as pipe-separated on one or more lines (wrap if needed).
  If skill-usage.jsonl is empty/missing: "No data yet"
  Note: counts may undercount — PostToolUse hook doesn't fire for all invocations.

{heatmap}
░ = 0  ▒ = 1  ▓ = 2  █ = 3+
```

If all metrics are 0, display with zeros — do not error.

### 5. Write detailed report

Write to `workspace/stats/report-YYYY-MM-DD.md` (today's date; overwrite if exists).

Generate the daily breakdown table **dynamically** from `$TMPDIR_STATS/daily.csv`:

```bash
source "$TMPDIR_STATS/env.sh"
GEN_TS=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
REPORT_DATE=$(date +%Y-%m-%d)
report_file="workspace/stats/report-$REPORT_DATE.md"

# Build daily breakdown table by iterating the date range
# Read CSV into awk lookup, then iterate dates
daily_table=$(
  current="$START_DATE"
  while [[ ! "$current" > "$END_DATE" ]]; do
    day_name=$(python3 -c "import datetime; print(datetime.date.fromisoformat('$current').strftime('%a'))")
    # Look up stats in CSV for this date
    row=$(grep "^$current," "$TMPDIR_STATS/daily.csv" 2>/dev/null)
    if [ -n "$row" ]; then
      IFS=',' read -r _ s c p <<< "$row"
    else
      s=0; c=0; p=0
    fi
    echo "| $current | $day_name | $s | $c | $p | — |"
    current=$(python3 -c "import datetime; d=datetime.date.fromisoformat('$current'); print((d+datetime.timedelta(days=1)).isoformat())")
  done
)
```

Knowledge entries: list each entry title + category from `workspace/tasks/lessons.md` matching the date range (same awk filter as step 2c, but also capture the `**Tip:**` line for the title).

Report content:
- Summary table (same metrics as chat summary)
- Daily breakdown table (dynamically generated — not hardcoded)
- Knowledge entries list (title + category + date)
- Skill usage full ranking (all skills from JSONL, not just top 3)
- Generation metadata: `Generated: {GEN_TS}`, `Range: {START_DATE} ~ {END_DATE}`, `Period: {N} days`

Clean up the temp directory after writing the report: `rm -rf "$TMPDIR_STATS"`.

For a narrative summary instead of metrics, suggest `/nase:recap`.
