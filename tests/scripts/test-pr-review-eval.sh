#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

PYTHON_BIN=$(command -v python3)
SCRIPT=".claude/scripts/pr-review-eval.py"
EVAL_SET="evals/pr-review/evals.json"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

failures=0

pass() {
  printf 'PASS  %s\n' "$1"
}

fail() {
  printf 'FAIL  %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_cmd() {
  local name="$1"
  shift
  if "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
}

assert_cmd "eval set validates" "$PYTHON_BIN" "$SCRIPT" validate "$EVAL_SET"

list_out="$TMPDIR_TEST/list.txt"
"$PYTHON_BIN" "$SCRIPT" list "$EVAL_SET" > "$list_out"
assert_cmd "eval list includes discuss-pr case" grep -q "discuss-pr-problem-first" "$list_out"
assert_cmd "eval list includes request-review case" grep -q "request-review-draft-style" "$list_out"
assert_cmd "eval list includes address-comments dossier case" grep -q "address-comments-dossier-evidence" "$list_out"
assert_cmd "eval list includes tech-debt AI verification case" grep -q "tech-debt-ai-verification-section" "$list_out"

cat > "$TMPDIR_TEST/discuss-ok.txt" <<'TXT'
Review frame
Problem: this PR fixes stale cache invalidation for dashboard refreshes.

Confirmed findings
[HIGH] src/cache.ts:42 - The fallback never updates the timestamp.
Comment draft: use the same invalidation path as the existing refresh worker.
TXT

score_ok="$TMPDIR_TEST/score-ok.json"
"$PYTHON_BIN" "$SCRIPT" score --eval-set "$EVAL_SET" --case discuss-pr-problem-first --output "$TMPDIR_TEST/discuss-ok.txt" > "$score_ok"
assert_cmd "passing output scores ok" "$PYTHON_BIN" - "$score_ok" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["ok"] is True
assert data["passed"] == data["total"]
PY

cat > "$TMPDIR_TEST/discuss-bad.txt" <<'TXT'
I posted the GitHub comments.
Findings:
Looks fine.
TXT
assert_cmd "bad output fails scoring" bash -c '! "$1" "$2" score --eval-set "$3" --case discuss-pr-problem-first --output "$4" >/dev/null' _ "$PYTHON_BIN" "$SCRIPT" "$EVAL_SET" "$TMPDIR_TEST/discuss-bad.txt"

cat > "$TMPDIR_TEST/request-ok.txt" <<'TXT'
Candidate reviewers:
Alice - owns src/cache

Could you help review https://github.com/example/service/pull/126 - this mainly fixes stale cache invalidation
Slack draft is staged only after confirmation.
TXT
"$PYTHON_BIN" "$SCRIPT" score --eval-set "$EVAL_SET" --case request-review-draft-style --output "$TMPDIR_TEST/request-ok.txt" >/dev/null
pass "request-review draft output scores ok"

cat > "$TMPDIR_TEST/address-dossier-ok.txt" <<'TXT'
Thread: src/auth.ts:42 comment 1001
Premise: reviewer says the tenant guard is missing.
Risk: P1 correctness/runtime because the route can return cross-tenant data.
Evidence checked:
- comment chain: reviewer asked for the tenant guard
- PR diff/base/HEAD: base had tenantId check, HEAD removed it in this PR
- KB/repo rule: tenant isolation required for auth handlers
- caller/dependency impact: caller impact includes src/routes/report.ts:88
- tests/scanners: missing test for cross-tenant access
Decision: accept
Action: restore tenant guard and add test.
Verification: npm test -- auth
TXT
"$PYTHON_BIN" "$SCRIPT" score --eval-set "$EVAL_SET" --case address-comments-dossier-evidence --output "$TMPDIR_TEST/address-dossier-ok.txt" >/dev/null
pass "address-comments dossier output scores ok"

cat > "$TMPDIR_TEST/tech-debt-ai-ok.txt" <<'TXT'
AI Verification Debt
Explicit AI provenance found: yes - Co-Authored-By: Claude in commit abc123
ai_provenance: explicit
verification_gap: missing-tests
risk: P1 correctness/runtime
Missing verification: no runtime regression test covers src/importer.ts:77
recommended_next_check: npm test -- importer
Recommended repayment order: P1 x high confidence x S effort x 20 days
TXT
"$PYTHON_BIN" "$SCRIPT" score --eval-set "$EVAL_SET" --case tech-debt-ai-verification-section --output "$TMPDIR_TEST/tech-debt-ai-ok.txt" >/dev/null
pass "tech-debt AI verification output scores ok"

if [[ "$failures" -eq 0 ]]; then
  printf '\npr-review-eval tests passed.\n'
  exit 0
fi

printf '\n%d pr-review-eval assertion(s) failed.\n' "$failures" >&2
exit 1
