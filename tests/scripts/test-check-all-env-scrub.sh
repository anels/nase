#!/usr/bin/env bash
# Regression test for the hermetic-environment block at the top of tests/check-all.sh.
#
# A developer shell that exports NASE_PROSE_LINT=0 (or any other NASE_* switch) used to turn
# prose-lint, daily-log and fact-force tests red, and a global git config changed what every
# git-fixture test saw. check-all.sh now drops NASE_* variables and isolates git config.
# Each case runs in a child bash so the scrub cannot leak into this test.

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

failures=0
source "$ROOT/tests/lib/assert.sh"

# Sources check-all.sh in source-only mode and prints the state the child ended with.
probe() {
  env "$@" bash -c '
    cd "$1"
    set --
    NASE_CHECK_ALL_SOURCE_ONLY=1
    source tests/check-all.sh
    printf "PROSE=%s\n" "${NASE_PROSE_LINT-unset}"
    printf "DAILY=%s\n" "${NASE_DAILY_LOG_GUARD-unset}"
    printf "FACT=%s\n" "${NASE_FACT_FORCE-unset}"
    printf "CUSTOM=%s\n" "${NASE_SOMETHING_NEW-unset}"
    printf "JOBS=%s\n" "${NASE_TEST_JOBS-unset}"
    printf "TIMEOUT=%s\n" "${NASE_TEST_TIMEOUT-unset}"
    printf "SOURCE_ONLY=%s\n" "${NASE_CHECK_ALL_SOURCE_ONLY-unset}"
    printf "GIT_GLOBAL=%s\n" "${GIT_CONFIG_GLOBAL-unset}"
    printf "GIT_NOSYSTEM=%s\n" "${GIT_CONFIG_NOSYSTEM-unset}"
  ' _ "$ROOT"
}

out=$(probe NASE_PROSE_LINT=0 NASE_DAILY_LOG_GUARD=0 NASE_FACT_FORCE=0 NASE_SOMETHING_NEW=1 \
  NASE_TEST_JOBS=3 NASE_TEST_TIMEOUT=77)

assert_has() {
  local name="$1" line="$2"
  if grep -qxF "$line" <<<"$out"; then pass "$name"; else fail "$name (wanted: $line; got: $(tr '\n' ' ' <<<"$out"))"; fi
}

assert_has "NASE_PROSE_LINT is dropped" "PROSE=unset"
assert_has "NASE_DAILY_LOG_GUARD is dropped" "DAILY=unset"
assert_has "NASE_FACT_FORCE is dropped" "FACT=unset"
assert_has "an unlisted NASE_* variable is dropped, not just the known ones" "CUSTOM=unset"
assert_has "NASE_TEST_JOBS survives" "JOBS=3"
assert_has "NASE_TEST_TIMEOUT survives" "TIMEOUT=77"
assert_has "NASE_CHECK_ALL_SOURCE_ONLY survives" "SOURCE_ONLY=1"
assert_has "git global config is isolated" "GIT_GLOBAL=/dev/null"
assert_has "git system config is isolated" "GIT_NOSYSTEM=1"

# The scrub must neutralise the live user config, not just set the variable: point the
# global config at a file that would rewrite the default branch and show git ignores it.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
printf '[init]\n\tdefaultBranch = leaked-from-global\n' >"$scratch/gitconfig"
branch=$(env GIT_CONFIG_GLOBAL="$scratch/gitconfig" bash -c '
  cd "$1"
  scratch=$2
  set --
  NASE_CHECK_ALL_SOURCE_ONLY=1
  source tests/check-all.sh
  git init -q "$scratch/repo"
  git -C "$scratch/repo" symbolic-ref --short HEAD
' _ "$ROOT" "$scratch")
if [[ "$branch" != "leaked-from-global" ]]; then
  pass "a global git config set before check-all.sh no longer reaches git"
else
  fail "a global git config set before check-all.sh still reaches git (branch: $branch)"
fi

# Mutation: without the scrub block the same probe must report the leak, otherwise the
# assertions above would pass on a check-all.sh that does nothing.
mutant="$scratch/check-all-no-scrub.sh"
awk '
  /^# Hermetic environment\./ { skip = 1 }
  skip && /^export GIT_CONFIG_GLOBAL=/ { skip = 0; next }
  !skip { print }
' "$ROOT/tests/check-all.sh" >"$mutant"
if grep -q 'compgen -e' "$mutant"; then
  fail "mutation harness did not remove the scrub block"
else
  leaked=$(env NASE_PROSE_LINT=0 bash -c '
    cd "$1"
    mutant=$2
    set --
    NASE_CHECK_ALL_SOURCE_ONLY=1
    source "$mutant"
    printf "%s" "${NASE_PROSE_LINT-unset}"
  ' _ "$ROOT" "$mutant")
  if [[ "$leaked" == "0" ]]; then
    pass "mutation: without the scrub block NASE_PROSE_LINT leaks through"
  else
    fail "mutation: without the scrub block NASE_PROSE_LINT should leak (got: $leaked)"
  fi
fi

if [[ "$failures" -ne 0 ]]; then
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi
printf '\nAll check-all env-scrub tests passed.\n'
