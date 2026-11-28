#!/usr/bin/env bash
# The design approval bar is stated once in design.md and the mode docs point to it.
# This guards that the old "count the WEAK rows" bar does not come back, and that the
# shared concepts the design and tech-debt-audit commands lean on keep their anchors.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

failures=0
source "$ROOT/tests/lib/assert.sh"

DESIGN=.claude/commands/nase/design.md
DOCS=.claude/docs

has_old_bar() {
  grep -Eq -- 'at most 1 WEAK|≤ ?1 WEAK|2\+ WEAK' "$@"
}

assert_contains "design.md owns the Approval bar" "$DESIGN" "## Approval bar"
assert_contains "Approval bar says WEAK count does not decide" "$DESIGN" \
  "The number of \`WEAK\` rows does not decide the verdict."
assert_contains "review mode points to the Approval bar" "$DOCS/design-review-mode.md" "Approval bar"
assert_contains "auto mode points to the Approval bar" "$DOCS/design-auto-mode.md" "Approval bar"

if has_old_bar "$DESIGN" "$DOCS"/design-*.md; then
  fail "no design doc states the old WEAK-count bar"
else
  pass "no design doc states the old WEAK-count bar"
fi

probe=$(mktemp)
trap 'rm -f "$probe"' EXIT
printf 'All criteria PASS or at most 1 WEAK -> APPROVED\n' > "$probe"
if has_old_bar "$probe"; then
  pass "old-bar probe is detected"
else
  fail "old-bar probe is detected"
fi

assert_contains "fog is defined in design-research" "$DOCS/design-research.md" "### C1b. Fog of war"
assert_contains "Module shape is defined in design-principles" "$DOCS/design-principles.md" "## Module shape"
assert_contains "tech-debt-audit uses Module shape" ".claude/commands/nase/tech-debt-audit.md" "Module shape"
assert_contains "tech-debt-audit picks hot spots from git history" ".claude/commands/nase/tech-debt-audit.md" \
  "--name-only --pretty=format:"
assert_contains "tech-debt-review enforces the deletion test" "$DOCS/review-mode-tech-debt.md" "deletion test"

if [ "$failures" -eq 0 ]; then
  printf '\ndesign approval bar tests passed.\n'
  exit 0
fi

printf '\n%d design approval bar assertion(s) failed.\n' "$failures" >&2
exit 1
