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

# Item 6 — sync work/skills/ → .claude/commands/nase/work/
SKILLS_DIR="$WORKSPACE/work/skills"
CMDS_DIR="$WORKSPACE/.claude/commands/nase/work"
if [ -d "$SKILLS_DIR" ]; then
  mkdir -p "$CMDS_DIR"
  synced=0
  for skill_file in "$SKILLS_DIR"/*.md; do
    [ -f "$skill_file" ] || continue
    name=$(basename "$skill_file" .md)
    cmd_file="$CMDS_DIR/$name.md"
    # Extract first non-empty line as description (skip YAML frontmatter if present)
    desc=$(awk '
      /^---$/ { if (NR==1) { in_front=1; next } }
      in_front && /^---$/ { in_front=0; next }
      in_front { next }
      NF { print; exit }
    ' "$skill_file")
    # Regenerate if missing or skill file is newer
    if [ ! -f "$cmd_file" ] || [ "$skill_file" -nt "$cmd_file" ]; then
      cat > "$cmd_file" << EOF
---
name: nase:work:$name
description: $desc
---

Read \`work/skills/$name.md\` and follow every step exactly as written.

\$ARGUMENTS
EOF
      synced=$((synced + 1))
    fi
  done
  [ "$synced" -gt 0 ] && echo "[session-start] synced $synced skill(s) from work/skills/ → /nase:work:*"
fi

# Item 8 — suggest /nase:reflect when today has commits
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


