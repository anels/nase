#!/usr/bin/env bash
# Regression tests for .claude/scripts/trace-role.py, the eval gate that decides
# whether discuss-pr Step 5b may trace with `lookup` instead of `worker`.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/trace-role.py"
# shellcheck source=/dev/null
. "$ROOT/tests/lib/assert.sh"

failures=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/trace-role-test-XXXXXXXX")
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude/docs"
cp "$ROOT/.claude/docs/pr-review-verification.md" "$TMP/.claude/docs/"

run() { python3 "$SCRIPT" --root "$TMP" "$@"; }

out=$(run resolve)
assert_contains "no receipt: worker" <(printf '%s' "$out") '"role": "worker"'
assert_contains "no receipt: reason" <(printf '%s' "$out") '"reason": "no-receipt"'

run record --worker-correct 10 --lookup-correct 10 --cases 19 >/dev/null 2>&1
rc=$?
if [ "$rc" = "2" ]; then pass "fewer than 20 cases is refused"; else fail "fewer than 20 cases is refused (got $rc)"; fi

run record --worker-correct 21 --lookup-correct 20 --cases 20 >/dev/null 2>&1
rc=$?
if [ "$rc" = "2" ]; then pass "correct answers above case count are refused"; else fail "correct answers above case count are refused (got $rc)"; fi

out=$(run record --worker-correct 18 --lookup-correct 18 --cases 20)
assert_contains "a tie records lookup" <(printf '%s' "$out") '"role": "lookup"'
out=$(run resolve)
assert_contains "a tie resolves to lookup" <(printf '%s' "$out") '"role": "lookup"'

out=$(run record --worker-correct 19 --lookup-correct 18 --cases 20)
assert_contains "a lookup loss records worker" <(printf '%s' "$out") '"role": "worker"'
out=$(run resolve)
assert_contains "a lookup loss resolves to worker" <(printf '%s' "$out") '"reason": "lookup-lost"'

# Any change to the §13 directive invalidates the receipt: the eval measured the
# old prompt, so its result cannot speak for the new one.
out=$(run record --worker-correct 18 --lookup-correct 18 --cases 20)
printf '\n- changed after the eval\n' >> "$TMP/.claude/docs/pr-review-verification.md"
out=$(run resolve)
assert_contains "a changed directive invalidates the receipt" <(printf '%s' "$out") '"reason": "directive-changed"'

# The gate is only real if Step 5b calls it.
if grep -q 'trace-role.py' "$ROOT/.claude/docs/discuss-pr-analysis.md"; then
  pass "discuss-pr Step 5b calls the trace-role gate"
else
  fail "discuss-pr Step 5b calls the trace-role gate"
fi

if [ "$failures" -ne 0 ]; then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\ntrace-role.sh: all assertions passed\n'
