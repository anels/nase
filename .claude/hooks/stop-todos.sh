#!/usr/bin/env bash
# Sourced before `set -e`: on bash 3.2 a syntax error in a sourced file would otherwise
# end the shell with status 2 instead of reaching the `||` fallback below.
HOOK_DIR=${BASH_SOURCE[0]%/*}
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.
# shellcheck source=../lib/hook-common.sh
{ [ -r "$HOOK_DIR/../lib/hook-common.sh" ] && . "$HOOK_DIR/../lib/hook-common.sh"; } 2>/dev/null \
  || { echo "[stop-todos] hook-common.sh unavailable - skipping" >&2; exit 0; }

set -euo pipefail

NASE_ROOT=$(nase_root) || exit 0

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
nase_require jq || exit 0
jq -cn --arg msg "$MESSAGE" '{systemMessage:$msg}'
