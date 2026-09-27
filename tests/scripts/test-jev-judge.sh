#!/usr/bin/env bash
# Regression tests for .claude/scripts/jev-judge.py.
#
# These exercise the documented degrade contract in
# .claude/docs/jev-judgment-points.md plus the wire shape of the request body.
# No live network calls are made: the degrade cases short-circuit before the
# HTTP request, and the wire-shape cases use --dry-run, which prints the body
# and exits instead of POSTing it.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/jev-judge.py"
# shellcheck source=/dev/null
. "$ROOT/tests/lib/assert.sh"

failures=0

# Runs the script with a caller-supplied environment, always forcing
# TYPESAFE_API_KEY to be unset first so a real key sitting in the ambient
# environment (e.g. from the typesafe-ai plugin) never turns a degrade-path
# test into a live network call. NASE_JEV is cleared for the same reason, since an
# ambient `NASE_JEV=off` short-circuits every case into `{"reason": "disabled"}`.
# Caller assignments come after the `-u` flags, so `run NASE_JEV=off` still sets it.
run() {
  env -u TYPESAFE_API_KEY -u NASE_JEV "$@" python3 "$SCRIPT" \
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

# Wire shape. The API pins each question schema's "type" to a lowercase const
# ("choice" / "score" / "noul") and rejects the CLI's capitalized spelling with an
# HTTP 400 that a short timeout then reports as "timeout".
shape() {
  env -u TYPESAFE_API_KEY -u NASE_JEV python3 "$SCRIPT" \
    --point test.point --type "$1" \
    --criteria '{"a": "b"}' --state '{"a": "b"}' --dry-run
}

# Parses the request body rather than grepping it, because a degrade path prints
# `{"available": false, ...}` that satisfies a negative grep while proving nothing.
wire_type() {
  printf '%s' "$1" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["questions"]["test.point"]["type"])' \
    2>/dev/null
}

assert_wire_type() {
  # assert_wire_type <cli-spelling> <expected-on-the-wire>
  local actual
  actual=$(wire_type "$(shape "$1")")
  if [ "$actual" = "$2" ]; then
    pass "$1 is sent as lowercase \"$2\""
  else
    fail "$1 is sent as lowercase \"$2\" (got '${actual:-<no request body produced>}')"
  fi
}

out=$(shape Choice)
rc=$?
if [ "$rc" = "0" ]; then pass "--dry-run: exits 0 without an API key"; else fail "--dry-run: exits 0 without an API key (got $rc)"; fi
assert_wire_type Choice choice
assert_wire_type Noul noul
assert_wire_type Score score

assert_contains "--dry-run: model is jev-latest" <(printf '%s' "$out") '"model": "jev-latest"'
assert_contains "--dry-run: point name keys the questions dict" <(printf '%s' "$out") '"test.point"'

# net_error must carry a stable, greppable suffix, because `URLError.reason` embeds
# a platform errno string and sometimes the resolved host. Port 1 on loopback
# refuses the connection, so this reaches the branch with no egress.
out=$(env -u TYPESAFE_API_KEY -u NASE_JEV \
  TYPESAFE_API_KEY=dummy NASE_JEV_ENDPOINT=http://127.0.0.1:1/systemone \
  python3 "$SCRIPT" --point test.point --type Choice \
  --criteria '{"a": "b"}' --state '{"a": "b"}')
rc=$?
if [ "$rc" = "0" ]; then pass "a refused connection exits 0"; else fail "a refused connection exits 0 (got $rc)"; fi
if printf '%s' "$out" | grep -Eq '"reason": "net_error:[A-Za-z]+"'; then
  pass "net_error names an exception class, not a message"
else
  fail "net_error names an exception class, not a message (got: $out)"
fi
if printf '%s' "$out" | grep -q 'net_error:.*[][ (]'; then
  fail "net_error suffix must not carry errno text or punctuation"
else
  pass "net_error suffix must not carry errno text or punctuation"
fi

# Every reason the script can emit is listed in its own docstring taxonomy, so a
# new failure mode cannot ship undocumented. Read the docstring through the parser
# rather than grepping the file: each reason is also a string literal at its own
# `unavailable(...)` call site, so a whole-file grep passes with no taxonomy at all.
docstring=$(python3 -c "import ast,sys;print(ast.get_docstring(ast.parse(open(sys.argv[1],encoding='utf-8').read())) or '')" "$SCRIPT")
for reason in no_api_key disabled invalid_config invalid_endpoint_scheme \
  "exception:bad_json" http_error timeout net_error invalid_response "exception:<msg>"; do
  if printf '%s' "$docstring" | grep -qF "$reason"; then
    pass "docstring taxonomy lists $reason"
  else
    fail "docstring taxonomy lists $reason"
  fi
done

# A real Jev call measures ~1.1s, so a default timeout under that would make the
# script report "timeout" on every healthy call and jev would never be used.
default_timeout=$(grep -E '^DEFAULT_TIMEOUT_MS' "$SCRIPT" | sed 's/[^0-9]//g')
if [ -n "$default_timeout" ] && [ "$default_timeout" -ge 1500 ]; then
  pass "default timeout ($default_timeout ms) leaves room for a real call"
else
  fail "default timeout is ${default_timeout:-unset} ms; a real Jev call takes ~1100 ms"
fi

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\njev-judge: all tests passed\n'
