#!/usr/bin/env bash
# Static check: every subagent dispatch site must explicitly ask for a fresh
# context window. A reused agent carries its previous brief and silently turns
# the subagent into a fork of the parent (mattpocock #1341/#1342).
#
# Run from repo root: bash tests/check-subagent-dispatch.sh

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

failures=0
checked=0

# Files that are expected to dispatch subagents.
files=$(find .claude/commands/nase .claude/docs -type f -name '*.md' 2>/dev/null | sort)

while IFS= read -r f; do
  [ -z "$f" ] && continue
  # Only inspect lines that look like a dispatch site.
  matches=$(grep -nE 'Agent\(|invoke `Agent`|Spawn .*`Agent`|fresh `Agent`' "$f" || true)
  [ -z "$matches" ] && continue
  checked=$((checked + 1))
  while IFS= read -r line; do
    ln=${line%%:*}
    # Look for "fresh" in a +/-3 line window around the dispatch site.
    start=$(( ln > 3 ? ln - 3 : 1 ))
    end=$(( ln + 3 ))
    window=$(sed -n "${start},${end}p" "$f")
    if ! grep -qi 'fresh' <<<"$window"; then
      printf 'FAIL  %s:%s: dispatch site without a "fresh context" qualifier: %s\n' \
        "$f" "$ln" "${line#*:}" >&2
      failures=$((failures + 1))
    fi
  done <<<"$matches"
done <<<"$files"

printf 'checked %d file(s) with dispatch sites, %d unqualified site(s)\n' "$checked" "$failures"
if [ "$failures" -ne 0 ]; then
  exit 1
fi
exit 0
