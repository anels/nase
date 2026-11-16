#!/usr/bin/env bash
# PreCompact hook — rotate large or stale workspace artifacts BEFORE the model
# enters context-compression. Cheap, idempotent, defensive: any failure here
# must not block the compress event itself.
#
# Triggers (each independent):
#   1. workspace/tasks/lessons.md > 80 KB → move entries marked
#      `> Promoted → <kb-file>` AND dated > 90 days ago into lessons-archive.md
#   2. workspace/efforts/done/*.md older than 60 days → move into
#      workspace/efforts/archive/<YYYY>/ (the year of the file's mtime)
#
# Read-only when the size/age guards aren't tripped — runs nearly instantly.

set -uo pipefail

HOOK_DIR=${BASH_SOURCE[0]%/*}
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.
# shellcheck source=../lib/hook-common.sh
{ [ -r "$HOOK_DIR/../lib/hook-common.sh" ] && . "$HOOK_DIR/../lib/hook-common.sh"; } 2>/dev/null \
  || { echo "[pre-compact-archive] hook-common.sh unavailable - skipping" >&2; exit 0; }

NASE_ROOT=$(nase_root) || exit 0
cd "$NASE_ROOT" || exit 0

PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)

# --- Lessons rotation -------------------------------------------------------
LESSONS="$NASE_ROOT/workspace/tasks/lessons.md"
LESSONS_JOURNAL="$NASE_ROOT/.nase-locks/workspace-archive-lessons.json"
RUN_LESSONS_ARCHIVE=0
if [ -e "$LESSONS_JOURNAL" ] || [ -L "$LESSONS_JOURNAL" ]; then
  # A prior archive transaction must finish even if cleanup already shrank the source.
  RUN_LESSONS_ARCHIVE=1
elif [ -f "$LESSONS" ] && [ ! -L "$LESSONS" ]; then
  # Start new work only when the file has grown past the threshold.
  SIZE=$(wc -c <"$LESSONS" 2>/dev/null || echo 0)
  if [ "${SIZE:-0}" -gt 81920 ]; then
    RUN_LESSONS_ARCHIVE=1
  fi
fi
if [ "$RUN_LESSONS_ARCHIVE" -eq 1 ]; then
  if [ -z "$PYTHON" ]; then
    echo "[pre-compact] WARNING: python3/python not found; lessons archival skipped" >&2
  elif ! "$PYTHON" .claude/scripts/workspace-archive.py lessons --root "$NASE_ROOT"; then
    echo "[pre-compact] WARNING: lessons archival failed; source was preserved" >&2
  fi
fi

# --- Efforts rotation -------------------------------------------------------
EFFORTS_DONE="$NASE_ROOT/workspace/efforts/done"
if [ -d "$EFFORTS_DONE" ] && [ -n "$PYTHON" ]; then
  # Year of the file's mtime, so a December file archived in January keeps its own year.
  # GNU `stat -c` goes first because GNU `stat -f` succeeds with filesystem info.
  file_year() {
    local m
    m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null) || return 1
    date -r "$m" +%Y 2>/dev/null || date -d "@$m" +%Y
  }
  moved=0
  years=""
  # mtime > 60 days. Use find -mtime for cross-shell portability.
  while IFS= read -r -d '' f; do
    relative=${f#"$NASE_ROOT"/}
    YEAR=$(file_year "$f") || YEAR=$(date +%Y)
    destination="workspace/efforts/archive/$YEAR/$(basename "$f")"
    if "$PYTHON" .claude/scripts/workspace-write-guard.py move-existing \
      --root "$NASE_ROOT" \
      --target "$relative" \
      --destination "$destination" \
      --older-than-days 60 \
      --lock-timeout-ms 250 >/dev/null 2>&1; then
      moved=$((moved + 1))
      case " $years " in *" $YEAR "*) ;; *) years="$years $YEAR" ;; esac
    else
      echo "[pre-compact] WARNING: retained $relative; archive collision or concurrent change" >&2
    fi
  done < <(find "$EFFORTS_DONE" -maxdepth 1 -type f -name '*.md' -mtime +60 -print0 2>/dev/null)
  if [ "$moved" -gt 0 ]; then
    years_label=$(printf '%s\n' $years | sort | paste -sd, -)
    case "$years_label" in
      *,*) years_label="{$years_label}" ;;
    esac
    echo "[pre-compact] archived $moved effort doc(s) > 60d → workspace/efforts/archive/$years_label/"
  fi
fi

exit 0
