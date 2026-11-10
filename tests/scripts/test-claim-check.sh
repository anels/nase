#!/usr/bin/env bash
# Regression tests for .claude/scripts/claim-check.py
#
# Run from repo root: bash tests/scripts/test-claim-check.sh

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/claim-check.py"
FIX="$ROOT/tests/fixtures/transcripts"

pass=0
fail=0

ok() { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL  %s%s\n' "$1" "${2:+: $2}" >&2; fail=$((fail+1)); }

run_case() {
  # $1 fixture, $2 expected: silent|warn
  local fx="$1" expected="$2" out rc
  out=$(printf '{"transcript_path":"%s/%s","session_id":"s1"}' "$FIX" "$fx" | python3 "$SCRIPT" 2>&1) || rc=$?
  rc=${rc:-0}
  if [ "$expected" = "silent" ]; then
    if [ -z "$out" ]; then ok "$fx -> silent"; else bad "$fx -> silent" "$out"; fi
  else
    if [ -n "$out" ] && grep -q "claim-check" <<<"$out"; then ok "$fx -> warn"; else bad "$fx -> warn" "$out"; fi
  fi
}

run_case "a-proven.jsonl" "silent"
run_case "b-no-run.jsonl" "warn"
run_case "c-fail-run.jsonl" "warn"
run_case "d-edit-after.jsonl" "warn"
run_case "e-malformed.jsonl" "warn"

# missing transcript path -> silent, no crash
out=$(printf '{"session_id":"s2"}' | python3 "$SCRIPT" 2>&1) || rc=$?
rc=${rc:-0}
if [ -z "$out" ] && [ "$rc" -eq 0 ]; then ok "missing transcript -> silent"; else bad "missing transcript -> silent" "$out"; fi

# non-existent transcript -> silent, no crash
out=$(printf '{"transcript_path":"/no/such/file.jsonl","session_id":"s3"}' | python3 "$SCRIPT" 2>&1) || rc=$?
rc=${rc:-0}
if [ -z "$out" ] && [ "$rc" -eq 0 ]; then ok "missing file -> silent"; else bad "missing file -> silent" "$out"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
