#!/usr/bin/env bash
# Regression tests for .claude/scripts/frontmatter_scalar.py
#
# effort-state.py, workspace-quality-scan.py and effort-rollup-evidence.py all branch
# on the validity flag rather than the value alone. The flag is the contract, and it
# says the frontmatter was unambiguous. Were it ever True for a duplicated or empty
# key, an effort's status would be decided by line order and nothing would report it.
#
# Run from repo root:  bash tests/scripts/test-frontmatter-scalar.sh

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

# Each case is a python program that prints nothing and exits 0, or raises.
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
from frontmatter_scalar import extract_frontmatter_scalar, normalize_scalar, canonical_bool
def doc(body):
    return "---\n" + body + "\n---\n\nbody text\n"
'

# --- extract_frontmatter_scalar: the validity flag -------------------------

run_case "a single non-empty key is valid" "$PRELUDE"'
value, valid = extract_frontmatter_scalar(doc("status: active"), "status")
assert (value, valid) == ("active", True), (value, valid)
'

run_case "an absent key is valid so the caller can apply its own default" "$PRELUDE"'
value, valid = extract_frontmatter_scalar(doc("status: active"), "tracking_only")
assert (value, valid) == (None, True), (value, valid)
'

run_case "a duplicated key fails closed" "$PRELUDE"'
# Two values and no rule for which wins. Returning True here would let the
# consumer act on line order.
value, valid = extract_frontmatter_scalar(doc("status: active\nstatus: done"), "status")
assert valid is False, (value, valid)
'

run_case "an empty value fails closed" "$PRELUDE"'
for body in ("status:", "status: ", "status:   "):
    value, valid = extract_frontmatter_scalar(doc(body), "status")
    assert valid is False, (body, value, valid)
'

run_case "a duplicated key fails closed even when one copy is empty" "$PRELUDE"'
value, valid = extract_frontmatter_scalar(doc("status: active\nstatus:"), "status")
assert valid is False, (value, valid)
'

run_case "a file with no frontmatter is valid and yields nothing" "$PRELUDE"'
value, valid = extract_frontmatter_scalar("# Just a heading\n\nbody\n", "status")
assert (value, valid) == (None, True), (value, valid)
'

run_case "only the frontmatter block is read, not the body" "$PRELUDE"'
# A line in the body that looks like frontmatter must not be picked up, or an
# effort doc that merely mentions "status: done" in prose changes its own state.
text = doc("status: active") + "\nstatus: done\n"
value, valid = extract_frontmatter_scalar(text, "status")
assert (value, valid) == ("active", True), (value, valid)
'

run_case "the key match is case-insensitive but anchored to line start" "$PRELUDE"'
value, valid = extract_frontmatter_scalar(doc("Status: active"), "status")
assert (value, valid) == ("active", True), (value, valid)
# An indented or suffixed key is a different key, not this one.
value, valid = extract_frontmatter_scalar(doc("  status: active"), "status")
assert value is None, (value, valid)
value, valid = extract_frontmatter_scalar(doc("status_extra: active"), "status")
assert value is None, (value, valid)
'

run_case "a CRLF frontmatter block still parses" "$PRELUDE"'
# A file edited on Windows must not read as having no frontmatter at all; that
# turns a real status into a silent default.
text = "---\r\nstatus: active\r\n---\r\n\r\nbody\r\n"
value, valid = extract_frontmatter_scalar(text, "status")
assert valid is True, (value, valid)
assert value.strip() == "active", repr(value)
'

# --- normalize_scalar ------------------------------------------------------

run_case "normalize_scalar lowercases and strips a trailing comment" "$PRELUDE"'
assert normalize_scalar("Active # still open") == "active"
assert normalize_scalar("  DONE  ") == "done"
'

run_case "normalize_scalar does not treat a quoted hash as a comment" "$PRELUDE"'
# The whole reason this helper exists instead of a split on "#".
assert normalize_scalar("\"c#\"") == "c#"
assert normalize_scalar("'"'"'a # b'"'"'") == "a # b"
'

run_case "normalize_scalar strips a comment after a closing quote" "$PRELUDE"'
assert normalize_scalar("\"done\" # finished") == "done"
'

# --- canonical_bool: the deliberately narrow contract ----------------------

run_case "canonical_bool accepts only unquoted true and false" "$PRELUDE"'
assert canonical_bool("true") == (True, True)
assert canonical_bool("false") == (False, True)
assert canonical_bool("True") == (True, True)
assert canonical_bool(" false # for now ") == (False, True)
'

run_case "canonical_bool treats a missing value as a valid default of false" "$PRELUDE"'
assert canonical_bool(None) == (False, True)
'

run_case "canonical_bool fails closed on a quoted or non-boolean value" "$PRELUDE"'
# A quoted "true" is a string in YAML, not a boolean. Accepting it would let a
# typo read as an intentional opt-in.
for raw in ("\"true\"", "'"'"'true'"'"'", "yes", "1", "on", "", "   ", "maybe"):
    value, valid = canonical_bool(raw)
    assert valid is False, (raw, value, valid)
    assert value is False, (raw, value)
'

# --- the contract the consumers actually rely on ---------------------------

if grep -q "extract_frontmatter_scalar" "$ROOT/.claude/scripts/effort-state.py" \
  && grep -q "extract_frontmatter_scalar" "$ROOT/.claude/scripts/workspace-quality-scan.py"; then
  ok "the consumers this contract protects still import it"
else
  bad "the consumers this contract protects still import it"
fi

printf '\n--- %s pass, %s fail ---\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
