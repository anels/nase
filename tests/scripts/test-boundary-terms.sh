#!/usr/bin/env bash
# Regression test for tests/check-boundary-terms.sh.
#
# Every case runs against a throwaway git repo via NASE_BOUNDARY_SCAN_ROOT, so
# the suite can hold probes that MUST fail. A gate that has only ever been seen
# passing on a clean tree is an assertion, not a guard.

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

GATE="$ROOT/tests/check-boundary-terms.sh"
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

failures=0
source "$ROOT/tests/lib/assert.sh"

# Assemble the probe term at runtime. A literal internal term in a tracked test
# file is the exact thing this gate exists to stop.
PROBE_TIER1="Acme""Corp"
PROBE_TIER2="Ware""house9"
PROBE_EXEMPT="Public ${PROBE_TIER1}"

new_repo() {
  local name="$1" repo="$TMPROOT/$1"
  mkdir -p "$repo/workspace"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name t
  printf 'workspace/\n' >"$repo/.gitignore"
  printf '%s\n' "$repo"
}

write_terms() {
  local repo="$1"
  {
    printf '# probe list\n'
    printf '0\t%s\n' "$PROBE_EXEMPT"
    printf '1\t%s\n' "$PROBE_TIER1"
    printf '2\t%s\n' "$PROBE_TIER2"
  } >"$repo/workspace/boundary-terms.txt"
}

run_gate() {
  local repo="$1" tag="$2"
  set +e
  NASE_BOUNDARY_SCAN_ROOT="$repo" bash "$GATE" >"$TMPROOT/$tag.out" 2>"$TMPROOT/$tag.err"
  printf '%s\n' "$?" >"$TMPROOT/$tag.rc"
  set -e
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -qm probe
}

# --- 1. clean tracked tree passes ---
repo=$(new_repo clean)
write_terms "$repo"
printf 'nothing to see here\n' >"$repo/doc.md"
commit_all "$repo"
run_gate "$repo" clean
assert_cmd "clean tracked tree passes" test "$(cat "$TMPROOT/clean.rc")" = "0"

# --- 2. tier 1 term in a tracked file fails (the probe that must fail) ---
repo=$(new_repo tier1)
write_terms "$repo"
printf 'owned by %s today\n' "$PROBE_TIER1" >"$repo/doc.md"
commit_all "$repo"
run_gate "$repo" tier1
assert_cmd "tier 1 term in a tracked file fails" test "$(cat "$TMPROOT/tier1.rc")" = "1"
assert_cmd "finding names the path and line" grep -q 'doc.md:1' "$TMPROOT/tier1.err"
assert_cmd "finding names the tier" grep -q 'tier 1' "$TMPROOT/tier1.err"

# --- 3. the matched term is never rendered ---
assert_cmd "matched term is redacted in the finding" \
  bash -c "! grep -q '$PROBE_TIER1' '$TMPROOT/tier1.err'"
assert_cmd "redacted fingerprint is shown instead" \
  grep -q "${PROBE_TIER1:0:1}\*\*" "$TMPROOT/tier1.err"

# --- 4. tier 2 term also fails, and reports its own tier ---
repo=$(new_repo tier2)
write_terms "$repo"
printf 'runs on %s\n' "$PROBE_TIER2" >"$repo/doc.md"
commit_all "$repo"
run_gate "$repo" tier2
assert_cmd "tier 2 term in a tracked file fails" test "$(cat "$TMPROOT/tier2.rc")" = "1"
assert_cmd "tier 2 finding reports tier 2" grep -q 'tier 2' "$TMPROOT/tier2.err"

# --- 5. an untracked file is out of scope ---
repo=$(new_repo untracked)
write_terms "$repo"
printf 'clean\n' >"$repo/doc.md"
commit_all "$repo"
printf 'owned by %s\n' "$PROBE_TIER1" >"$repo/scratch.md"
run_gate "$repo" untracked
assert_cmd "untracked file is out of scope" test "$(cat "$TMPROOT/untracked.rc")" = "0"

# --- 6. the git-ignored workspace tree is out of scope ---
repo=$(new_repo ignored)
write_terms "$repo"
printf 'clean\n' >"$repo/doc.md"
commit_all "$repo"
printf 'owned by %s\n' "$PROBE_TIER1" >"$repo/workspace/notes.md"
run_gate "$repo" ignored
assert_cmd "git-ignored workspace is out of scope" test "$(cat "$TMPROOT/ignored.rc")" = "0"

# --- 7. an exempt phrase suppresses the term inside it ---
repo=$(new_repo exempt)
write_terms "$repo"
printf 'see %s for details\n' "$PROBE_EXEMPT" >"$repo/doc.md"
commit_all "$repo"
run_gate "$repo" exempt
assert_cmd "exempt phrase suppresses the term inside it" test "$(cat "$TMPROOT/exempt.rc")" = "0"

# --- 8. the exemption does not leak to a bare use of the same term ---
repo=$(new_repo exempt-bare)
write_terms "$repo"
printf 'see %s and also bare %s\n' "$PROBE_EXEMPT" "$PROBE_TIER1" >"$repo/doc.md"
commit_all "$repo"
run_gate "$repo" exempt-bare
assert_cmd "bare term still fails alongside an exempt phrase" \
  test "$(cat "$TMPROOT/exempt-bare.rc")" = "1"

# --- 9. matching is whole-word and case-sensitive ---
repo=$(new_repo wholeword)
write_terms "$repo"
{
  printf 'lowercase %s is a different token\n' "$(printf '%s' "$PROBE_TIER1" | tr 'A-Z' 'a-z')"
  printf 'and %sish is not a whole word\n' "$PROBE_TIER1"
} >"$repo/doc.md"
commit_all "$repo"
run_gate "$repo" wholeword
assert_cmd "different casing and suffixed word do not fire" \
  test "$(cat "$TMPROOT/wholeword.rc")" = "0"

# --- 10. absent term list skips instead of failing (fresh clone) ---
repo=$(new_repo nolist)
printf 'owned by %s\n' "$PROBE_TIER1" >"$repo/doc.md"
commit_all "$repo"
run_gate "$repo" nolist
assert_cmd "absent term list skips" test "$(cat "$TMPROOT/nolist.rc")" = "0"
assert_cmd "skip is announced" grep -q 'SKIP' "$TMPROOT/nolist.out"

# --- 11. a malformed term list is a hard error, not a silent pass ---
repo=$(new_repo malformed)
printf '3\tBogusTier\n' >"$repo/workspace/boundary-terms.txt"
printf 'clean\n' >"$repo/doc.md"
commit_all "$repo"
run_gate "$repo" malformed
assert_cmd "malformed term list exits 2" test "$(cat "$TMPROOT/malformed.rc")" = "2"

# --- 12. a term list with only exempt phrases is a hard error ---
repo=$(new_repo exempt-only)
printf '0\t%s\n' "$PROBE_EXEMPT" >"$repo/workspace/boundary-terms.txt"
printf 'clean\n' >"$repo/doc.md"
commit_all "$repo"
run_gate "$repo" exempt-only
assert_cmd "term list with no tier 1 or 2 terms exits 2" \
  test "$(cat "$TMPROOT/exempt-only.rc")" = "2"

# --- 13. the real tree is clean right now ---
set +e
bash "$GATE" >"$TMPROOT/real.out" 2>"$TMPROOT/real.err"
real_rc=$?
set -e
assert_cmd "the real tracked tree passes the gate" test "$real_rc" = "0"

exit "$failures"
