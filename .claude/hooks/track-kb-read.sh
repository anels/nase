#!/usr/bin/env bash
# PostToolUse:Read hook — record KB file reads to workspace/stats/kb-usage.jsonl.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

NASE_ROOT="${NASE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[ -z "$NASE_ROOT" ] && exit 0
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOGGER="$HOOK_DIR/../scripts/kb-usage-log.py"

INPUT=$(cat)
# One jq call for both fields. The values are joined with a NUL byte so a path
# that contains spaces, backslashes or newlines survives intact; a shell
# variable cannot hold a NUL, so they are read straight off the pipe.
FILE_PATH=""
SESSION_ID=""
{
  IFS= read -r -d '' FILE_PATH || true
  IFS= read -r -d '' SESSION_ID || true
} < <(
  printf '%s' "$INPUT" \
    | jq -j '[.tool_input.file_path // .tool_input.path // "", .session_id // .sessionId // ""] | join("\u0000")' \
      2>/dev/null || true
)
[ -z "$FILE_PATH" ] && exit 0
[ -n "$SESSION_ID" ] || SESSION_ID="${CLAUDE_SESSION_ID:-${CLAUDE_SESSIONID:-}}"

ARGS=(record --root "$NASE_ROOT" --file "$FILE_PATH" --access read --source read-hook)
[ -n "$SESSION_ID" ] && ARGS+=(--session "$SESSION_ID")
python3 "$LOGGER" "${ARGS[@]}" \
  >/dev/null 2>&1 || true

exit 0
