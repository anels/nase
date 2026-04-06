#!/usr/bin/env bash
# PostToolUse:Edit hook — instant type-check after editing code files.
# Opt-in: disabled by default in settings.json. Enable via /update-config.
#
# Reads edited file path from stdin JSON, checks if it belongs to a known repo
# with a configured quick-check command, and runs it.
#
# Config: workspace/tmp/.typecheck-commands
#   Format: repo-path|command  (one per line)
#   Example: /Users/you/repos/my-app|dotnet build --no-restore -v q
#
# Requires: jq

set -euo pipefail

command -v jq &>/dev/null || exit 0

WORKSPACE=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
CONFIG="$WORKSPACE/workspace/tmp/.typecheck-commands"
[ -f "$CONFIG" ] || exit 0

FILE_PATH=$(jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
[ -n "$FILE_PATH" ] || exit 0

MATCHED_CMD=""
while IFS='|' read -r REPO_PATH CMD; do
  [ -z "$REPO_PATH" ] && continue
  [[ "$REPO_PATH" == \#* ]] && continue
  if [[ "$FILE_PATH" == "$REPO_PATH"/* ]]; then
    MATCHED_CMD="$CMD"
    MATCHED_REPO="$REPO_PATH"
    break
  fi
done < "$CONFIG"

[ -n "$MATCHED_CMD" ] || exit 0

# Timeout after 30s to avoid blocking the editor
OUTPUT=$(cd "$MATCHED_REPO" && timeout 30 bash -c "$MATCHED_CMD" 2>&1) || {
  EXIT_CODE=$?
  if [ "$EXIT_CODE" -eq 124 ]; then
    echo "[edit-typecheck] Timed out after 30s in $MATCHED_REPO"
  else
    echo "[edit-typecheck] Type-check failed in $MATCHED_REPO:"
    echo "$OUTPUT" | head -20
  fi
  exit 0
}
