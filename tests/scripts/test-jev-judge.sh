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

out=$(run TYPESAFE_API_KEY=dummy 'NASE_JEV_ENDPOINT=http://[bad')
rc=$?
if [ "$rc" = "0" ]; then pass "unparseable endpoint: exits 0, does not crash"; else fail "unparseable endpoint: exits 0 (got $rc): $out"; fi
assert_contains "unparseable endpoint: reason is invalid_endpoint_scheme" <(printf '%s' "$out") '"reason": "invalid_endpoint_scheme"'

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
if printf '%s' "$out" | python3 -c 'import json,sys; r=json.load(sys.stdin)["reason"]; sys.exit(0 if any(c in r for c in "[] (") else 1)'; then
  fail "net_error suffix must not carry errno text or punctuation (got: $(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["reason"])'))"
else
  pass "net_error suffix must not carry errno text or punctuation"
fi

# A client failure that is not a network error must not quote its message: http.client
# embeds the whole Authorization header in the text for a key with a control character,
# and doctor prints this reason. The key below ends in a carriage return to trigger it.
out=$(env -u NASE_JEV TYPESAFE_API_KEY=$'sk-leak-canary\r' NASE_JEV_ENDPOINT=http://127.0.0.1:1/systemone \
  python3 "$SCRIPT" --point test.point --type Choice \
  --criteria '{"a": "b"}' --state '{"a": "b"}')
if grep -q -- "sk-leak-canary" <<< "$out"; then
  fail "the reason must not echo the API key (got: $out)"
else
  pass "the reason does not echo the API key"
fi
if printf '%s' "$out" | grep -Eq '"reason": "exception:[A-Za-z]+"'; then
  pass "a client failure names an exception class, not a message"
else
  fail "a client failure names an exception class, not a message (got: $out)"
fi

# Every reason the script can emit is listed in its own docstring taxonomy, so a
# new failure mode cannot ship undocumented. Read the docstring through the parser
# rather than grepping the file: each reason is also a string literal at its own
# `unavailable(...)` call site, so a whole-file grep passes with no taxonomy at all.
docstring=$(python3 -c "import ast,sys;print(ast.get_docstring(ast.parse(open(sys.argv[1],encoding='utf-8').read())) or '')" "$SCRIPT")
for reason in no_api_key disabled invalid_config invalid_endpoint_scheme \
  "exception:bad_json" http_error timeout net_error invalid_response "exception:<class>"; do
  if grep -qF -- "$reason" <<< "$docstring"; then
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

# A call site that only names the doc leaves the agent guessing how to run Jev, and
# a guess like `command -v jev` reports "not installed" for a working setup. Every
# tracked `Try jev first` line must name `.claude/scripts/jev-judge.py`, and doctor must
# probe it. The owner doc describes the call-site pattern and is not a call site itself.
sites=$(git -C "$ROOT" grep -n -i 'try jev first' -- .claude ':!.claude/docs/jev-judgment-points.md')
sites_rc=$?
bare=$(printf '%s\n' "$sites" | grep -v -F '.claude/scripts/jev-judge.py' || true)
if [ "$sites_rc" -eq 0 ] && [ -z "$bare" ]; then
  pass "every Try jev first call site names jev-judge.py"
else
  fail "Try jev first call sites missing jev-judge.py (git grep exit $sites_rc): $(printf '%s' "$bare" | cut -d: -f1,2 | tr '\n' ' ')"
fi
if grep -q -F -- '--point doctor.probe' "$ROOT/.claude/commands/nase/doctor.md"; then
  pass "doctor probes jev-judge.py"
else
  fail "doctor probes jev-judge.py"
fi

