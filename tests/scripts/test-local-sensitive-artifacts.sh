#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

SCAN="$ROOT/tests/check-local-sensitive-artifacts.sh"
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

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

run_scan() {
  local root="$1" output="$2" rc_file="$3"
  set +e
  NASE_SENSITIVE_SCAN_ROOT="$root" bash "$SCAN" >"$output.out" 2>"$output.err"
  printf '%s\n' "$?" >"$rc_file"
  set -e
}

run_scan "$TMPROOT" "$TMPROOT/empty" "$TMPROOT/empty.rc"
assert_cmd "empty temp root passes" test "$(cat "$TMPROOT/empty.rc")" = "0"

fake_bearer='Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.fakePayload.fakeSignature # pragma: allowlist secret'

mkdir -p "$TMPROOT/.omc/sessions"
printf '%s\n' "$fake_bearer" >"$TMPROOT/.omc/sessions/request.log"

run_scan "$TMPROOT" "$TMPROOT/hit" "$TMPROOT/hit.rc"
assert_cmd ".omc bearer token fails scan" test "$(cat "$TMPROOT/hit.rc")" = "1"
assert_cmd ".omc path is reported" grep -q '.omc/sessions/request.log' "$TMPROOT/hit.err"

md_root="$TMPROOT/markdown-log-root"
mkdir -p "$md_root/workspace/logs"
printf '%s\n' "$fake_bearer" >"$md_root/workspace/logs/2026-06-10.md"

run_scan "$md_root" "$TMPROOT/md-log" "$TMPROOT/md-log.rc"
assert_cmd "markdown daily log bearer token fails scan" test "$(cat "$TMPROOT/md-log.rc")" = "1"
assert_cmd "markdown daily log path is reported" grep -q 'workspace/logs/2026-06-10.md' "$TMPROOT/md-log.err"

if [[ "$failures" -eq 0 ]]; then
  printf '\nlocal-sensitive-artifacts tests passed.\n'
  exit 0
fi

printf '\n%d local-sensitive-artifacts assertion(s) failed.\n' "$failures" >&2
exit 1
