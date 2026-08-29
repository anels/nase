#!/usr/bin/env bash
# Regression tests for .claude/scripts/prose-lint.py.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/prose-lint.py"
FIXTURES="$ROOT/tests/fixtures/prose"
# shellcheck source=/dev/null
. "$ROOT/tests/lib/assert.sh"

failures=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

run() {
  local surface="$1" file="$2" out="$3"
  python3 "$SCRIPT" --surface "$surface" --file "$file" --format json >"$out" 2>"$out.err"
  echo $?
}

jq_count() {
  python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
print(sum(1 for f in data["findings"] if f["rule"] == sys.argv[2]))
' "$1" "$2"
}

# --- clean drafts pass -----------------------------------------------------

rc=$(run slack-channel "$FIXTURES/slack-clean.md" "$TMP/clean.json")
if [ "$rc" = "0" ]; then pass "clean Slack draft exits 0"; else fail "clean Slack draft exits 0 (got $rc)"; fi
assert_contains "clean Slack draft reports zero gates" "$TMP/clean.json" '"gates": 0'
assert_contains "clean Slack draft reports zero markers" "$TMP/clean.json" '"markers": 0'

rc=$(run github-review-comment "$FIXTURES/review-clean.md" "$TMP/revclean.json")
if [ "$rc" = "0" ]; then pass "anchored review comment exits 0"; else fail "anchored review comment exits 0 (got $rc)"; fi

# --- slop draft trips the expected rules -----------------------------------

rc=$(run slack-channel "$FIXTURES/slack-slop.md" "$TMP/slop.json")
if [ "$rc" = "1" ]; then pass "slop Slack draft exits 1"; else fail "slop Slack draft exits 1 (got $rc)"; fi

for rule in SLK-TRAILURL SLK-BULLET FMT-EMOJI FMT-BOLDDEF; do
  n=$(jq_count "$TMP/slop.json" "$rule")
  if [ "$n" -ge 1 ]; then pass "slop draft trips $rule"; else fail "slop draft trips $rule"; fi
done

for rule in REG-T1 REG-T2 REG-T3 TPL SYN-ING SYN-SHORT SPEC; do
  n=$(jq_count "$TMP/slop.json" "$rule")
  if [ "$n" -ge 1 ]; then pass "slop draft trips $rule"; else fail "slop draft trips $rule"; fi
done

assert_contains "slop draft verdict recommends a rewrite" "$TMP/slop.json" "rewrite rather than patch"

# --- review gates ----------------------------------------------------------

rc=$(run github-review-comment "$FIXTURES/review-vague.md" "$TMP/revvague.json")
if [ "$rc" = "1" ]; then pass "vague review comment exits 1"; else fail "vague review comment exits 1 (got $rc)"; fi
for rule in REV-ANCHOR REV-COURTESY REV-YOU REV-VAGUE; do
  n=$(jq_count "$TMP/revvague.json" "$rule")
  if [ "$n" -ge 1 ]; then pass "vague review comment trips $rule"; else fail "vague review comment trips $rule"; fi
done

# --- masking: code and URLs are not prose ----------------------------------

cat >"$TMP/masked.md" <<'EOF'
Rerun finished at 09:20 for `robotlogs.leverage_delve_seamless` on host 12.

```
2026-08-28 ERROR delve underscore pivotal seamless meticulous
```

See https://example.com/utilize-and-leverage-guide in the runbook for the rest.
EOF
rc=$(run github-pr-body "$TMP/masked.md" "$TMP/masked.json")
n=$(jq_count "$TMP/masked.json" REG-T1)
if [ "$n" = "0" ]; then pass "fenced code, inline code and URLs are masked"; else fail "fenced code, inline code and URLs are masked (got $n T1 hits)"; fi

# --- word boundaries: no substring hits ------------------------------------

