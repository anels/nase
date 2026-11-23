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

# PowerShell reads a backslash as a literal path separator, where the POSIX scanner reads
# an escape and drops it, so `C:\tools\gh.exe pr merge` would never name `gh`. Scan with
# forward slashes, as block-dangerous-git.sh does. `tr` drops the CR a Windows jq prints.
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null | tr -d '\r') \
  || block 'could not read the tool name from the tool input'
if [ "$TOOL_NAME" = "PowerShell" ]; then
  CMD=${CMD//\\//}
fi

# The command goes over stdin: as an argument, one past the OS limit (about 32K
# characters on Windows) fails to launch and reads as a blocked mutation.
GUARD_RC=0
printf '%s' "$CMD" | python3 "$HOOK_DIR/../scripts/external-write-action.py" guard || GUARD_RC=$?
case "$GUARD_RC" in
  0) ;;
  10) block 'raw external mutation is not allowed; use external-write-action.py with an approved manifest' ;;
  *) block "the guard could not inspect this command (exit $GUARD_RC); failing closed. This is a guard failure, not a verdict on the command." ;;
esac
