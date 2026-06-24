#!/usr/bin/env bash
# Regression tests for .claude/scripts/statusline-context.py.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/statusline-context.py"

pass=0
fail=0

assert_eq() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual" >&2
  fi
}

render() {
  printf '%s\n' "$1" | python3 "$SCRIPT"
}

out=$(render '{"model":{"display_name":"Sonnet"},"context_window":{"used_percentage":42.8,"current_usage":{"input_tokens":1234,"cache_read_input_tokens":567,"cache_creation_input_tokens":89}}}')
assert_eq "renders compact status line" "$out" "Sonnet | ctx 42% | in 1234 | cache r567/w89"

out=$(render '{}')
assert_eq "missing fields degrade to zero/unknown" "$out" "unknown | ctx 0% | in 0 | cache r0/w0"

out=$(render '{')
assert_eq "invalid json does not fail" "$out" "unknown | ctx 0% | in 0 | cache r0/w0"

out=$(render '{"context_window":{"current_usage":7}}')
assert_eq "non-object usage degrades to zero" "$out" "unknown | ctx 0% | in 0 | cache r0/w0"

total=$((pass + fail))
printf '\n%d/%d assertions passed\n' "$pass" "$total"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
