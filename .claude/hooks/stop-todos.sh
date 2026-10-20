#!/usr/bin/env bash
set -euo pipefail

NASE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || true
if [ -z "$NASE_ROOT" ]; then
  exit 0
fi

MESSAGE=""

append_line() {
  if [ -n "$MESSAGE" ]; then
    MESSAGE+=$'\n'
  fi
  MESSAGE+="$1"
}

# Session notes — the backup hook owns the archive; this hook owns the reminder.
# A successful Stop hook's stdout is never shown, so emit JSON systemMessage.
LOG_DATE=$(date +%Y-%m-%d)
LOG="$NASE_ROOT/workspace/logs/$LOG_DATE.md"
if [ -f "$LOG" ]; then
  SESSION_CONTENT=$(awk '/^## Sessions/{found=1; next} /^## /{found=0} found && /[^[:space:]]/{print; exit}' "$LOG")
  if [ -z "$SESSION_CONTENT" ]; then
    append_line "[session-end] WARNING: no session notes in today's log — update workspace/logs/$LOG_DATE.md before closing"
  fi
else
  append_line "[session-end] WARNING: no daily log for today — consider running /nase:wrap-up"
fi

if [ -z "$MESSAGE" ]; then
  exit 0
fi
command -v jq >/dev/null 2>&1 || exit 0
jq -cn --arg msg "$MESSAGE" '{systemMessage:$msg}'
