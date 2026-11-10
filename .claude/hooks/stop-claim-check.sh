#!/usr/bin/env bash
# Sourced before `set -e`: on bash 3.2 a syntax error in a sourced file would otherwise
# end the shell with status 2 instead of reaching the `||` fallback below.
HOOK_DIR=${BASH_SOURCE[0]%/*}
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.
# shellcheck source=../lib/hook-common.sh
{ [ -r "$HOOK_DIR/../lib/hook-common.sh" ] && . "$HOOK_DIR/../lib/hook-common.sh"; } 2>/dev/null \
  || { exit 0; }

set -euo pipefail

# Fail-open telemetry-style hook: never block, never non-zero.
nase_require python3 || exit 0
NASE_ROOT=$(nase_root) || exit 0

INPUT=$(cat 2>/dev/null || true)
if [ -z "$INPUT" ]; then
  exit 0
fi

# Export NASE_ROOT so claim-check.py can place its dedupe marker there.
export NASE_ROOT
printf '%s' "$INPUT" | python3 "$NASE_ROOT/.claude/scripts/claim-check.py" 2>/dev/null || true
exit 0
