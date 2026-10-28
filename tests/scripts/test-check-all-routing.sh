#!/usr/bin/env bash
# Regression test for the `--changed` path routing in tests/check-all.sh.
#
# check-all.sh is sourced for its functions only (NASE_CHECK_ALL_SOURCE_ONLY). Every
# runner is replaced with a recorder, so each case asserts which gates a given set of
# changed files selects without running any of them.

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

NASE_CHECK_ALL_SOURCE_ONLY=1
export NASE_CHECK_ALL_SOURCE_ONLY
set --
# shellcheck source=../check-all.sh
source "$ROOT/tests/check-all.sh"

# check-all.sh owns a `failures` array; reset it to the counter assert.sh expects.
failures=0
source "$ROOT/tests/lib/assert.sh"

CHANGED=""
RAN=()
collect_changed_files() { printf '%s\n' "$CHANGED"; }
section() { :; }
run_gate() { RAN+=("gate:$1"); }
record() { RAN+=("$1"); }
run_hook_tests() { record hook-tests; }
run_script_tests() { record script-tests; }
run_skill_bash_blocks() { record skill-bash-blocks; }
run_skill_overlap() { record skill-overlap; }
run_shared_doc_bash_blocks() { record doc-bash-blocks; }
run_kb_domain_map_contract() { record kb-domain-map; }
run_canonical_pointers() { record canonical-pointers; }
run_effort_pointer_integrity() { record effort-pointers; }
run_evals() { record evals; }

route() {
  CHANGED="$1"
  RAN=()
  run_changed_extras >/dev/null
}

ran() {
  local want="$1" item
  for item in "${RAN[@]+"${RAN[@]}"}"; do
    [[ "$item" == "$want" || "$item" == "$want"* ]] && return 0
  done
  return 1
}

expect_runs() {
  local name="$1" changed="$2" want="$3"
  route "$changed"
  if ran "$want"; then pass "$name"; else fail "$name (ran: ${RAN[*]+"${RAN[*]}"})"; fi
}

expect_skips() {
  local name="$1" changed="$2" unwanted="$3"
  route "$changed"
  if ran "$unwanted"; then fail "$name (ran: ${RAN[*]})"; else pass "$name"; fi
}

# Read by run_shellcheck_changed, which lives in the sourced check-all.sh.
# shellcheck disable=SC2034
SHELLCHECK_BIN=/bin/true
# shellcheck disable=SC2034
SHELLCHECK_SKIP=""

expect_runs "a changed shell file is shellchecked" "tests/check-boundary-terms.sh" "gate:shellcheck 1 changed shell file(s)"
expect_runs "a changed hook is shellchecked" ".claude/hooks/session-start.sh" "gate:shellcheck 1 changed shell file(s)"
expect_skips "a non-shell change is not shellchecked" "README.md" "gate:shellcheck"
expect_skips "a deleted shell file is not shellchecked" "tests/scripts/test-does-not-exist.sh" "gate:shellcheck"

expect_runs "command-only edit triggers script tests" ".claude/commands/nase/design.md" "script-tests"
expect_runs "shared-doc-only edit triggers script tests" ".claude/docs/plain-writing-guard.md" "script-tests"
expect_runs "roles.yaml edit triggers script tests" ".claude/roles.yaml" "script-tests"
expect_runs "workflow edit triggers script tests" ".github/workflows/validate.yml" "script-tests"
expect_runs "a gate script edit triggers script tests" "tests/check-shared-doc-refs.sh" "script-tests"
expect_runs "settings.json edit triggers hook tests" ".claude/settings.json" "hook-tests"
expect_runs "check-all.sh edit still triggers script tests" "tests/check-all.sh" "script-tests"
expect_runs "script edit still triggers script tests" ".claude/scripts/pr-github-helper.py" "script-tests"

expect_skips "settings.local.json does not trigger hook tests" ".claude/settings.local.json" "hook-tests"
expect_skips "an unrelated top-level file triggers no script tests" "LICENSE" "script-tests"

if [[ "$failures" -ne 0 ]]; then
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi
printf '\nAll check-all routing tests passed.\n'
