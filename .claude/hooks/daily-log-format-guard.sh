#!/usr/bin/env bash
# PreToolUse guard: block Edit, Write and MultiEdit calls that add a non-canonical
# session line to workspace/logs/YYYY-MM-DD.md. Rule and exit codes: daily-log-line-check.py.
# Fails open on infrastructure problems. Escape hatch: NASE_DAILY_LOG_GUARD=0.
set -uo pipefail

[ "${NASE_DAILY_LOG_GUARD:-1}" = "0" ] && exit 0

CHECK="$(dirname "${BASH_SOURCE[0]}")/../scripts/daily-log-line-check.py"

command -v python3 >/dev/null 2>&1 || exit 0
[ -r "$CHECK" ] || exit 0

payload=$(cat)
[[ $payload == *workspace*logs* ]] || exit 0

printf '%s' "$payload" | python3 "$CHECK"
