#!/usr/bin/env bash
# Fires on WorktreeRemove — appends an entry to today's work log.
# Do not wire this to WorktreeCreate: Claude Code expects a WorktreeCreate hook
# to create the worktree and print the absolute worktree path on stdout.
# Sourced before `set -e`: on bash 3.2 a syntax error in a sourced file would otherwise
# end the shell with status 2 instead of reaching the `||` fallback below.
HOOK_DIR=${BASH_SOURCE[0]%/*}
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.
# shellcheck source=../lib/hook-common.sh
{ [ -r "$HOOK_DIR/../lib/hook-common.sh" ] && . "$HOOK_DIR/../lib/hook-common.sh"; } 2>/dev/null \
  || { echo "[worktree-log] hook-common.sh unavailable - skipping" >&2; exit 0; }

set -euo pipefail

NASE_ROOT=$(nase_root) || exit 0

# Parse hook JSON from stdin (cap at 8KB to guard against oversized payloads)
INPUT=$(head -c 8192)

# Extract worktree path via jq; WorktreeRemove uses "worktree_path".
WORKTREE_PATH=$(printf '%s' "$INPUT" | jq -r '.worktree_path // .path // .name // empty' 2>/dev/null || true)
[ -z "$WORKTREE_PATH" ] && WORKTREE_PATH="(path unknown)"
python3 "$HOOK_DIR/../scripts/daily-log-append.py" worktree "removed \`$WORKTREE_PATH\`" --root "$NASE_ROOT" >/dev/null
