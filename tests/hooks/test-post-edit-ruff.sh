#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

HOOK="$ROOT/.claude/hooks/post-edit-ruff.sh"
if ! command -v ruff >/dev/null 2>&1; then
  printf 'SKIP  post-edit-ruff requires ruff for diagnostic assertions\n'
  exit 0
fi

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

failures=0
source "$ROOT/tests/lib/assert.sh"

run_hook() {
  local file_path="$1" output="$2" rc_file="$3"
  set +e
  bash "$HOOK" >"$output.out" 2>"$output.err" <<JSON
{"tool_input":{"file_path":"$file_path"}}
JSON
  printf '%s\n' "$?" >"$rc_file"
  set -e
}

cat >"$TMPDIR_TEST/good.py" <<'PY'
def greet(name: str) -> str:
    return f"hello {name}"
PY

# An undefined name is the exact class of defect `python3 -m py_compile` cannot see,
# which is why this hook exists alongside the compile step.
cat >"$TMPDIR_TEST/bad.py" <<'PY'
def greet(name: str) -> str:
    return f"hello {nmae}"
PY

printf 'not python\n' >"$TMPDIR_TEST/note.txt"

run_hook "$TMPDIR_TEST/good.py" "$TMPDIR_TEST/good" "$TMPDIR_TEST/good.rc"
assert_cmd "valid python file passes" test "$(cat "$TMPDIR_TEST/good.rc")" = "0"
assert_cmd "valid python file has no stderr" test ! -s "$TMPDIR_TEST/good.err"

run_hook "$TMPDIR_TEST/bad.py" "$TMPDIR_TEST/bad" "$TMPDIR_TEST/bad.rc"
assert_cmd "undefined name blocks" test "$(cat "$TMPDIR_TEST/bad.rc")" = "2"
assert_cmd "undefined name reports the linter" grep -q 'ruff' "$TMPDIR_TEST/bad.err"
assert_cmd "undefined name names the rule" grep -q 'F821' "$TMPDIR_TEST/bad.err"

run_hook "$TMPDIR_TEST/note.txt" "$TMPDIR_TEST/txt" "$TMPDIR_TEST/txt.rc"
assert_cmd "non-python file skipped" test "$(cat "$TMPDIR_TEST/txt.rc")" = "0"
assert_cmd "non-python file has no output" sh -c "test ! -s '$TMPDIR_TEST/txt.out' && test ! -s '$TMPDIR_TEST/txt.err'"

if [[ "$failures" -eq 0 ]]; then
  printf '\npost-edit-ruff tests passed.\n'
  exit 0
fi

printf '\n%d post-edit-ruff assertion(s) failed.\n' "$failures" >&2
exit 1
