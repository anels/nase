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

NASE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
CONFIG="$NASE_ROOT/workspace/tmp/.typecheck-commands"
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

# Timeout after 30s to avoid blocking the editor. macOS does not ship GNU
# timeout by default; Homebrew installs it as gtimeout.
TIMEOUT_BIN=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
if [ -n "$TIMEOUT_BIN" ]; then
  RUN_CMD=("$TIMEOUT_BIN" 30 bash -c "$MATCHED_CMD")
else
  WARN_MARKER="$NASE_ROOT/workspace/tmp/.edit-typecheck-no-timeout-warned"
  if [ ! -f "$WARN_MARKER" ]; then
    mkdir -p "$(dirname "$WARN_MARKER")"
    echo "[edit-typecheck] WARNING: timeout/gtimeout not found; running checks without a timeout"
    : > "$WARN_MARKER"
  fi
  RUN_CMD=(bash -c "$MATCHED_CMD")
fi

OUTPUT=$(cd "$MATCHED_REPO" && "${RUN_CMD[@]}" 2>&1) || {
  EXIT_CODE=$?
  if [ -n "$TIMEOUT_BIN" ] && [ "$EXIT_CODE" -eq 124 ]; then
    echo "[edit-typecheck] Timed out after 30s in $MATCHED_REPO"
  else
    echo "[edit-typecheck] Type-check failed in $MATCHED_REPO:"
    echo "$OUTPUT" | head -20
  fi
  exit 0
}
