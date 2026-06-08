#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

HOOK="$ROOT/.claude/hooks/post-edit-shellcheck.sh"
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
  local file_path="$1" output="$2" rc_file="$3"
  set +e
  bash "$HOOK" >"$output.out" 2>"$output.err" <<JSON
{"tool_input":{"file_path":"$file_path"}}
JSON
  printf '%s\n' "$?" >"$rc_file"
  set -e
}

mkdir -p "$TMPDIR_TEST"
cat >"$TMPDIR_TEST/good.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "ok"
SH

cat >"$TMPDIR_TEST/bad.sh" <<'SH'
#!/usr/bin/env bash
if true; then
  echo ok
SH

printf 'not shell\n' >"$TMPDIR_TEST/note.txt"

run_hook "$TMPDIR_TEST/good.sh" "$TMPDIR_TEST/good" "$TMPDIR_TEST/good.rc"
assert_cmd "valid shell file passes" test "$(cat "$TMPDIR_TEST/good.rc")" = "0"
assert_cmd "valid shell file has no stderr" test ! -s "$TMPDIR_TEST/good.err"

run_hook "$TMPDIR_TEST/bad.sh" "$TMPDIR_TEST/bad" "$TMPDIR_TEST/bad.rc"
assert_cmd "invalid shell file blocks" test "$(cat "$TMPDIR_TEST/bad.rc")" = "2"
assert_cmd "invalid shell file reports shellcheck" grep -q 'shellcheck' "$TMPDIR_TEST/bad.err"

run_hook "$TMPDIR_TEST/note.txt" "$TMPDIR_TEST/txt" "$TMPDIR_TEST/txt.rc"
assert_cmd "non-shell file skipped" test "$(cat "$TMPDIR_TEST/txt.rc")" = "0"
assert_cmd "non-shell file has no output" sh -c "test ! -s '$TMPDIR_TEST/txt.out' && test ! -s '$TMPDIR_TEST/txt.err'"

if [[ "$failures" -eq 0 ]]; then
  printf '\npost-edit-shellcheck tests passed.\n'
  exit 0
fi

printf '\n%d post-edit-shellcheck assertion(s) failed.\n' "$failures" >&2
exit 1
