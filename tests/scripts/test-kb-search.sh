#!/usr/bin/env bash
# Regression tests for .claude/scripts/kb-search.sh.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/kb-search.sh"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/workspace/kb/general"
cat > "$FIXTURE/workspace/kb/general/search.md" <<'EOF'
# Search fixture

### 2026-05-01 Literal bracket search
**Tags:** [P1], shell
**Confidence:** high
literal [ value in body.

### 2026-05-02 C++ literal search
**Tags:** language
**Confidence:** high
C++ and .NET should be searched as literal text.

### 2026-05-03 Dash literal search
**Tags:** shell
**Confidence:** high
--literal should be searched as an exact literal, not interpreted as a grep option.

### 2026-05-04 Long token budget search
**Tags:** token-budget
**Confidence:** high
longtoken line 01
longtoken line 02
longtoken line 03
longtoken line 04
longtoken line 05
longtoken line 06
longtoken line 07
longtoken line 08
longtoken line 09
longtoken line 10
longtoken line 11
longtoken line 12
longtoken line 13
longtoken line 14
longtoken line 15
longtoken line 16
longtoken line 17
longtoken line 18
longtoken line 19
longtoken line 20
longtoken line 21
longtoken line 22
longtoken line 23
longtoken line 24
longtoken line 25
longtoken line 26
longtoken line 27
longtoken line 28
longtoken line 29
longtoken line 30
EOF

cd "$FIXTURE" || exit 1

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

out=$(bash "$SCRIPT" "[" 2>&1)
rc=$?
assert_exit "T1: literal bracket query succeeds" 0 "$rc"
assert_contains "T1: literal bracket entry found" "$out" "Literal bracket search"
assert_not_contains "T1: no grep regex error" "$out" "grep:"

out=$(bash "$SCRIPT" "literal" "tag:[P1]" 2>&1)
rc=$?
assert_exit "T2: literal tag filter succeeds" 0 "$rc"
assert_contains "T2: tag-filtered entry found" "$out" "Literal bracket search"
assert_not_contains "T2: no grep regex error" "$out" "grep:"

out=$(bash "$SCRIPT" "C++" 2>&1)
rc=$?
assert_exit "T3: literal plus query succeeds" 0 "$rc"
assert_contains "T3: C++ entry found" "$out" "C++ literal search"
assert_not_contains "T3: no grep regex error" "$out" "grep:"

out=$(bash "$SCRIPT" --with-score "literal" 2>&1)
rc=$?
assert_exit "T4: score output succeeds" 0 "$rc"
assert_contains "T4: score is exposed" "$out" "**Score:** 3"
assert_contains "T4: scored entry found" "$out" "Literal bracket search"

out=$(bash "$SCRIPT" "--literal" 2>&1)
rc=$?
assert_exit "T5: dash-prefixed literal query succeeds" 0 "$rc"
assert_contains "T5: dash-prefixed entry found" "$out" "Dash literal search"
assert_not_contains "T5: exact dash query does not fall back" "$out" "partial match"

out=$(bash "$SCRIPT" "longtoken" "--max-entry-lines" 8 2>&1)
rc=$?
assert_exit "T6: long entries are capped by default" 0 "$rc"
assert_contains "T6: cap marker is shown" "$out" "rerun with --full"
assert_not_contains "T6: capped output omits tail" "$out" "longtoken line 30"

out=$(bash "$SCRIPT" "longtoken" "--full" 2>&1)
rc=$?
assert_exit "T7: --full preserves complete entry output" 0 "$rc"
assert_contains "T7: full output includes tail" "$out" "longtoken line 30"

total=$((pass + fail))
printf '\n%d/%d assertions passed\n' "$pass" "$total"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
