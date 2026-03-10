Display workspace usage statistics with a GitHub-style activity heatmap. Shows sessions, commits, PRs, skill usage rankings, and knowledge entries over 7/30/all-time windows. Use to review productivity patterns, check which skills are used most, or get a quick sense of recent activity.

**Input:** $ARGUMENTS — optional: `7` (default), `30`, or `all`

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

For `all`, find the earliest log file: `ls work/logs/????-??-??.md | sort | head -1 | xargs basename .md | sed 's/.md//'`

### 2. Scan data sources

Run all scans as a single bash script to collect per-day data into temp files for the report.

```bash
START_DATE="<start>"
END_DATE="<end>"
TMPDIR_STATS="/tmp/nase-stats-$$"
mkdir -p "$TMPDIR_STATS"
trap "rm -rf '$TMPDIR_STATS'" EXIT

# 2a. Scan log files — collect per-day data
total_sessions=0; total_commits=0; total_prs=0; active_days=0
for log_file in work/logs/????-??-??.md; do
  [ ! -f "$log_file" ] && continue
  log_date=$(basename "$log_file" .md)
  # POSIX-safe date comparison
  if [ "$log_date" \< "$START_DATE" ] || [ "$log_date" \> "$END_DATE" ]; then continue; fi

  # Sessions: count ### headers
  # NOTE: grep -c exits with code 1 when 0 matches; use || assignment to handle that.
  sessions=$(grep -c "^### " "$log_file" 2>/dev/null) || sessions=0
  [ "$sessions" -gt 0 ] && active_days=$((active_days + 1))
  total_sessions=$((total_sessions + sessions))

  # Commits: deduplicate SHAs (7+ hex chars at line start)
  commits=$(grep -oE '^[0-9a-f]{7,40}[[:space:]]' "$log_file" 2>/dev/null | sort -u | wc -l | tr -d ' ')
  commits=${commits:-0}
  total_commits=$((total_commits + commits))

  # PRs: unique github.com pull URLs
  prs=$(grep -oE 'github\.com/[^/]+/[^/]+/pull/[0-9]+' "$log_file" 2>/dev/null | sort -u | wc -l | tr -d ' ')
  prs=${prs:-0}
  total_prs=$((total_prs + prs))

  # Store per-day stats (csv: date,sessions,commits,prs)
  echo "$log_date,$sessions,$commits,$prs" >> "$TMPDIR_STATS/daily.csv"
done

# 2b. Tasks (current totals, not date-filtered)
completed_tasks=$(grep -c "^- \[x\]" work/tasks/todo.md 2>/dev/null) || completed_tasks=0
in_progress_tasks=$(grep -c "^- \[ \]" work/tasks/todo.md 2>/dev/null) || in_progress_tasks=0

# 2c. Knowledge entries — grep finds UTF-8 em-dash lines, awk filters by date
# Note: awk character classes don't match UTF-8 multibyte chars reliably in MINGW.
# Use grep for pattern matching, awk for date range filtering.
knowledge_entries=0
if [ -f "work/tasks/lessons.md" ]; then
  knowledge_entries=$(grep -E '^## [a-zA-Z]+ — [0-9]{4}-[0-9]{2}-[0-9]{2}' work/tasks/lessons.md 2>/dev/null \
    | awk -v start="$START_DATE" -v end="$END_DATE" '
      { d = $NF; if (d >= start && d <= end) count++ }
      END { print count+0 }
    ')
fi

# 2d. KB file updates by mtime
kb_updates=0
if [ -d "work/kb/" ]; then
  next_day=$(date -d "$END_DATE + 1 day" +%Y-%m-%d)
  kb_updates=$(find work/kb/ -name '*.md' -type f -newermt "$START_DATE" ! -newermt "$next_day" 2>/dev/null | wc -l | tr -d ' ')
fi

# 2e. Skill usage from JSONL
skill_top=""
if [ -f "work/stats/skill-usage.jsonl" ]; then
  skill_top=$(awk -v start="$START_DATE" -v end="$END_DATE" '
    {
      match($0, /"skill":"([^"]*)"/, sa); skill = sa[1]
      match($0, /"ts":"([^"]*)"/, ta);  ts = ta[1]
      d = substr(ts, 1, 10)
      if (d >= start && d <= end) counts[skill]++
    }
    END { for (s in counts) print counts[s] " " s }
  ' work/stats/skill-usage.jsonl | sort -rn | head -3)
fi

# Write env for reuse
cat > "$TMPDIR_STATS/env.sh" << ENV_EOF
TOTAL_SESSIONS=$total_sessions
TOTAL_COMMITS=$total_commits
TOTAL_PRS=$total_prs
ACTIVE_DAYS=$active_days
COMPLETED_TASKS=$completed_tasks
IN_PROGRESS_TASKS=$in_progress_tasks
KNOWLEDGE_ENTRIES=$knowledge_entries
KB_UPDATES=$kb_updates
ENV_EOF
```

Save `$TMPDIR_STATS` path for use in steps 3–5.

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

To generate in bash, iterate dates with `date -d "$START_DATE + N days" +%Y-%m-%d` until END_DATE. Use `awk` to look up sessions per date in the CSV.

### 4. Output chat summary

Read AI name from `work/config.md` (`AI engineer:` line).

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

Top Skills:
  {skill1} ×{N}  |  {skill2} ×{N}  |  {skill3} ×{N}
  (or "No data yet" if skill-usage.jsonl is empty/missing)

{heatmap}
░ = 0  ▒ = 1  ▓ = 2  █ = 3+
```

If all metrics are 0, display with zeros — do not error.

### 5. Write detailed report

Write to `work/stats/report-YYYY-MM-DD.md` (today's date; overwrite if exists).

Generate the daily breakdown table **dynamically** from `$TMPDIR_STATS/daily.csv`:

```bash
source "$TMPDIR_STATS/env.sh"
GEN_TS=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
REPORT_DATE=$(date +%Y-%m-%d)
report_file="work/stats/report-$REPORT_DATE.md"

# Build daily breakdown table by iterating the date range
# Read CSV into awk lookup, then iterate dates
daily_table=$(
  current="$START_DATE"
  while [ "$current" \<= "$END_DATE" ]; do
    day_name=$(date -d "$current" +%a)
    # Look up stats in CSV for this date
    row=$(grep "^$current," "$TMPDIR_STATS/daily.csv" 2>/dev/null)
    if [ -n "$row" ]; then
      IFS=',' read -r _ s c p <<< "$row"
    else
      s=0; c=0; p=0
    fi
    echo "| $current | $day_name | $s | $c | $p | — |"
    current=$(date -d "$current + 1 day" +%Y-%m-%d)
  done
)
```

Knowledge entries: list each entry title + category from `work/tasks/lessons.md` matching the date range (same awk filter as step 2c, but also capture the `**Tip:**` line for the title).

Report content:
- Summary table (same metrics as chat summary)
- Daily breakdown table (dynamically generated — not hardcoded)
- Knowledge entries list (title + category + date)
- Skill usage full ranking (all skills from JSONL, not just top 3)
- Generation metadata: `Generated: {GEN_TS}`, `Range: {START_DATE} ~ {END_DATE}`, `Period: {N} days`

The EXIT trap set in step 2 cleans up `$TMPDIR_STATS` automatically.
