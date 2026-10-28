#!/usr/bin/env bash
# Regression tests for .claude/scripts/nase_json.py, nase_script.py and
# nase_time.utc_now_iso.
#
# These helpers replaced per-script copies whose output is hashed and bound into
# manifests, gate bundles and evidence files. Every expected value below is a literal
# written out by hand, not computed by the code under test, because a digest check that
# derives its expectation from the same function can never disagree with it. If a
# literal here has to change, an artifact already on disk stops verifying.
#
# Run from repo root:  bash tests/scripts/test-nase-json.sh

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

pass=0
fail=0

ok() {
  printf 'PASS  %s\n' "$1"
  pass=$((pass + 1))
}

bad() {
  printf 'FAIL  %s%s\n' "$1" "${2:+: $2}" >&2
  fail=$((fail + 1))
}

run_case() {
  local name="$1" program="$2"
  local err
  if err=$(python3 -c "$program" 2>&1); then
    ok "$name"
  else
    bad "$name" "$(printf '%s' "$err" | tail -3 | tr '\n' ' ')"
  fi
}

PRELUDE='
import pathlib, sys
sys.path.insert(0, str(pathlib.Path("'"$ROOT"'") / ".claude" / "scripts"))
import nase_json, nase_script, nase_time
SCRIPTS = pathlib.Path("'"$ROOT"'") / ".claude" / "scripts"
VALUE = {"é": "日本語😀", "b": 1, "a": [1, 2.5, None, True]}
'

# --- nase_json.canonical_bytes --------------------------------------------

run_case "default keeps non-ASCII as UTF-8 with no trailing newline" "$PRELUDE"'
expected = b"{\"a\":[1,2.5,null,true],\"b\":1,\"\xc3\xa9\":\"\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e\xf0\x9f\x98\x80\"}"
assert nase_json.canonical_bytes(VALUE) == expected, nase_json.canonical_bytes(VALUE)
'

run_case "trailing_newline appends exactly one LF and nothing else" "$PRELUDE"'
bare = nase_json.canonical_bytes(VALUE)
assert nase_json.canonical_bytes(VALUE, trailing_newline=True) == bare + b"\n"
'

run_case "ensure_ascii=True escapes non-ASCII and keeps the bare form" "$PRELUDE"'
expected = b"{\"a\":[1,2.5,null,true],\"b\":1,\"\\u00e9\":\"\\u65e5\\u672c\\u8a9e\\ud83d\\ude00\"}"
assert nase_json.canonical_bytes(VALUE, ensure_ascii=True) == expected
'

run_case "keys sort lexically as strings and containers stay compact" "$PRELUDE"'
value = {"10": 2, "2": 3, "": 4, "1": 1, "n": {"d": [], "c": {}}}
expected = b"{\"\":4,\"1\":1,\"10\":2,\"2\":3,\"n\":{\"c\":{},\"d\":[]}}"
assert nase_json.canonical_bytes(value) == expected
'

run_case "scalars and empty containers encode as plain JSON" "$PRELUDE"'
cases = [({}, b"{}"), ([], b"[]"), ("", b"\"\""), (None, b"null"), (True, b"true"),
         (0.1 + 0.2, b"0.30000000000000004"), (10**30, b"1000000000000000000000000000000")]
for value, expected in cases:
    assert nase_json.canonical_bytes(value) == expected, (value, nase_json.canonical_bytes(value))
'

run_case "flags are keyword-only so a call site names the variant it wants" "$PRELUDE"'
try:
    nase_json.canonical_bytes(VALUE, True)
except TypeError:
    pass
else:
    raise AssertionError("positional flag accepted")
'

# --- consumers hold the variant their stored artifacts were written with --------

run_case "verify-bundle and fsd-review-gate use the bare UTF-8 form" "$PRELUDE"'
bare = nase_json.canonical_bytes(VALUE)
for name, script in (("vb", "verify-bundle.py"), ("fsd", "fsd-review-gate.py")):
    module = nase_script.load_script(name, SCRIPTS / script)
    assert module.canonical_bytes(VALUE) == bare, script
'

run_case "external-write-action hashes the ASCII-escaped bare form" "$PRELUDE"'
import hashlib
module = nase_script.load_script("ewa", SCRIPTS / "external-write-action.py")
expected = b"{\"a\":[1,2.5,null,true],\"b\":1,\"\\u00e9\":\"\\u65e5\\u672c\\u8a9e\\ud83d\\ude00\"}"
assert module.sha256(VALUE) == hashlib.sha256(expected).hexdigest()
'

