#!/usr/bin/env bash
# Keep high-context command entrypoints and their on-demand phase docs bounded.

set -euo pipefail

max_entry_lines=250
max_entry_bytes=12000
max_phase_lines=300
max_phase_bytes=18000
failures=0

entry_skills=(
  .claude/commands/nase/fsd.md
  .claude/commands/nase/discuss-pr.md
  .claude/commands/nase/address-comments.md
)

phase_docs=(
  .claude/docs/fsd-intake-and-setup.md
  .claude/docs/fsd-implementation-loop.md
  .claude/docs/address-comments-analysis.md
  .claude/docs/address-comments-delivery.md
  .claude/docs/discuss-pr-analysis.md
  .claude/docs/discuss-pr-output.md
)

check_budget() {
  local file="$1" max_lines="$2" max_bytes="$3" label="$4"
  local lines bytes
  lines=$(wc -l < "$file" | tr -d ' ')
  bytes=$(wc -c < "$file" | tr -d ' ')
  if (( lines <= max_lines && bytes <= max_bytes )); then
    printf 'PASS  %s %s: %s lines, %s bytes (budget: %s lines, %s bytes)\n' \
      "$label" "$file" "$lines" "$bytes" "$max_lines" "$max_bytes"
  else
    printf 'FAIL  %s %s: %s lines, %s bytes (budget: %s lines, %s bytes)\n' \
      "$label" "$file" "$lines" "$bytes" "$max_lines" "$max_bytes" >&2
    failures=$((failures + 1))
  fi
}

for skill in "${entry_skills[@]}"; do
  check_budget "$skill" "$max_entry_lines" "$max_entry_bytes" entry
done

for doc in "${phase_docs[@]}"; do
  check_budget "$doc" "$max_phase_lines" "$max_phase_bytes" phase-doc
done

if (( failures > 0 )); then
  exit 1
fi