printf 'The delivery landed at 09:20 and the run completed on host 12.\n' >"$TMP/boundary.md"
run github-pr-body "$TMP/boundary.md" "$TMP/boundary.json" >/dev/null
n=$(jq_count "$TMP/boundary.json" REG-T3)
if [ "$n" = "0" ]; then pass "delivery does not match the very intensifier"; else fail "delivery does not match the very intensifier"; fi

# --- em dash is a gate, and the script does not carry the character --------

printf 'The fix landed — finally — on host 12 at 09:20.\n' >"$TMP/dash.md"
run slack-dm "$TMP/dash.md" "$TMP/dash.json" >/dev/null
n=$(jq_count "$TMP/dash.json" FMT-DASH)
if [ "$n" -ge 1 ]; then pass "em dash trips FMT-DASH"; else fail "em dash trips FMT-DASH"; fi
if grep -q $'—' "$SCRIPT"; then
  fail "prose-lint.py must not embed the em dash character it flags"
else
  pass "prose-lint.py does not embed the em dash character it flags"
fi

# --- jira sections ---------------------------------------------------------

printf '## Context\nbackfill gap\n\n## Scope\nrerun\n' >"$TMP/jira.md"
run jira-ticket "$TMP/jira.md" "$TMP/jira.json" >/dev/null
assert_contains "jira ticket names the missing sections" "$TMP/jira.json" "Acceptance, References"

# --- surface routing -------------------------------------------------------

printf -- '- one item\n- two item\n' >"$TMP/bullets.md"
run github-pr-body "$TMP/bullets.md" "$TMP/prbullets.json" >/dev/null
n=$(jq_count "$TMP/prbullets.json" SLK-BULLET)
if [ "$n" = "0" ]; then pass "SLK rules do not run on non-Slack surfaces"; else fail "SLK rules do not run on non-Slack surfaces"; fi

# --- usage errors ----------------------------------------------------------

python3 "$SCRIPT" --surface slack-dm >/dev/null 2>&1
if [ "$?" = "2" ]; then pass "missing --file exits 2"; else fail "missing --file exits 2"; fi

python3 "$SCRIPT" --list-rules >"$TMP/rules.txt" 2>&1
assert_contains "--list-rules prints the gate column" "$TMP/rules.txt" "REV-ANCHOR"

# --- Slack bullet direction matches slack-draft-style.md -------------------
# Formatting Mechanics: `- item` is the list syntax; a literal bullet character
# is plain text and never renders as a list. The gate must flag the latter.

printf -- '- fix in `a.py:8` moves the check\n- rerun at 09:20 finished green\n' >"$TMP/dashbullets.md"
run slack-channel "$TMP/dashbullets.md" "$TMP/dashbullets.json" >/dev/null
n=$(jq_count "$TMP/dashbullets.json" SLK-BULLET)
if [ "$n" = "0" ]; then pass "dash bullets are the correct Slack syntax"; else fail "dash bullets are the correct Slack syntax"; fi

# --- a bare URL followed by a blank line is a valid boundary ---------------

printf 'Runbook is at https://example.com/runbook\n\nRerun finished at 09:20 on host 12.\n' >"$TMP/urlblank.md"
run slack-channel "$TMP/urlblank.md" "$TMP/urlblank.json" >/dev/null
n=$(jq_count "$TMP/urlblank.json" SLK-TRAILURL)
if [ "$n" = "0" ]; then pass "blank line after a trailing URL is a valid boundary"; else fail "blank line after a trailing URL is a valid boundary"; fi

# --- paragraph offsets survive wide blank-line separators ------------------

printf 'first line here with enough words to matter\n\n   \n\nSecond block of prose that carries no concrete referent at all and simply keeps going without ever naming a thing or a count anywhere in it.\n' >"$TMP/offsets.md"
run github-pr-body "$TMP/offsets.md" "$TMP/offsets.json" >/dev/null
reported=$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
print(next((f["line"] for f in data["findings"] if f["rule"] == "SPEC"), 0))
' "$TMP/offsets.json")
if [ "$reported" = "5" ]; then
  pass "paragraph offsets survive a whitespace-only separator line"
else
  fail "paragraph offsets survive a whitespace-only separator line (SPEC reported line $reported, expected 5)"
