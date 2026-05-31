#!/usr/bin/env bash
# PreCompact hook — rotate large or stale workspace artifacts BEFORE the model
# enters context-compression. Cheap, idempotent, defensive: any failure here
# must not block the compress event itself.
#
# Triggers (each independent):
#   1. workspace/tasks/lessons.md > 80 KB → move entries marked
#      `> Promoted → <kb-file>` AND dated > 90 days ago into lessons-archive.md
#   2. workspace/efforts/done/*.md older than 60 days → move into
#      workspace/efforts/archive/<YYYY>/
#
# Read-only when the size/age guards aren't tripped — runs nearly instantly.

set -uo pipefail

NASE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$NASE_ROOT" || exit 0

PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)

# --- Lessons rotation -------------------------------------------------------
LESSONS="$NASE_ROOT/workspace/tasks/lessons.md"
LESSONS_ARCHIVE="$NASE_ROOT/workspace/tasks/lessons-archive.md"
if [ -f "$LESSONS" ]; then
  # Size guard — only do work when the file has grown past the threshold.
  SIZE=$(wc -c <"$LESSONS" 2>/dev/null || echo 0)
  if [ "${SIZE:-0}" -gt 81920 ] && [ -n "$PYTHON" ]; then
    "$PYTHON" - "$LESSONS" "$LESSONS_ARCHIVE" << 'PYEOF' || true
import os, re, sys
from datetime import datetime, timedelta

src, dst = sys.argv[1], sys.argv[2]
cutoff = (datetime.now() - timedelta(days=90)).date()

with open(src, encoding='utf-8') as f:
    text = f.read()

# Sections delimited by lines like:
#   ## debugging -- 2026-05-05 -- title...
sections = re.split(r'(?=^## [a-z]+ -- \d{4}-\d{2}-\d{2})', text, flags=re.MULTILINE)

preamble = ''
if sections and not sections[0].startswith('## '):
    preamble = sections.pop(0)

keep, archived = [], []
for s in sections:
    m = re.match(r'## [a-z]+ -- (\d{4}-\d{2}-\d{2})', s)
    if not m:
        keep.append(s); continue
    d = datetime.strptime(m.group(1), '%Y-%m-%d').date()
    promoted = '> Promoted →' in s
    if d < cutoff and promoted:
        archived.append(s)
    else:
        keep.append(s)

if not archived:
    sys.exit(0)

with open(src, 'w', encoding='utf-8') as f:
    f.write(preamble + ''.join(keep))

if not os.path.exists(dst):
    with open(dst, 'w', encoding='utf-8') as f:
        f.write('# Lessons Archive\n\n> Promoted lessons older than 90 days. Moved here by pre-compact-archive.sh.\n\n')

with open(dst, 'a', encoding='utf-8') as f:
    f.write(''.join(archived))

print(f"[pre-compact] archived {len(archived)} promoted lesson(s) > 90d → workspace/tasks/lessons-archive.md")
PYEOF
  fi
fi

# --- Efforts rotation -------------------------------------------------------
EFFORTS_DONE="$NASE_ROOT/workspace/efforts/done"
if [ -d "$EFFORTS_DONE" ]; then
  YEAR=$(date +%Y)
  ARCHIVE_DIR="$NASE_ROOT/workspace/efforts/archive/$YEAR"
  moved=0
  # mtime > 60 days. Use find -mtime for cross-shell portability.
  while IFS= read -r -d '' f; do
    mkdir -p "$ARCHIVE_DIR"
    if mv "$f" "$ARCHIVE_DIR/" 2>/dev/null; then
      moved=$((moved + 1))
    fi
  done < <(find "$EFFORTS_DONE" -maxdepth 1 -type f -name '*.md' -mtime +60 -print0 2>/dev/null)
  if [ "$moved" -gt 0 ]; then
    echo "[pre-compact] archived $moved effort doc(s) > 60d → workspace/efforts/archive/$YEAR/"
  fi
fi

exit 0
