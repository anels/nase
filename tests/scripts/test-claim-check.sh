#!/usr/bin/env bash
# Regression tests for .claude/scripts/claim-check.py
#
# Run from repo root: bash tests/scripts/test-claim-check.sh

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/claim-check.py"
FIX="$ROOT/tests/fixtures/transcripts"

pass=0
fail=0

ok() { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL  %s%s\n' "$1" "${2:+: $2}" >&2; fail=$((fail+1)); }

run_case() {
  # $1 fixture, $2 expected: silent|warn
  local fx="$1" expected="$2" out rc
  out=$(printf '{"transcript_path":"%s/%s","session_id":"s1"}' "$FIX" "$fx" | python3 "$SCRIPT" 2>&1) || rc=$?
  rc=${rc:-0}
  if [ "$expected" = "silent" ]; then
    if [ -z "$out" ]; then ok "$fx -> silent"; else bad "$fx -> silent" "$out"; fi
  else
    if [ -n "$out" ] && grep -q "claim-check" <<<"$out"; then ok "$fx -> warn"; else bad "$fx -> warn" "$out"; fi
  fi
}

run_case "a-proven.jsonl" "silent"
run_case "b-no-run.jsonl" "warn"
run_case "c-fail-run.jsonl" "warn"
run_case "d-edit-after.jsonl" "warn"
run_case "e-malformed.jsonl" "warn"
run_case "f-bash-edit-after.jsonl" "warn"
run_case "g-ls-makefile.jsonl" "warn"
run_case "h-pipe-tail.jsonl" "warn"

# hostile session id must not escape workspace/tmp
nroot=$(mktemp -d)
printf '{"transcript_path":"%s/b-no-run.jsonl","session_id":"../../x"}' "$FIX" | NASE_ROOT="$nroot" python3 "$SCRIPT" >/dev/null 2>&1
if [ -z "$(find "$nroot" -name 'claim-check-*.state' -not -path "$nroot/workspace/tmp/*")" ] \
  && [ -n "$(find "$nroot/workspace/tmp" -name 'claim-check-*.state' 2>/dev/null)" ] \
  && [ ! -e "$nroot/../x.state" ]; then
  ok "hostile session id stays inside workspace/tmp"
else
  bad "hostile session id stays inside workspace/tmp" "$(find "$nroot" -type f)"
fi
rm -rf "$nroot"

# table-driven is_verify_run / is_bash_edit
table_out=$(python3 - "$SCRIPT" 2>&1 <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cc", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

VERIFY = {
    "pytest -q": True,
    "cd x && pytest": True,
    "FOO=1 python3 -m pytest -x": True,
    "uv run pytest": True,
    "time pytest -q 2>&1": True,
    "make": True,
    "make test && echo ok": True,
    "npm run build": True,
    "bash tests/check-all.sh": True,
    "set -o pipefail; pytest -q | tail -3": True,
    "set -o pipefail && pytest -q | tail -3": True,
    "ls Makefile": False,
    "cat mypy.ini": False,
    "grep tox x": False,
    "git log --grep pytest": False,
    "pytest -q | tail -3": False,
    "pytest; echo done": False,
    "pytest || true": False,
    "make\nls": False,
    "npm run test:unit": True,
    "npm run lint:fix": True,
    "npm run build:prod": True,
    "yarn test:ci": True,
    "pytest &": False,
    "echo 'unterminated": False,
    "": False,
}
EDIT = {
    "sed -i '' s/a/b/ f": True,
    "perl -pi -e s/a/b/ f": True,
    "echo hi > a.txt": True,
    "echo hi >> a.txt": True,
    "cat f | tee g": True,
    "git apply x.patch": True,
    "git checkout -- f": True,
    "git stash": True,
    "patch -p1 < x": True,
    "git stash push -m wip": True,
    "git stash pop": True,
    "git stash": True,
    "git restore f": True,
    "git restore --staged --worktree f": True,
    "git -C repo apply x.patch": True,
    "echo hi | tee out.txt": True,
    "echo hi > 'a b.txt'": True,
    "gh pr create --title 'x -> main'": False,
    "git commit -m 'feat: x -> y'": False,
    "git commit -m \"a => b\"": False,
    "echo a>b": True,
    "echo 'a>b'": False,
    "jq '.a>1' f": False,
    "git stash list": False,
    "git stash show -p": False,
    "git restore --staged f": False,
    "git log | tee /tmp/x": False,
    "git log | tee": False,
    "echo tee": False,
    "grep tee f": False,
    "perl -Mstrict -e 1": False,
    "ls 2>&1 | head": False,
    "cmd >&2": False,
    "cmd &> /dev/null": False,
    "sed -n 1,3p f": False,
    "grep -i foo f": False,
    "ls > /dev/null": False,
    "pytest > /tmp/o": False,
    "pytest 2>&1": False,
    "pytest 2>/dev/null": False,
    "": False,
}
bad = []
for cmd, want in VERIFY.items():
    if m.is_verify_run(cmd) != want:
        bad.append(f"is_verify_run({cmd!r}) != {want}")
for cmd, want in EDIT.items():
    if m.is_bash_edit(cmd) != want:
        bad.append(f"is_bash_edit({cmd!r}) != {want}")
print("\n".join(bad))
PY
)
if [ -z "$table_out" ]; then ok "is_verify_run / is_bash_edit table"; else bad "is_verify_run / is_bash_edit table" "$table_out"; fi

# missing transcript path -> silent, no crash
out=$(printf '{"session_id":"s2"}' | python3 "$SCRIPT" 2>&1) || rc=$?
rc=${rc:-0}
if [ -z "$out" ] && [ "$rc" -eq 0 ]; then ok "missing transcript -> silent"; else bad "missing transcript -> silent" "$out"; fi

# non-existent transcript -> silent, no crash
out=$(printf '{"transcript_path":"/no/such/file.jsonl","session_id":"s3"}' | python3 "$SCRIPT" 2>&1) || rc=$?
rc=${rc:-0}
if [ -z "$out" ] && [ "$rc" -eq 0 ]; then ok "missing file -> silent"; else bad "missing file -> silent" "$out"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