fi

# --- terse writing is not uniform-cadence ----------------------------------

printf 'Backfill rerun done. Four partitions recovered. Dashboard is green.\n' >"$TMP/terse.md"
run slack-dm "$TMP/terse.md" "$TMP/terse.json" >/dev/null
n=$(jq_count "$TMP/terse.json" SYN-UNIFORM)
if [ "$n" = "0" ]; then pass "uniformly short sentences are not flagged as model cadence"; else fail "uniformly short sentences are not flagged as model cadence"; fi

# --- external-write-action wiring ------------------------------------------

cat >"$TMP/surface_check.py" <<'PY'
import importlib.util
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "external_write_action", root / ".claude" / "scripts" / "external-write-action.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

cases = [
    (["gh", "pr", "create", "--body-file", "b.md"], "github-pr-body"),
    (["gh", "pr", "edit", "12", "--body-file", "b.md"], "github-pr-body"),
    (["gh", "pr", "comment", "12", "--body-file", "b.md"], "github-review-reply"),
    (["gh", "pr", "review", "12", "--body-file", "b.md"], "github-review-reply"),
    (["gh", "api", "repos/o/r/pulls/12/reviews", "--method", "POST", "--input", "r.json"],
     "github-review-reply"),
    (["gh", "api", "repos/o/r/issues/12/comments", "--method", "POST", "--input", "c.json"],
     "github-review-reply"),
    (["gh", "api", "repos/o/r/releases", "--method", "POST"], None),
    (["gh", "pr", "list"], None),
    (["az", "group", "delete"], None),
]
for argv, expected in cases:
    actual = module.prose_surface(argv)
    if actual != expected:
        print(f"MISMATCH {argv} -> {actual}, expected {expected}")
        raise SystemExit(1)

body = root / "tests" / "fixtures" / "prose" / "review-vague.md"
findings = module.prose_gate_findings(root, body, "github-review-reply")
if not findings:
    print("expected gate findings from review-vague.md")
    raise SystemExit(1)
if module.prose_gate_findings(root, root / "tests" / "fixtures" / "prose" / "review-clean.md", "github-review-reply"):
    print("clean review comment must produce no gate findings")
    raise SystemExit(1)

import json
import tempfile

envelope = {
    "event": "COMMENT",
    "body": "Overall the change is fine.",
    "comments": [
        {"path": "src/a.cs", "line": 12, "body": "Make sure to handle this as appropriate."},
        {"path": "src/b.cs", "line": 3, "body": "`src/b.cs:3` returns before the dispose."},
    ],
}
with tempfile.TemporaryDirectory() as tmp:
    review = pathlib.Path(tmp) / "review.json"
    review.write_text(json.dumps(envelope), encoding="utf-8")
    labels = [label for label, _ in module.prose_bodies(review)]
    if len(labels) != 3:
        print(f"expected 3 body values from the review envelope, got {labels}")
        raise SystemExit(1)
    hits = module.prose_gate_findings(root, review, "github-review-reply")
    if not any("comments[0].body" in hit for hit in hits):
        print(f"expected the vague inline comment to be flagged, got {hits}")
        raise SystemExit(1)
    if any("comments[1].body" in hit for hit in hits):
        print(f"the anchored inline comment must stay clean, got {hits}")
        raise SystemExit(1)

import os

os.environ["NASE_PROSE_LINT"] = "0"
if module.prose_gate_findings(root, body, "github-review-reply"):
    print("NASE_PROSE_LINT=0 must disable the external-write prose gate")
    raise SystemExit(1)
del os.environ["NASE_PROSE_LINT"]
print("ok")
PY

if python3 "$TMP/surface_check.py" "$ROOT" >"$TMP/surface.out" 2>&1; then
  pass "external-write-action maps gh subcommands to prose surfaces"
else
  fail "external-write-action maps gh subcommands to prose surfaces: $(cat "$TMP/surface.out")"
fi

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nprose-lint: all tests passed\n'
