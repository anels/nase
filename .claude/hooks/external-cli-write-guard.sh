#!/usr/bin/env bash
# PreToolUse Bash guard for GitHub, ADO, and known cloud CLI mutations.
set -euo pipefail

block() {
  printf 'BLOCKED by external-cli-write-guard: %s\n' "$1" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || block 'jq is required to inspect Bash tool input'
command -v python3 >/dev/null 2>&1 || block 'python3 is required to inspect external mutations'

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) \
  || block 'could not parse Bash tool input JSON'
[[ -z "$CMD" ]] && exit 0

HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if ! python3 "$HOOK_DIR/../scripts/external-write-action.py" guard --command "$CMD"; then
  block 'raw external mutation is not allowed; use external-write-action.py with an approved manifest'
fi
