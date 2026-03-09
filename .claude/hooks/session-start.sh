#!/usr/bin/env bash
set -euo pipefail

WORKSPACE=$(git rev-parse --show-toplevel 2>/dev/null) || true
if [ -z "$WORKSPACE" ]; then
  echo "[session-start] ERROR: not in a git repo — cannot determine workspace" >&2
  exit 1
fi

DATE=$(date +%Y-%m-%d)
LOG="$WORKSPACE/work/logs/$DATE.md"
mkdir -p "$WORKSPACE/work/logs"
if [ ! -f "$LOG" ]; then
  printf "# Work Log — %s\n\n## Sessions\n\n" "$DATE" > "$LOG"
fi
echo "[session-start] log ready: $LOG"

# Detect Python interpreter — used for archival and date fallback
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || command -v py 2>/dev/null || true)

# Check last backup status: surface errors from previous session
STATUS_FILE="$WORKSPACE/work/logs/.backup-status"
if [ -f "$STATUS_FILE" ]; then
  LAST=$(tail -n1 "$STATUS_FILE")
  if echo "$LAST" | grep -qE "ERROR|WARNING"; then
    echo "[session-start] WARNING: last backup had an issue — $LAST"
    echo "[session-start] Check .backup-target config or run /restore to verify data"
  fi
fi

# Item 4 — backup target reachability check (check both locations for legacy compat)
TARGET_FILE="$WORKSPACE/.backup-target"
if [ ! -f "$TARGET_FILE" ] && [ -f "$WORKSPACE/work/.backup-target" ]; then
  TARGET_FILE="$WORKSPACE/work/.backup-target"
fi
if [ -f "$TARGET_FILE" ]; then
  TARGET=$(tr -d '\r\n' < "$TARGET_FILE")
  if [ -n "$TARGET" ] && ! ls "$TARGET" >/dev/null 2>&1; then
    echo "[session-start] WARNING: backup target not reachable: $TARGET"
    echo "[session-start] Check that drive/network share is mounted, or update .backup-target"
  fi
fi

# Item 5 — auto-archive tech digest entries older than 30 days
TRENDS="$WORKSPACE/work/kb/general/tech-trends.md"
if [ -f "$TRENDS" ]; then
  if [ -z "$PYTHON" ]; then
    echo "[session-start] WARNING: python3/python not found — tech digest archival skipped (tech-trends.md may grow unbounded)"
  else
  "$PYTHON" - "$TRENDS" "$WORKSPACE/work/kb/general" << 'PYEOF' || true
import sys, re, os
from datetime import datetime, timedelta

trends_path = sys.argv[1]
kb_dir = sys.argv[2]
cutoff = datetime.now() - timedelta(days=30)

with open(trends_path, encoding='utf-8') as f:
    content = f.read()

sections = re.split(r'(?=\n## Tech Digest — \d{4}-\d{2}-\d{2})', content)
if not sections[0].strip().startswith('## Tech Digest'):
    preamble = sections.pop(0)
else:
    preamble = ''

keep, archive_by_year = [], {}
for section in sections:
    m = re.search(r'## Tech Digest — (\d{4}-\d{2}-\d{2})', section)
    if not m:
        keep.append(section); continue
    entry_date = datetime.strptime(m.group(1), '%Y-%m-%d')
    if entry_date < cutoff:
        year = m.group(1)[:4]
        archive_by_year.setdefault(year, []).append(section)
    else:
        keep.append(section)

if not archive_by_year:
    sys.exit(0)

with open(trends_path, 'w', encoding='utf-8') as f:
    f.write(preamble + ''.join(keep))

for year, entries in archive_by_year.items():
    archive_path = os.path.join(kb_dir, f'tech-trends-archive-{year}.md')
    if not os.path.exists(archive_path):
        with open(archive_path, 'w', encoding='utf-8') as f:
            f.write(f'# Tech Trends Archive — {year}\n')
    with open(archive_path, 'a', encoding='utf-8') as f:
        f.write(''.join(entries))

total = sum(len(v) for v in archive_by_year.values())
print(f"[session-start] archived {total} tech digest entries older than 30 days")
PYEOF
  fi
fi

# Item 6 — suggest /nase:reflect when today has commits
if [ -f "$WORKSPACE/work/context.md" ]; then
  REPOS=$(grep -oiE '`[A-Za-z]:[^`]+`|`/[^`]+`' "$WORKSPACE/work/context.md" 2>/dev/null | tr -d '`' || true)
  HAS_COMMITS=0
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    case "$repo" in //*|http*|ftp*) continue ;; esac  # skip UNC/remote paths
    [ -d "$repo" ] || continue                         # skip non-existent paths
    REPO_LOG=$(git -C "$repo" log --since="midnight" --oneline --branches 2>/dev/null || true)
    if [ -n "$REPO_LOG" ]; then
      HAS_COMMITS=1
      break
    fi
  done <<< "$REPOS"
  if [ "$HAS_COMMITS" -eq 1 ]; then
    echo "[session-start] You have commits today — consider running /nase:reflect to capture learnings"
  fi
fi

# Item 7 — suggest /nase:weekly-report if >7 days since last
REPORT_STATUS="$WORKSPACE/work/logs/.report-status"
if [ -f "$REPORT_STATUS" ]; then
  LAST_WEEKLY=$(grep "^weekly-report=" "$REPORT_STATUS" | cut -d= -f2 | tr -d '\r\n' || true)
  if [ -n "$LAST_WEEKLY" ]; then
    LAST_TS=$(date -d "$LAST_WEEKLY" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$LAST_WEEKLY" +%s 2>/dev/null || echo 0)
    if [ "$LAST_TS" -eq 0 ] && [ -n "$PYTHON" ]; then
      LAST_TS=$("$PYTHON" -c "from datetime import datetime; print(int(datetime.strptime('$LAST_WEEKLY','%Y-%m-%d').timestamp()))" 2>/dev/null || echo 0)
    fi
    NOW_TS=$(date +%s)
    DAYS_AGO=$(( (NOW_TS - LAST_TS) / 86400 ))
    if [ "$DAYS_AGO" -ge 7 ]; then
      echo "[session-start] Last weekly report was ${DAYS_AGO} days ago — consider running /nase:weekly-report"
    fi
  else
    echo "[session-start] No weekly report recorded yet — consider running /nase:weekly-report"
  fi
fi

