#!/usr/bin/env bash
# Fires on WorktreeRemove — appends an entry to today's work log.
# Do not wire this to WorktreeCreate: Claude Code expects a WorktreeCreate hook
# to create the worktree and print the absolute worktree path on stdout.
set -euo pipefail

HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NASE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || true
if [ -z "$NASE_ROOT" ]; then
  exit 0
fi

# Parse hook JSON from stdin (cap at 8KB to guard against oversized payloads)
INPUT=$(head -c 8192)

# Extract worktree path via jq; WorktreeRemove uses "worktree_path".
WORKTREE_PATH=$(printf '%s' "$INPUT" | jq -r '.worktree_path // .path // .name // empty' 2>/dev/null || true)
[ -z "$WORKTREE_PATH" ] && WORKTREE_PATH="(path unknown)"
python3 "$HOOK_DIR/../scripts/daily-log-append.py" worktree "removed \`$WORKTREE_PATH\`" --root "$NASE_ROOT" >/dev/null
