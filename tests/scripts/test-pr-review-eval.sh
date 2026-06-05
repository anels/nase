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

Could you help review this? https://github.com/example/service/pull/126 — this mainly fixes stale cache invalidation
Slack draft is staged only after confirmation.
TXT
"$PYTHON_BIN" "$SCRIPT" score --eval-set "$EVAL_SET" --case request-review-draft-style --output "$TMPDIR_TEST/request-ok.txt" >/dev/null
pass "request-review draft output scores ok"

if [[ "$failures" -eq 0 ]]; then
  printf '\npr-review-eval tests passed.\n'
  exit 0
fi

printf '\n%d pr-review-eval assertion(s) failed.\n' "$failures" >&2
exit 1
