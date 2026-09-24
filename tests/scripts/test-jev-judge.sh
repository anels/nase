#!/usr/bin/env bash
# Regression tests for .claude/scripts/jev-judge.py.
#
# These only exercise the documented degrade contract in
# .claude/docs/jev-judgment-points.md: no live network calls are made, since
# every case here is designed to short-circuit before the HTTP request.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/jev-judge.py"
# shellcheck source=/dev/null
. "$ROOT/tests/lib/assert.sh"

failures=0

# Runs the script with a caller-supplied environment, always forcing
# TYPESAFE_API_KEY to be unset first so a real key sitting in the ambient
# environment (e.g. from the typesafe-ai plugin) never turns a degrade-path
# test into a live network call.
run() {
  env -u TYPESAFE_API_KEY "$@" python3 "$SCRIPT" \
    --point test.point --type Choice \
    --criteria '{"a": "b"}' --state '{"a": "b"}'
}

out=$(run)
rc=$?
if [ "$rc" = "0" ]; then pass "no API key: exits 0"; else fail "no API key: exits 0 (got $rc)"; fi
assert_contains "no API key: reports unavailable" <(printf '%s' "$out") '"available": false'
assert_contains "no API key: reason is no_api_key" <(printf '%s' "$out") '"reason": "no_api_key"'

out=$(run NASE_JEV=off TYPESAFE_API_KEY=dummy)
rc=$?
if [ "$rc" = "0" ]; then pass "NASE_JEV=off: exits 0"; else fail "NASE_JEV=off: exits 0 (got $rc)"; fi
assert_contains "NASE_JEV=off: reason is disabled" <(printf '%s' "$out") '"reason": "disabled"'

out=$(run TYPESAFE_API_KEY=dummy NASE_JEV_TIMEOUT_MS=)
rc=$?
if [ "$rc" = "0" ]; then pass "blank NASE_JEV_TIMEOUT_MS: exits 0, does not crash"; else fail "blank NASE_JEV_TIMEOUT_MS: exits 0 (got $rc): $out"; fi
assert_contains "blank NASE_JEV_TIMEOUT_MS: reports unavailable" <(printf '%s' "$out") '"available": false'

out=$(run TYPESAFE_API_KEY=dummy NASE_JEV_EXCERPT_CHARS=not-a-number)
rc=$?
if [ "$rc" = "0" ]; then pass "non-numeric NASE_JEV_EXCERPT_CHARS: exits 0, does not crash"; else fail "non-numeric NASE_JEV_EXCERPT_CHARS: exits 0 (got $rc): $out"; fi
assert_contains "non-numeric NASE_JEV_EXCERPT_CHARS: reports unavailable" <(printf '%s' "$out") '"available": false'

out=$(run TYPESAFE_API_KEY=dummy NASE_JEV_ENDPOINT=ftp://example.invalid)
rc=$?
if [ "$rc" = "0" ]; then pass "non-http(s) endpoint: exits 0, does not crash"; else fail "non-http(s) endpoint: exits 0 (got $rc): $out"; fi
assert_contains "non-http(s) endpoint: reason is invalid_endpoint_scheme" <(printf '%s' "$out") '"reason": "invalid_endpoint_scheme"'

out=$(env -u TYPESAFE_API_KEY TYPESAFE_API_KEY=dummy python3 "$SCRIPT" \
  --point test.point --type Choice --criteria 'not-json' --state '{"a": "b"}' 2>/dev/null)
rc=$?
if [ "$rc" = "0" ]; then pass "malformed --criteria JSON: exits 0, does not crash"; else fail "malformed --criteria JSON: exits 0 (got $rc)"; fi
assert_contains "malformed --criteria JSON: reports unavailable" <(printf '%s' "$out") '"available": false'

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\njev-judge: all tests passed\n'
