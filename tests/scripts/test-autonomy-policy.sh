#!/usr/bin/env bash
# Regression tests for .claude/scripts/autonomy-policy.py.
#
# Exercises the contract in .claude/docs/external-mutation-policy.md ->
# Autonomy level: missing or invalid config degrades to guided, an unknown class
# never resolves to auto, and the never classes stay never at every level.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/autonomy-policy.py"
# shellcheck source=/dev/null
. "$ROOT/tests/lib/assert.sh"

failures=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/autonomy-test-XXXXXXXX")
trap 'rm -rf "$TMP"' EXIT

write_config() {
  mkdir -p "$TMP/workspace"
  printf '%s\n' "$1" > "$TMP/workspace/config.md"
}

run() {
  python3 "$SCRIPT" --root "$TMP" "$@"
}

# --- missing config -------------------------------------------------------
out=$(run --class jira-transition-progress)
rc=$?
if [ "$rc" = "0" ]; then pass "missing config: exits 0"; else fail "missing config: exits 0 (got $rc)"; fi
assert_contains "missing config: level is guided" <(printf '%s' "$out") '"level": "guided"'
assert_contains "missing config: decision is ask" <(printf '%s' "$out") '"decision": "ask"'
assert_contains "missing config: reason names the fallback" <(printf '%s' "$out") '"level_reason": "no-config"'

# --- guided ---------------------------------------------------------------
write_config '## Autonomy
level: guided'
out=$(run --class slack-draft)
assert_contains "guided: slack draft asks" <(printf '%s' "$out") '"decision": "ask"'
out=$(run --class merge)
assert_contains "guided: merge is never" <(printf '%s' "$out") '"decision": "never"'

# --- standard -------------------------------------------------------------
write_config '## Autonomy
level: standard'
out=$(run --class jira-transition-progress)
assert_contains "standard: in-progress transition is auto" <(printf '%s' "$out") '"decision": "auto"'
out=$(run --class workspace-durable-write)
assert_contains "standard: durable workspace write still asks" <(printf '%s' "$out") '"decision": "ask"'
out=$(run --class confluence-publish)
assert_contains "standard: confluence publish stays never" <(printf '%s' "$out") '"decision": "never"'
out=$(run --class slack-send)
assert_contains "standard: slack send stays never" <(printf '%s' "$out") '"decision": "never"'

# --- auto -----------------------------------------------------------------
write_config '## Autonomy
level: auto'
out=$(run --class pr-create-draft)
assert_contains "auto: draft PR is auto" <(printf '%s' "$out") '"decision": "auto"'
out=$(run --class force-push)
assert_contains "auto: force-push stays never" <(printf '%s' "$out") '"decision": "never"'
out=$(run --class review-other-pr)
assert_contains "auto: review of another PR stays never" <(printf '%s' "$out") '"decision": "never"'

# --- invalid level --------------------------------------------------------
write_config '## Autonomy
level: turbo'
out=$(run --class jira-transition-progress)
assert_contains "invalid level: degrades to guided" <(printf '%s' "$out") '"level": "guided"'
assert_contains "invalid level: names the bad value" <(printf '%s' "$out") '"level_reason": "invalid-level:turbo"'
assert_contains "invalid level: asks" <(printf '%s' "$out") '"decision": "ask"'

# --- section boundary -----------------------------------------------------
# A level key outside ## Autonomy must not be read.
write_config '## Something
level: auto'
out=$(run --class jira-transition-progress)
assert_contains "level outside the autonomy section is ignored" <(printf '%s' "$out") '"level": "guided"'

# --- unknown class --------------------------------------------------------
write_config '## Autonomy
level: auto'
out=$(run --class not-a-class)
assert_contains "unknown class: asks" <(printf '%s' "$out") '"decision": "ask"'
assert_contains "unknown class: reason is unknown-class" <(printf '%s' "$out") '"reason": "unknown-class"'

# --- list -----------------------------------------------------------------
write_config '## Autonomy
level: standard'
out=$(run --list)
count=$(printf '%s\n' "$out" | grep -c '"class":')
if [ "$count" -ge 18 ]; then pass "list: prints every class ($count)"; else fail "list: prints every class (got $count)"; fi
if grep -q -- '"decision": "never"' <<< "$out"; then
  pass "list: includes never classes"
else
  fail "list: includes never classes"
fi

# --- usage error ----------------------------------------------------------
run >/dev/null 2>&1
rc=$?
if [ "$rc" = "2" ]; then pass "no arguments: exits 2"; else fail "no arguments: exits 2 (got $rc)"; fi

# --- doc/script parity ----------------------------------------------------
# The policy table in the doc and the CLASSES map in the script are two copies
# of one contract. A class that exists in only one of them is a silent policy
# gap, so compare the class sets and the per-level decisions.
if parity=$(python3 - "$ROOT/.claude/docs/external-mutation-policy.md" "$SCRIPT" <<'PY'
import importlib.util
import re
import sys

doc_path, script_path = sys.argv[1], sys.argv[2]

spec = importlib.util.spec_from_file_location("autonomy_policy", script_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

text = open(doc_path, encoding="utf-8").read()
section = re.search(r"^## Autonomy level\s*$", text, re.M)
if not section:
    print("no autonomy section")
    sys.exit(1)
body = text[section.end():]
end = re.search(r"^##\s+", body, re.M)
body = body[: end.start()] if end else body

doc_classes = {}
for line in body.splitlines():
    if not line.startswith("| "):
        continue
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if len(cells) < 4 or not cells[1] in ("ask", "auto", "never"):
        continue
    # The class names are the leading tokens of the first cell; the parenthetical
    # after them is a human gloss, so it is cut before the names are read.
    for name in re.findall(r"[a-z][a-z0-9-]+", cells[0].split(" (")[0]):
        doc_classes[name] = tuple(cells[1:4])

script_classes = {name: (t["guided"], t["standard"], t["auto"]) for name, t in mod.CLASSES.items()}

missing_in_doc = sorted(set(script_classes) - set(doc_classes))
missing_in_script = sorted(set(doc_classes) - set(script_classes))
mismatched = sorted(
    name
    for name in set(script_classes) & set(doc_classes)
    if script_classes[name] != doc_classes[name]
)
if missing_in_doc or missing_in_script or mismatched:
    print(
        "missing_in_doc=%s missing_in_script=%s mismatched=%s"
        % (missing_in_doc, missing_in_script, mismatched)
    )
    sys.exit(1)
sys.exit(0)
PY
); then
  pass "the doc table and the script table agree"
else
  fail "the doc table and the script table agree ($parity)"
fi

if [ "$failures" -ne 0 ]; then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nautonomy-policy.sh: all assertions passed\n'
