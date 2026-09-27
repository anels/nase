#!/usr/bin/env bash
# Regression tests for .claude/scripts/log-range.py
#
# /nase:recap passes this script's output straight to grep, and a dropped tail date
# produces a recap that looks complete and is not. The property under test is that
# every existing day in the range is present, month and year boundaries included,
# and that a day with no log is dropped rather than handed to grep as a missing path.
#
# Run from repo root:  bash tests/scripts/test-log-range.sh

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

SCRIPT="$ROOT/.claude/scripts/log-range.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/workspace/logs"

pass=0
fail=0
ok() { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s%s\n' "$1" "${2:+: $2}" >&2; fail=$((fail + 1)); }

seed() { : > "$TMP/workspace/logs/$1.md"; }

run() { python3 "$SCRIPT" "$1" "$2" --root "$TMP" "${@:3}"; }
days() { run "$1" "$2" | tr ' ' '\n' | xargs -n1 basename 2>/dev/null | sed 's/\.md$//' | tr '\n' ' ' | sed 's/ $//'; }

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    ok "$name"
  else
    bad "$name" "expected '$expected', got '$actual'"
  fi
}

# --- the tail-date bug this script was written to prevent ------------------

for d in 2026-01-30 2026-01-31 2026-02-01 2026-02-02; do seed "$d"; done

assert_eq "a month boundary keeps both tails" \
  "2026-01-30 2026-01-31 2026-02-01 2026-02-02" \
  "$(days 2026-01-30 2026-02-02)"

seed 2025-12-31
seed 2026-01-01
assert_eq "a year boundary keeps both tails" \
  "2025-12-31 2026-01-01" \
  "$(days 2025-12-31 2026-01-01)"

# --- absent days are dropped, not emitted ----------------------------------

# 2026-02-03 and 2026-02-04 are deliberately not seeded.
seed 2026-02-05
count=$(run 2026-02-02 2026-02-05 | tr ' ' '\n' | grep -c .)
assert_eq "days with no log file are dropped" "2" "$count"

if run 2026-02-02 2026-02-05 | grep -q '2026-02-03'; then
  bad "a missing day never reaches the caller"
else
  ok "a missing day never reaches the caller"
fi

# --- boundaries are inclusive on both ends ---------------------------------

single=$(run 2026-02-05 2026-02-05 | tr ' ' '\n' | grep -c .)
assert_eq "a single-day range is inclusive" "1" "$single"

# --- separators ------------------------------------------------------------

newline_lines=$(run 2026-01-30 2026-02-02 --separator newline | grep -c .)
assert_eq "newline separator emits one path per line" "4" "$newline_lines"

if run 2026-01-30 2026-02-02 | grep -q ' '; then
  ok "space separator joins on a single line"
else
  bad "space separator joins on a single line"
fi

# --- argument handling -----------------------------------------------------

run 2026-02-05 2026-02-02 >/dev/null 2>&1
assert_eq "an inverted range exits 1" "1" "$?"

python3 "$SCRIPT" "not-a-date" 2026-02-02 --root "$TMP" >/dev/null 2>&1
assert_eq "a malformed date exits non-zero" "1" "$?"

# An empty result is success, not an error: recap has to tolerate a quiet period.
out=$(run 2030-01-01 2030-01-05)
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "an empty range exits 0 with no output"
else
  bad "an empty range exits 0 with no output" "rc=$rc out='$out'"
fi

# --- the root is resolved, not assumed from the link -----------------------

ln -s "$SCRIPT" "$TMP/linked-log-range.py"
if python3 "$TMP/linked-log-range.py" 2026-01-30 2026-02-02 --root "$TMP" | grep -q '2026-01-30'; then
  ok "invocation through a symlink still resolves the range"
else
  bad "invocation through a symlink still resolves the range"
fi

printf '\n--- %s pass, %s fail ---\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
