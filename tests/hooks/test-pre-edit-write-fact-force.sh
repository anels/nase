#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

HOOK="$ROOT/.claude/hooks/pre-edit-write-fact-force.sh"
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

run_hook() {
  local file_path="$1"
  local output="$2"
  CLAUDE_SESSION_ID="test-session" TMPDIR="$TMPDIR_TEST" bash "$HOOK" >"$output.out" 2>"$output.err" <<JSON
{"tool_input":{"file_path":"$file_path"}}
JSON
}

assert_json_context_contains() {
  local output="$1" needle="$2"
  jq -e --arg needle "$needle" \
    '.hookSpecificOutput.hookEventName == "PreToolUse"
      and (.hookSpecificOutput.additionalContext | contains($needle))' \
    "$output" >/dev/null
}

mkdir -p "$TMPDIR_TEST/src" "$TMPDIR_TEST/docs" "$TMPDIR_TEST/tests" "$TMPDIR_TEST/workspace"
touch "$TMPDIR_TEST/src/app.py" "$TMPDIR_TEST/docs/app.py" "$TMPDIR_TEST/tests/app.py" "$TMPDIR_TEST/workspace/app.py"

run_hook "$TMPDIR_TEST/src/app.py" "$TMPDIR_TEST/src-run"
assert_cmd "source edit emits additionalContext reminder" assert_json_context_contains "$TMPDIR_TEST/src-run.out" '[fact-force]'
assert_cmd "source edit does not write stderr" test ! -s "$TMPDIR_TEST/src-run.err"

run_hook "$TMPDIR_TEST/src/app.py" "$TMPDIR_TEST/src-second"
assert_cmd "same file emits no stdout" test ! -s "$TMPDIR_TEST/src-second.out"
assert_cmd "same file only warns once" test ! -s "$TMPDIR_TEST/src-second.err"

(
  cd "$TMPDIR_TEST"
  run_hook "docs/app.py" "$TMPDIR_TEST/docs-run"
  run_hook "tests/app.py" "$TMPDIR_TEST/tests-run"
  run_hook "workspace/app.py" "$TMPDIR_TEST/workspace-run"
)
assert_cmd "relative docs path skipped" test ! -s "$TMPDIR_TEST/docs-run.err"
assert_cmd "relative tests path skipped" test ! -s "$TMPDIR_TEST/tests-run.err"
assert_cmd "relative workspace path skipped" test ! -s "$TMPDIR_TEST/workspace-run.err"

NASE_FACT_FORCE=0 CLAUDE_SESSION_ID="disabled-session" TMPDIR="$TMPDIR_TEST" bash "$HOOK" >"$TMPDIR_TEST/disabled.out" 2>"$TMPDIR_TEST/disabled.err" <<JSON
{"tool_input":{"file_path":"$TMPDIR_TEST/src/app.py"}}
JSON
assert_cmd "NASE_FACT_FORCE emits no stdout" test ! -s "$TMPDIR_TEST/disabled.out"
assert_cmd "NASE_FACT_FORCE disables hook" test ! -s "$TMPDIR_TEST/disabled.err"

if [[ "$failures" -eq 0 ]]; then
  printf '\npre-edit-write-fact-force tests passed.\n'
  exit 0
fi

printf '\n%d pre-edit-write-fact-force assertion(s) failed.\n' "$failures" >&2
exit 1
