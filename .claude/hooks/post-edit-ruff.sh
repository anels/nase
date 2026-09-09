#!/usr/bin/env bash
# PostToolUse Edit|Write hook — run ruff on edited Python files.
#
# The twin of post-edit-shellcheck.sh: `tests/check-all.sh` catches a lint failure at
# commit time, this catches it at edit time.
#
# Exit 2 on diagnostics so Claude Code receives stderr as blocking feedback.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat || true)"
[[ -z "$INPUT" ]] && exit 0

FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
[[ -z "$FILE_PATH" ]] && exit 0

case "$FILE_PATH" in
  *.py) ;;
  *) exit 0 ;;
esac

[[ -f "$FILE_PATH" ]] || exit 0
command -v ruff >/dev/null 2>&1 || exit 0

# ruff discovers its config from the edited file's directory upward, so an edit in
# another repo is judged by that repo's rules, not this one's. --force-exclude also
# honours those rules' excludes, so an edit to scratch Python under `workspace/` is
# skipped here; `tests/check-all.sh` names the skill scripts explicitly instead.
if output=$(ruff check --no-cache --force-exclude "$FILE_PATH" 2>&1); then
  exit 0
fi

printf 'ruff failed for %s:\n%s\n' "$FILE_PATH" "$output" >&2
exit 2
