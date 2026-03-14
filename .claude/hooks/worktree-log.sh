#!/usr/bin/env bash
# Fires on WorktreeCreate and WorktreeRemove — appends an entry to today's work log.
set -euo pipefail

WORKSPACE=$(git rev-parse --show-toplevel 2>/dev/null) || true
if [ -z "$WORKSPACE" ]; then
  exit 0
fi

read -r DATE TIMESTAMP < <(date '+%Y-%m-%d %H:%M')
LOG="$WORKSPACE/work/logs/$DATE.md"
mkdir -p "$WORKSPACE/work/logs"
[ -f "$LOG" ] || printf "# Work Log — %s\n\n## Sessions\n\n" "$DATE" > "$LOG"

# Parse hook JSON from stdin (cap at 8KB to guard against oversized payloads)
INPUT=$(head -c 8192)
EVENT="${HOOK_EVENT_NAME:-WorktreeCreate}"

# Extract worktree path via jq; field may be "path" or "worktree_path"
WORKTREE_PATH=$(printf '%s' "$INPUT" | jq -r '.path // .worktree_path // empty' 2>/dev/null || true)
[ -z "$WORKTREE_PATH" ] && WORKTREE_PATH="(path unknown)"
if [ "$EVENT" = "WorktreeCreate" ]; then
  printf -- "- %s worktree created: \`%s\`\n" "$TIMESTAMP" "$WORKTREE_PATH" >> "$LOG"
  echo "[worktree-log] logged create: $WORKTREE_PATH"
else
  printf -- "- %s worktree removed: \`%s\`\n" "$TIMESTAMP" "$WORKTREE_PATH" >> "$LOG"
  echo "[worktree-log] logged remove: $WORKTREE_PATH"
fi
