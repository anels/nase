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
if [ -f "$LESSONS" ]; then
  # Size guard — only do work when the file has grown past the threshold.
  SIZE=$(wc -c <"$LESSONS" 2>/dev/null || echo 0)
  if [ "${SIZE:-0}" -gt 81920 ] && [ -n "$PYTHON" ]; then
    if ! "$PYTHON" .claude/scripts/workspace-archive.py lessons --root "$NASE_ROOT"; then
      echo "[pre-compact] WARNING: lessons archival failed; source was preserved" >&2
    fi
  fi
fi

# --- Efforts rotation -------------------------------------------------------
EFFORTS_DONE="$NASE_ROOT/workspace/efforts/done"
if [ -d "$EFFORTS_DONE" ] && [ -n "$PYTHON" ]; then
  YEAR=$(date +%Y)
  ARCHIVE_DIR="$NASE_ROOT/workspace/efforts/archive/$YEAR"
  moved=0
  # mtime > 60 days. Use find -mtime for cross-shell portability.
  while IFS= read -r -d '' f; do
    relative=${f#"$NASE_ROOT"/}
    destination="workspace/efforts/archive/$YEAR/$(basename "$f")"
    if "$PYTHON" .claude/scripts/workspace-write-guard.py move-existing \
      --root "$NASE_ROOT" \
      --target "$relative" \
      --destination "$destination" \
      --older-than-days 60 \
      --lock-timeout-ms 250 >/dev/null 2>&1; then
      moved=$((moved + 1))
    else
      echo "[pre-compact] WARNING: retained $relative; archive collision or concurrent change" >&2
    fi
  done < <(find "$EFFORTS_DONE" -maxdepth 1 -type f -name '*.md' -mtime +60 -print0 2>/dev/null)
  if [ "$moved" -gt 0 ]; then
    echo "[pre-compact] archived $moved effort doc(s) > 60d → workspace/efforts/archive/$YEAR/"
  fi
fi

exit 0
