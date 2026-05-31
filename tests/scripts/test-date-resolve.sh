#!/usr/bin/env bash
# Regression tests for .claude/scripts/date-resolve.py.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/date-resolve.py"

pass=0
fail=0

assert_exit() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    pass=$((pass + 1))
    printf 'PASS  %s (exit=%s)\n' "$desc" "$actual"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s (expected exit=%s, got %s)\n' "$desc" "$expected" "$actual" >&2
  fi
}

assert_contains() {
  local desc="$1" actual="$2" needle="$3"
  if printf '%s' "$actual" | grep -qF "$needle"; then
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n  expected to contain: %s\n  actual: %s\n' "$desc" "$needle" "$actual" >&2
  fi
}

assert_not_contains() {
  local desc="$1" actual="$2" needle="$3"
  if printf '%s' "$actual" | grep -qF "$needle"; then
    fail=$((fail + 1))
    printf 'FAIL  %s\n  expected NOT to contain: %s\n  actual: %s\n' "$desc" "$needle" "$actual" >&2
  else
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$desc"
  fi
}

out=$(python3 "$SCRIPT" "2026-05-01 to 2026-05-02" 2>&1)
rc=$?
assert_exit "T1: valid explicit range succeeds" 0 "$rc"
assert_contains "T1: valid range output" "$out" "2026-05-01 2026-05-02"

out=$(python3 "$SCRIPT" "2026-13-01 to 2026-13-02" 2>&1)
rc=$?
assert_exit "T2: invalid explicit range falls back" 0 "$rc"
assert_contains "T2: invalid range warns" "$out" "WARNING: invalid date range"
assert_not_contains "T2: no traceback" "$out" "Traceback"

out=$(python3 "$SCRIPT" "2026-05-03 to 2026-05-01" 2>&1)
rc=$?
assert_exit "T3: reversed explicit range falls back" 0 "$rc"
assert_contains "T3: reversed range warns" "$out" "end before start"
assert_not_contains "T3: no traceback" "$out" "Traceback"

expected_10d=$(python3 - <<'PY'
import datetime
today = datetime.date.today()
print(f"{today - datetime.timedelta(days=9)} {today}")
PY
)
out=$(python3 "$SCRIPT" "10d" 2>&1)
rc=$?
assert_exit "T4: arbitrary Nd range succeeds" 0 "$rc"
assert_contains "T4: 10d range output" "$out" "$expected_10d"
assert_not_contains "T4: no fallback warning" "$out" "WARNING:"

out=$(python3 "$SCRIPT" "last 10 days" 2>&1)
rc=$?
assert_exit "T5: arbitrary last N days succeeds" 0 "$rc"
assert_contains "T5: last 10 days output" "$out" "$expected_10d"
assert_not_contains "T5: no fallback warning" "$out" "WARNING:"

out=$(python3 "$SCRIPT" "999999999999999999999d" 2>&1)
rc=$?
assert_exit "T6: huge day count falls back cleanly" 0 "$rc"
assert_contains "T6: huge day count warns" "$out" "WARNING: invalid day count"
assert_not_contains "T6: no traceback" "$out" "Traceback"

total=$((pass + fail))
printf '\n%d/%d assertions passed\n' "$pass" "$total"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
