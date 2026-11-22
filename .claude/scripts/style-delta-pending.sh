#!/usr/bin/env bash
# style-delta-pending.sh - List pending [STYLE-DELTA] lines across the top-level daily logs.
#
# A pending delta is a log line whose marker is exactly [STYLE-DELTA], sitting right after the
# bullet's optional `HH:MM (note) | style-delta: ` prefix - the shape
# `.claude/docs/style-delta-capture.md` writes. Lines that mention the marker in prose, and the
# [STYLE-DELTA-APPLIED] / [STYLE-DELTA-DISCARDED] terminal markers, never match.
# workspace/logs/archive/ is not scanned.
#
# Usage: bash .claude/scripts/style-delta-pending.sh [--logs-dir DIR]
# Output (stdout): path:line:text, one per pending delta, oldest log first. Empty when none.
# Exit 0 always for a missing default logs dir, so "no deltas" is not read as a command
# failure.
# Exit 1: usage error, including an explicit --logs-dir that does not exist, because that is
# a mistyped path rather than "no deltas".
# Exit 2: a log file could not be read. Silence there would also read as "no deltas".

set -euo pipefail

DEFAULT_LOGS_DIR="workspace/logs"
LOGS_DIR="$DEFAULT_LOGS_DIR"
explicit_dir=0

while [ $# -gt 0 ]; do
  case "$1" in
    --logs-dir)
      [ $# -ge 2 ] || { echo "style-delta-pending: --logs-dir needs a value" >&2; exit 1; }
      LOGS_DIR="$2"
      explicit_dir=1
      shift 2
      ;;
    *)
      echo "usage: style-delta-pending.sh [--logs-dir DIR]" >&2
      exit 1
      ;;
  esac
done

if [ ! -d "$LOGS_DIR" ]; then
  if [ "$explicit_dir" -eq 1 ]; then
    echo "style-delta-pending: no such directory: $LOGS_DIR" >&2
    exit 1
  fi
  exit 0
fi

# The marker must close right after STYLE-DELTA, so the -APPLIED and -DISCARDED variants
# cannot match. The parenthetical note is free-form because real logs carry both `(08-20)`
# and `(09-14 local)` after a midnight timestamp.
PATTERN='^- ([0-9]{2}:[0-9]{2}( \([^)]*\))? \| style-delta: )?\[STYLE-DELTA\]'

for f in "$LOGS_DIR"/*.md; do
  [ -f "$f" ] || continue
  rc=0
  # -H keeps the filename on single-file grep output, which is the whole path:line:text
  # contract. Skipping sed avoids reinterpreting `&`, `|`, and `\` in a path.
  grep -Hn -E "$PATTERN" "$f" || rc=$?
  # 1 means "no match in this file", the normal case. Anything higher is a read error, and
  # reporting it as "no deltas" would silently skip a real pending delta.
  if [ "$rc" -ge 2 ]; then
    echo "style-delta-pending: cannot read $f (grep exit $rc)" >&2
    exit "$rc"
  fi
done
