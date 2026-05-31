#!/usr/bin/env bash
# Fires on WorktreeRemove — appends an entry to today's work log.
# Do not wire this to WorktreeCreate: Claude Code expects a WorktreeCreate hook
# to create the worktree and print the absolute worktree path on stdout.
set -euo pipefail

NASE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || true
if [ -z "$NASE_ROOT" ]; then
  exit 0
fi

IFS=' ' read -r DATE TIMESTAMP <<< "$(date '+%Y-%m-%d %H:%M')"
LOG="$NASE_ROOT/workspace/logs/$DATE.md"
mkdir -p "$NASE_ROOT/workspace/logs"
[ -f "$LOG" ] || printf "# Work Log — %s\n\n## Sessions\n\n" "$DATE" > "$LOG"

# Parse hook JSON from stdin (cap at 8KB to guard against oversized payloads)
INPUT=$(head -c 8192)

# Extract worktree path via jq; WorktreeRemove uses "worktree_path".
WORKTREE_PATH=$(printf '%s' "$INPUT" | jq -r '.worktree_path // .path // .name // empty' 2>/dev/null || true)
[ -z "$WORKTREE_PATH" ] && WORKTREE_PATH="(path unknown)"
printf -- "- %s worktree removed: \`%s\`\n" "$TIMESTAMP" "$WORKTREE_PATH" >> "$LOG"
echo "[worktree-log] logged remove: $WORKTREE_PATH" >&2
