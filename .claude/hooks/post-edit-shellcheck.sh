#!/usr/bin/env bash
# PostToolUse Edit|Write hook — run shellcheck on edited shell scripts.
#
# Exit 2 on diagnostics so Claude Code receives stderr as blocking feedback.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat || true)"
[[ -z "$INPUT" ]] && exit 0

FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
[[ -z "$FILE_PATH" ]] && exit 0

case "$FILE_PATH" in
  *.sh|*.bash) ;;
  *) exit 0 ;;
esac

[[ -f "$FILE_PATH" ]] || exit 0
command -v shellcheck >/dev/null 2>&1 || exit 0

if output=$(shellcheck -S warning "$FILE_PATH" 2>&1); then
  exit 0
fi

printf 'shellcheck failed for %s:\n%s\n' "$FILE_PATH" "$output" >&2
exit 2