# A Noul question with only free-form criteria is rejected by the API with HTTP 400.
noul_sites=$(git -C "$ROOT" grep -n -E -e '--type[= ]+"?Noul' -- .claude ':!.claude/docs/jev-judgment-points.md')
noul_rc=$?
noul_bad=$(printf '%s\n' "$noul_sites" | awk -F: '{
  a = $0; calls = gsub(/--type[= ]+"?Noul/, "&", a)
  b = $0; ins = gsub(/--instructions/, "&", b)
  if (calls != ins) print $1 ":" $2
}')
if [ "$noul_rc" -eq 0 ] && [ -z "$noul_bad" ]; then
  pass "every Noul call site passes --instructions"
else
  fail "every Noul call site passes --instructions (git grep exit $noul_rc, missing in: $(printf '%s' "$noul_bad" | tr '\n' ' '))"
fi

# The API sends no confidence for Noul, only a probability, so the script derives one.
noul_confidence() {
  env -u NASE_JEV TYPESAFE_API_KEY=dummy python3 -I - "$SCRIPT" "$1" <<'PY'
import importlib.util
import io
import json
import sys
import urllib.request

spec = importlib.util.spec_from_file_location("jev_judge", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


body = json.dumps({"answers": {"p": {"type": "noul", "noul": float(sys.argv[2])}}}).encode()
urllib.request.urlopen = lambda *a, **k: Response(body)
sys.argv = ["jev-judge.py", "--point", "p", "--type", "Noul", "--instructions", "q", "--criteria", "{}", "--state", "{}"]
mod.main()
PY
}
for p in 0.95 0.05 0.6; do
  want=$(python3 -c "p=$p; print(max(p, 1 - p))")
  got=$(noul_confidence "$p" | python3 -c "import json,sys; print(json.load(sys.stdin)['confidence'])")
  if [ "$got" = "$want" ]; then
    pass "Noul probability $p reports confidence $want"
  else
    fail "Noul probability $p reports confidence $want (got '$got')"
  fi
done

# The usable/fallback decision lives in the script, not in each call site: a
# caller that hand-rolls `confidence >= 0.9` will drift from this threshold, and
# a caller that only checks `available` will trust a 0.4 answer. Telemetry is
# opt-in and must never change the answer.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/jev-telemetry-XXXXXXXX")
trap 'rm -rf "$TMP"' EXIT

choice_shape() {
  env -u NASE_JEV TYPESAFE_API_KEY=dummy NASE_JEV_TELEMETRY_FILE="$TMP/jev.jsonl" \
    python3 -I - "$SCRIPT" "$1" <<'PY'
import importlib.util
import io
import json
import sys
import urllib.request

spec = importlib.util.spec_from_file_location("jev_judge", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


body = json.dumps(
    {"answers": {"p": {"type": "choice", "choice": "a", "confidence": float(sys.argv[2])}}}
).encode()
urllib.request.urlopen = lambda *a, **k: Response(body)
sys.argv = ["jev-judge.py", "--point", "p", "--type", "Choice", "--criteria", '{"a":"b"}', "--state", "{}"]
mod.main()
PY
}

out=$(choice_shape 0.4)
if [ "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["usable"])')" = "False" ]; then
  pass "confidence 0.4 is not usable"
else
  fail "confidence 0.4 is not usable (got: $out)"
fi
if [ "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["fallback_reason"])')" = "low_confidence" ]; then
  pass "confidence 0.4 reports low_confidence"
else
  fail "confidence 0.4 reports low_confidence (got: $out)"
fi
if [ "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["point"])')" = "p" ]; then
  pass "the answer echoes its point name"
else
  fail "the answer echoes its point name (got: $out)"
fi

out=$(choice_shape 0.95)
if [ "$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["usable"], d["fallback_reason"])')" = "True None" ]; then
  pass "confidence 0.95 is usable with no fallback"
else
  fail "confidence 0.95 is usable with no fallback (got: $out)"
fi

if [ -s "$TMP/jev.jsonl" ]; then
  lines=$(wc -l < "$TMP/jev.jsonl" | tr -d ' ')
  if [ "$lines" = "2" ]; then
    pass "telemetry writes one line per call"
  else
    fail "telemetry writes one line per call (got $lines)"
  fi
  if tail -1 "$TMP/jev.jsonl" | python3 -c 'import json,sys
d=json.load(sys.stdin)
need={"ts","point","type","available","confidence","usable","fallback_reason","latency_ms","criteria_sha256"}
sys.exit(0 if need <= set(d) and len(d["criteria_sha256"])==12 else 1)'; then
    pass "telemetry carries point, confidence, fallback, latency, and criteria hash"
  else
    fail "telemetry carries point, confidence, fallback, latency, and criteria hash (got: $(tail -1 "$TMP/jev.jsonl"))"
  fi
else
  fail "telemetry file was not written"
fi

# A telemetry path that cannot be written must not change the answer or the exit code.
out=$(env -u TYPESAFE_API_KEY -u NASE_JEV NASE_JEV_TELEMETRY_FILE=/dev/null/nope \
  python3 "$SCRIPT" --point test.point --type Choice \
  --criteria '{"a": "b"}' --state '{"a": "b"}')
rc=$?
if [ "$rc" = "0" ] && grep -q -- '"reason": "no_api_key"' <<< "$out"; then
  pass "an unwritable telemetry path leaves the answer intact"
else
  fail "an unwritable telemetry path leaves the answer intact (rc=$rc, got: $out)"
fi

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\njev-judge: all tests passed\n'
