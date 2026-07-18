#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

PYTHON_BIN=$(command -v python3)
SCRIPT=".claude/scripts/pr-review-eval.py"
EVAL_SET="evals/pr-review/evals.json"
CORE_EVAL_SET="evals/core-workflows/evals.json"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

failures=0
source "$ROOT/tests/lib/assert.sh"

assert_cmd "eval set validates" "$PYTHON_BIN" "$SCRIPT" validate "$EVAL_SET"
assert_cmd "core workflow eval set validates" "$PYTHON_BIN" "$SCRIPT" validate "$CORE_EVAL_SET"

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

cat > "$TMPDIR_TEST/design-ok.txt" <<'TXT'
Target PR count: 1
Validation - how to get the real number: run `pytest tests/test_invoice_retry.py`.
TXT
"$PYTHON_BIN" "$SCRIPT" score --eval-set "$CORE_EVAL_SET" --case design-implementation-ready --output "$TMPDIR_TEST/design-ok.txt" >/dev/null
pass "design output scores ok"

cat > "$TMPDIR_TEST/sre-ok.txt" <<'TXT'
Status: keep open - the error is still occurring inside the 30-minute recovery window.
Recovery evidence: 8 failures in the last 15 minutes.
Confidence: high.
TXT
"$PYTHON_BIN" "$SCRIPT" score --eval-set "$CORE_EVAL_SET" --case sre-closure-evidence --output "$TMPDIR_TEST/sre-ok.txt" >/dev/null
pass "SRE closure output scores ok"

cat > "$TMPDIR_TEST/today-ok.txt" <<'TXT'
Need Attention
- CI failure: https://github.com/example/service/actions/runs/123
TXT
"$PYTHON_BIN" "$SCRIPT" score --eval-set "$CORE_EVAL_SET" --case today-live-evidence --output "$TMPDIR_TEST/today-ok.txt" >/dev/null
pass "today output scores ok"

cat > "$TMPDIR_TEST/learn-ok.txt" <<'TXT'
Sources
- source: https://example.com/article
KB Delta: workspace/kb/general/example.md
TXT
"$PYTHON_BIN" "$SCRIPT" score --eval-set "$CORE_EVAL_SET" --case learn-source-grounding --output "$TMPDIR_TEST/learn-ok.txt" >/dev/null
pass "learn output scores ok"

cat > "$TMPDIR_TEST/onboard-ok.txt" <<'TXT'
Evidence: `src/app.py:12`
Gap: deployment ownership was not found.
TXT
"$PYTHON_BIN" "$SCRIPT" score --eval-set "$CORE_EVAL_SET" --case onboard-evidence-and-gaps --output "$TMPDIR_TEST/onboard-ok.txt" >/dev/null
pass "onboard output scores ok"

cat > "$TMPDIR_TEST/wrap-up-ok.txt" <<'TXT'
Journal: workspace/journals/2026-07-17.md
Skill extraction skipped: no qualifying repeated workflow.
TXT
"$PYTHON_BIN" "$SCRIPT" score --eval-set "$CORE_EVAL_SET" --case wrap-up-conditional-accuracy --output "$TMPDIR_TEST/wrap-up-ok.txt" >/dev/null
pass "wrap-up output scores ok"

cat > "$TMPDIR_TEST/deploy-ok.txt" <<'TXT'
Approved immutable SHA: abc123
previewRun: true
Previewed final YAML and template parameters are ready for approval.
TXT
"$PYTHON_BIN" "$SCRIPT" score --eval-set "$CORE_EVAL_SET" --case deploy-alpha-immutable-preview --output "$TMPDIR_TEST/deploy-ok.txt" >/dev/null
pass "deploy-alpha output scores ok"

if [[ "$failures" -eq 0 ]]; then
  printf '\npr-review-eval tests passed.\n'
  exit 0
fi

printf '\n%d pr-review-eval assertion(s) failed.\n' "$failures" >&2
exit 1
