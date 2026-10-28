#!/usr/bin/env bash
# PreToolUse Bash guard for GitHub, ADO, and known cloud CLI mutations.
set -euo pipefail

# Load the shared lib before the EXIT trap below. A syntax error in a sourced file
# makes bash 3.2 exit through the trap with status 0, which would fail open; with no
# trap yet, `set -e` exits 2 and the guard blocks.
HOOK_DIR=${BASH_SOURCE[0]%/*}
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.
# shellcheck source=../lib/hook-common.sh
{ [ -r "$HOOK_DIR/../lib/hook-common.sh" ] && . "$HOOK_DIR/../lib/hook-common.sh"; } 2>/dev/null \
  || { echo "BLOCKED by external-cli-write-guard: hook-common.sh is missing or unreadable; failing closed." >&2; exit 2; }

nase_install_fail_closed_trap external-cli-write-guard

block() {
  printf 'BLOCKED by external-cli-write-guard: %s\n' "$1" >&2
  exit 2
}

nase_require jq || block 'jq is required to inspect Bash tool input'
nase_require python3 || block 'python3 is required to inspect external mutations'

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) \
  || block 'could not parse Bash tool input JSON'
[[ -z "$CMD" ]] && exit 0

if ! python3 "$HOOK_DIR/../scripts/external-write-action.py" guard --command "$CMD"; then
  block 'raw external mutation is not allowed; use external-write-action.py with an approved manifest'
fi
