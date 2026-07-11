#!/usr/bin/env bash
# Keep the highest-context command skills small enough to invoke without excess carryover.

set -euo pipefail

max_lines=500
failures=0

skills=(
  .claude/commands/nase/fsd.md
  .claude/commands/nase/discuss-pr.md
  .claude/commands/nase/address-comments.md
)

for skill in "${skills[@]}"; do
  lines=$(wc -l < "$skill" | tr -d ' ')
  if (( lines <= max_lines )); then
    printf 'PASS  %s is %s lines (budget: %s)\n' "$skill" "$lines" "$max_lines"
  else
    printf 'FAIL  %s is %s lines (budget: %s)\n' "$skill" "$lines" "$max_lines" >&2
    failures=$((failures + 1))
  fi
done

if (( failures > 0 )); then
  exit 1
fi