run_case "effort-rollup evidence is written UTF-8 with one trailing newline" "$PRELUDE"'
import tempfile
module = nase_script.load_script("er", SCRIPTS / "effort-rollup-evidence.py")
with tempfile.TemporaryDirectory() as tmp:
    target = pathlib.Path(tmp) / "out.json"
    module.atomic_json(target, VALUE)
    assert target.read_bytes() == nase_json.canonical_bytes(VALUE) + b"\n"
'

# --- nase_time.utc_now_iso --------------------------------------------------

run_case "utc_now_iso keeps the fraction and ends in Z" "$PRELUDE"'
import datetime as dt
class Clock(dt.datetime):
    @classmethod
    def now(cls, tz=None):
        return cls(2026, 3, 4, 5, 6, 7, 123456, tzinfo=tz)
real = nase_time.datetime
nase_time.datetime = Clock
try:
    assert nase_time.utc_now_iso() == "2026-03-04T05:06:07.123456Z"
    assert nase_time.utc_now_iso(microseconds=False) == "2026-03-04T05:06:07Z"
finally:
    nase_time.datetime = real
'

run_case "utc_now_iso on a whole second has no fraction either way" "$PRELUDE"'
import datetime as dt
class Clock(dt.datetime):
    @classmethod
    def now(cls, tz=None):
        return cls(2026, 3, 4, 5, 6, 7, 0, tzinfo=tz)
real = nase_time.datetime
nase_time.datetime = Clock
try:
    assert nase_time.utc_now_iso() == "2026-03-04T05:06:07Z"
    assert nase_time.utc_now_iso(microseconds=False) == "2026-03-04T05:06:07Z"
finally:
    nase_time.datetime = real
'

# --- nase_script ------------------------------------------------------------

run_case "load_script raises the caller's exception type, naming the file" "$PRELUDE"'
class Mine(RuntimeError):
    pass
try:
    nase_script.load_script("x", pathlib.Path("/nonexistent/helper.txt"), Mine)
except Mine as exc:
    assert str(exc) == "cannot load helper: helper.txt", str(exc)
else:
    raise AssertionError("no error")
'

run_case "load_script defaults to ImportError" "$PRELUDE"'
try:
    nase_script.load_script("x", pathlib.Path("/nonexistent/helper.txt"))
except ImportError as exc:
    assert str(exc) == "cannot load helper: helper.txt", str(exc)
else:
    raise AssertionError("no error")
'

run_case "load_script loads a hyphenated script by path" "$PRELUDE"'
module = nase_script.load_script("vb", SCRIPTS / "verify-bundle.py")
assert callable(module.scan_stream_for_secret)
assert module.__name__ == "vb"
'

run_case "stream_secret_kind names a secret and passes clean bytes" "$PRELUDE"'
scanner = nase_script.load_script("vb", SCRIPTS / "verify-bundle.py")
assert nase_script.stream_secret_kind(scanner, b"hello world") is None
assert nase_script.stream_secret_kind(scanner, b"") is None
assert nase_script.stream_secret_kind(scanner, b"password=hunter2hunter2xx") == "credential-assignment"
pem_header = b"-----BEGIN RSA " + b"PRIVATE KEY-----\nabc\n"
assert nase_script.stream_secret_kind(scanner, pem_header) == "private-key"
'

run_case "consumers share one scan result for the same bytes" "$PRELUDE"'
data = b"password=hunter2hunter2xx"
for name, script, attr in (("er", "effort-rollup-evidence.py", "secret_kind"),
                           ("cv", "citation-validator.py", "secret_kind"),
                           ("sk", "skill-eval-run.py", "scan_bytes")):
    module = nase_script.load_script(name, SCRIPTS / script)
    assert getattr(module, attr)(data) == "credential-assignment", script
    assert getattr(module, attr)(b"plain") is None, script
'

# --- no private copies come back ---------------------------------------------

run_case "no script defines its own canonical_bytes, load_module or file_sha" "$PRELUDE"'
import re
pattern = re.compile(r"^def (canonical_bytes|load_module|file_sha)\(", re.M)
offenders = [p.name for p in sorted(SCRIPTS.glob("*.py"))
             if p.name != "nase_json.py" and pattern.search(p.read_text(encoding="utf-8"))]
assert not offenders, offenders
'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
