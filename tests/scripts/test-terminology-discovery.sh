#!/usr/bin/env bash
# Regression tests for the terminology-discovery wiring.
# The shared doc must exist, every call site must point at it, and the
# private-source rule must stay in the research step it constrains.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"
# shellcheck source=tests/lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

DOC=".claude/docs/terminology-discovery.md"
failures=0

assert_cmd "$DOC exists" test -f "$DOC"

for file in .claude/commands/nase/learn.md .claude/commands/nase/onboard.md \
  .claude/docs/discuss-pr-output.md .claude/commands/nase/terminology.md; do
  assert_contains "$file points at $DOC" "$file" "$DOC"
done

for skill in learn onboard discuss-pr; do
  assert_contains "$DOC names /nase:$skill" "$DOC" "/nase:$skill"
done

assert_contains "$DOC keeps the no-direct-write rule" "$DOC" 'never writes under `workspace/kb/terminology/`'
assert_contains "$DOC hands the private-source flag to the command" "$DOC" 'pass `source:private`'
assert_contains "$DOC skips the hand-off for a cancelled write" "$DOC" 'Skipped when the write was cancelled'
assert_contains "onboard lists candidates without asking" .claude/commands/nase/onboard.md 'without asking'
assert_contains "learn carries the question in its existing ask" .claude/commands/nase/learn.md 'terminology question from `.claude/docs/terminology-discovery.md`'
assert_contains "discuss-pr carries the question in its existing ask" .claude/docs/discuss-pr-output.md 'terminology question from `.claude/docs/terminology-discovery.md`'

step_3a_skips_web() {
  awk '/^ +4\. WebSearch\/WebFetch/{f=1} f&&/^$/{exit} f' .claude/commands/nase/terminology.md \
    | grep -qF 'Skip this step when `source:private` is set'
}
assert_cmd "terminology Step 3a keeps the private-source web skip" step_3a_skips_web

if (( failures > 0 )); then
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi
