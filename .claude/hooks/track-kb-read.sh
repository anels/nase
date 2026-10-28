#!/usr/bin/env bash
# PostToolUse:Read hook — record KB file reads to workspace/stats/kb-usage.jsonl.

set -uo pipefail

HOOK_DIR=${BASH_SOURCE[0]%/*}
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.
# shellcheck source=../lib/hook-common.sh
{ [ -r "$HOOK_DIR/../lib/hook-common.sh" ] && . "$HOOK_DIR/../lib/hook-common.sh"; } 2>/dev/null \
  || { echo "[track-kb-read] hook-common.sh unavailable - skipping" >&2; exit 0; }

nase_require jq python3 || exit 0

NASE_ROOT=$(nase_root) || exit 0
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
[ -n "$SESSION_ID" ] || SESSION_ID=$(nase_session_id)

ARGS=(record --root "$NASE_ROOT" --file "$FILE_PATH" --access read --source read-hook)
[ -n "$SESSION_ID" ] && ARGS+=(--session "$SESSION_ID")
python3 "$LOGGER" "${ARGS[@]}" \
  >/dev/null 2>&1 || true

exit 0
