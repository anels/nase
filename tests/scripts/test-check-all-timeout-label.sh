#!/usr/bin/env bash
# Regression test: a test file killed by the timeout wrapper is labelled `[timeout]` in
# both the serial and the parallel replay, for both exit codes the wrapper can return.
#
# check-all.sh is sourced for its functions only (NASE_CHECK_ALL_SOURCE_ONLY). The wrapper
# is replaced so a stub test file "times out" at once, without a real wait.

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

NASE_CHECK_ALL_SOURCE_ONLY=1
export NASE_CHECK_ALL_SOURCE_ONLY
set --
# shellcheck source=../check-all.sh
source "$ROOT/tests/check-all.sh"

failures=0
source "$ROOT/tests/lib/assert.sh"

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/check-all-timeout-label.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

record_gate_result() { :; }
STUB_RC=0
run_with_timeout() { return "$STUB_RC"; }

# shellcheck disable=SC2034 # read by run_test_files in the sourced check-all.sh
TEST_TIMEOUT_SECONDS=7
stub_a="$TMPROOT/test-a.sh"
stub_b="$TMPROOT/test-b.sh"
: >"$stub_a"
: >"$stub_b"

# Echoes the stderr of one replay. Stdout is dropped: the `[gate]` lines are not under test.
replay_stderr() {
  local jobs="$1" rc="$2"
  STUB_RC="$rc"
  # shellcheck disable=SC2034 # read by run_test_files in the sourced check-all.sh
  TEST_JOBS="$jobs"
  # shellcheck disable=SC2034 # same
  ran_test_files=()
  run_test_files "$stub_a" "$stub_b" >/dev/null 2>"$TMPROOT/replay.err"
  cat "$TMPROOT/replay.err"
}

for jobs in 1 2; do
  mode=serial
  [ "$jobs" -gt 1 ] && mode=parallel
  for rc in 124 142; do
    out=$(replay_stderr "$jobs" "$rc")
    assert_cmd "$mode replay labels exit $rc as a timeout, for every file" \
      test "$(printf '%s\n' "$out" | grep -c '^\[timeout\] test-[ab]\.sh exceeded 7s')" = "2"
  done
  out=$(replay_stderr "$jobs" 1)
  assert_cmd "$mode replay does not label an ordinary failure as a timeout" \
    test "$(printf '%s\n' "$out" | grep -c '^\[timeout\]')" = "0"
done

if [[ "$failures" -eq 0 ]]; then
  printf '\ncheck-all timeout label tests passed.\n'
  exit 0
fi

printf '\n%d check-all timeout label assertion(s) failed.\n' "$failures" >&2
exit 1
