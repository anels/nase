#!/usr/bin/env bash
# Resolve and run one hook registered in .claude/settings.json.
#
# Centralising the root lookup here keeps the 25 hook registrations to one line
# each. Before this, each entry repeated `WORKSPACE=$(git rev-parse ...)`, which
# made a root-resolution change a 25-site edit.
#
# Usage: hook-dispatch.sh <hook-file> [args...]
#   hook-file is a basename under .claude/hooks/, e.g. stop-backup.sh.
#
# Root precedence: NASE_ROOT, then CLAUDE_PROJECT_DIR (set by Claude Code),
# then `git rev-parse --show-toplevel`. With none of them the hook is skipped
# rather than run against the wrong tree.

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: hook-dispatch.sh <hook-file> [args...]" >&2
  exit 2
fi

HOOK_NAME=$1
shift

case "$HOOK_NAME" in
  *.sh) ;;
  *) echo "hook-dispatch: expected a .sh hook name: $HOOK_NAME" >&2; exit 2 ;;
esac
case "$HOOK_NAME" in
  */*|*..*) echo "hook-dispatch: hook name may not contain a path: $HOOK_NAME" >&2; exit 2 ;;
esac

ROOT=${NASE_ROOT:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || true)}}
if [ -z "$ROOT" ]; then
  echo "hook-dispatch: cannot resolve the project root; hook skipped" >&2
  exit 0
fi

export NASE_ROOT="$ROOT"
exec bash "$ROOT/.claude/hooks/$HOOK_NAME" "$@"
