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
run_effort_pointer_integrity() { record effort-pointers; }
run_evals() { record evals; }

route() {
  CHANGED="$1"
  RAN=()
  run_changed_extras >/dev/null
}

# Exact match. A prefix match let `gate:shellcheck` pass for any `gate:shellcheck-*` label
# and let `script-tests` pass for `script-tests-extra`.
ran() {
  local want="$1" item
  for item in "${RAN[@]+"${RAN[@]}"}"; do
    [[ "$item" == "$want" ]] && return 0
  done
  return 1
}

# Only for labels that carry a count suffix, like `gate:shellcheck 1 changed shell file(s)`.
ran_prefix() {
  local want="$1" item
  for item in "${RAN[@]+"${RAN[@]}"}"; do
    [[ "$item" == "$want"* ]] && return 0
  done
  return 1
}

expect_runs() {
  local name="$1" changed="$2" want="$3"
  route "$changed"
  if ran "$want"; then pass "$name"; else fail "$name (ran: ${RAN[*]+"${RAN[*]}"})"; fi
}

expect_runs_prefix() {
  local name="$1" changed="$2" want="$3"
  route "$changed"
  if ran_prefix "$want"; then pass "$name"; else fail "$name (ran: ${RAN[*]+"${RAN[*]}"})"; fi
}

expect_skips() {
  local name="$1" changed="$2" unwanted="$3"
  route "$changed"
  if ran "$unwanted"; then fail "$name (ran: ${RAN[*]})"; else pass "$name"; fi
}

expect_skips_prefix() {
  local name="$1" changed="$2" unwanted="$3"
  route "$changed"
  if ran_prefix "$unwanted"; then fail "$name (ran: ${RAN[*]})"; else pass "$name"; fi
}

# Read by run_shellcheck_changed, which lives in the sourced check-all.sh.
# shellcheck disable=SC2034
SHELLCHECK_BIN=/bin/true
# shellcheck disable=SC2034
SHELLCHECK_SKIP=""

expect_runs_prefix "a changed shell file is shellchecked" "tests/check-boundary-terms.sh" "gate:shellcheck 1 changed shell file(s)"
expect_runs_prefix "a changed hook is shellchecked" ".claude/hooks/session-start.sh" "gate:shellcheck 1 changed shell file(s)"
expect_skips_prefix "a non-shell change is not shellchecked" "README.md" "gate:shellcheck"
expect_skips_prefix "a deleted shell file is not shellchecked" "tests/scripts/test-does-not-exist.sh" "gate:shellcheck"

expect_runs "command-only edit triggers script tests" ".claude/commands/nase/design.md" "script-tests"
expect_runs "shared-doc-only edit triggers script tests" ".claude/docs/plain-writing-guard.md" "script-tests"
expect_runs "roles.yaml edit triggers script tests" ".claude/roles.yaml" "script-tests"
expect_runs "workflow edit triggers script tests" ".github/workflows/validate.yml" "script-tests"
expect_runs "a gate script edit triggers script tests" "tests/check-shared-doc-refs.sh" "script-tests"
expect_runs "settings.json edit triggers hook tests" ".claude/settings.json" "hook-tests"
expect_runs "check-all.sh edit still triggers script tests" "tests/check-all.sh" "script-tests"
expect_runs "script edit still triggers script tests" ".claude/scripts/pr-github-helper.py" "script-tests"

expect_runs "a command edit triggers the subagent dispatch check" ".claude/commands/nase/design.md" "gate:check-subagent-dispatch.sh"
expect_runs "a shared-doc edit triggers the subagent dispatch check" ".claude/docs/plain-writing-guard.md" "gate:check-subagent-dispatch.sh"
expect_runs "editing the dispatch check triggers it" "tests/check-subagent-dispatch.sh" "gate:check-subagent-dispatch.sh"
expect_skips "an unrelated edit does not trigger the dispatch check" "LICENSE" "gate:check-subagent-dispatch.sh"

expect_skips "settings.local.json does not trigger hook tests" ".claude/settings.local.json" "hook-tests"
expect_skips "an unrelated top-level file triggers no script tests" "LICENSE" "script-tests"

# --- tier coverage: every tests/check-*.sh gate runs in --fast and --full ---
# A gate script that no tier calls is dead weight that reads as coverage (check-subagent-dispatch.sh
# sat unwired for exactly this reason). Re-source check-all.sh in a subshell so the recorder
# overrides above do not leak, replace run_gate with a recorder that prints the gate label,
# and stub the two runners that would otherwise start test files or lychee.
tier_gates() {
  local tier="$1"
  (
    NASE_CHECK_ALL_SOURCE_ONLY=1
    set --
    # shellcheck source=../check-all.sh
    source "$ROOT/tests/check-all.sh"
    section() { :; }
    run_gate() { printf '%s\n' "$1"; }
    run_test_files() { :; }
    run_lychee() { :; }
    "run_$tier"
  )
}

# check-local-sensitive-artifacts.sh scans git-ignored local debug artifacts under
# workspace/, which does not exist in CI or a fresh checkout, so it is full-tier only.
FAST_EXEMPT=" check-local-sensitive-artifacts.sh "

for tier in fast full; do
  gates=$(tier_gates "$tier")
  for gate_file in "$ROOT"/tests/check-*.sh; do
    gate=$(basename "$gate_file")
    [[ "$gate" == "check-all.sh" ]] && continue
    if [[ "$tier" == fast && "$FAST_EXEMPT" == *" $gate "* ]]; then
      continue
    fi
    if grep -qxF "$gate" <<< "$gates"; then
      pass "$gate runs in --$tier"
    else
      fail "$gate does not run in --$tier"
    fi
  done
done

# --- hook wiring: every registered hook must be named in docs/architecture.md ---
wiring_dir="$(mktemp -d)"
trap 'rm -rf "$wiring_dir"' EXIT
cp "$ROOT/.claude/settings.json" "$wiring_dir/settings.json"
cp "$ROOT/docs/architecture.md" "$wiring_dir/architecture.md"
if check_hook_wiring "$wiring_dir/settings.json" "$wiring_dir/architecture.md" >/dev/null 2>&1; then
  pass "hook wiring passes on a pristine copy of settings.json and architecture.md"
else
  fail "hook wiring passes on a pristine copy of settings.json and architecture.md"
fi
registered=$(grep -oE '[A-Za-z0-9_-]+\.sh' "$wiring_dir/settings.json" | grep -vx 'hook-dispatch.sh' | sort -u | head -1)
grep -vF "$registered" "$ROOT/docs/architecture.md" >"$wiring_dir/architecture.md" || true
if wiring_err=$(check_hook_wiring "$wiring_dir/settings.json" "$wiring_dir/architecture.md" 2>&1 >/dev/null); then
  fail "hook wiring fails when $registered is missing from the architecture doc"
elif [[ "$wiring_err" == *"$registered is registered in settings.json but not named in"* ]]; then
  pass "hook wiring fails and names $registered when the architecture doc omits it"
else
  fail "hook wiring failed but did not name $registered (got: $wiring_err)"
fi

if [[ "$failures" -ne 0 ]]; then
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi
printf '\nAll check-all routing tests passed.\n'
