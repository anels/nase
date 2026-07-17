#!/usr/bin/env bash
set -u

ROOT=$(git rev-parse --show-toplevel)
HELPER="$ROOT/.claude/scripts/worktree-cleanup.py"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/nase-worktree-cleanup.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

passed=0
failed=0

pass() { printf 'PASS: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

expect_rc() {
  local name=$1 expected=$2
  shift 2
  set +e
  "$@" >"$TMP/out" 2>"$TMP/err"
  local rc=$?
  set -e
  if [[ $rc -eq $expected ]]; then
    pass "$name"
  else
    fail "$name (expected rc $expected, got $rc: $(tr '\n' ' ' <"$TMP/err"))"
  fi
}

new_case() {
  local name=$1
  local base="$TMP/$name"
  mkdir -p "$base"
  git init --bare -q -b main "$base/remote.git"
  git clone -q "$base/remote.git" "$base/repo"
  git -C "$base/repo" config user.name test
  git -C "$base/repo" config user.email test@example.com
  printf 'base\n' >"$base/repo/tracked.txt"
  printf 'ignored/\n' >"$base/repo/.gitignore"
  git -C "$base/repo" add tracked.txt .gitignore
  git -C "$base/repo" commit -qm base
  git -C "$base/repo" push -q origin main
  git -C "$base/repo" worktree add -q -b feature "$base/wt" main
  git -C "$base/wt" push -qu origin feature
  CASE_BASE=$base
  CASE_REPO=$(git -C "$base/repo" rev-parse --show-toplevel)
  CASE_WT=$(git -C "$base/wt" rev-parse --show-toplevel)
  CASE_HEAD=$(git -C "$base/wt" rev-parse HEAD)
}

run_helper() {
  python3 "$HELPER" \
    --repo "$CASE_REPO" \
    --worktree "$CASE_WT" \
    --remote origin \
    --remote-ref refs/heads/feature \
    --expected-head "$CASE_HEAD"
}

linked_worktree_path() {
  git -C "$CASE_REPO" worktree list --porcelain |
    awk -v primary="$CASE_REPO" '/^worktree /{path=substr($0,10); if (path != primary) print path}' |
    tail -1
}

make_git_wrapper() {
  mkdir -p "$TMP/fakebin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'if [[ "${NASE_TEST_MODE:-}" == late && " $* " == *" worktree move "* ]]; then' \
    '  "$NASE_TEST_REAL_GIT" "$@"' \
    '  rc=$?' \
    '  if [[ $rc -eq 0 ]]; then' \
    '    mkdir -p "$NASE_TEST_OLD_PATH/ignored"' \
    '    printf "late\\n" >"$NASE_TEST_OLD_PATH/ignored/late.bin"' \
    '  fi' \
    '  exit "$rc"' \
    'fi' \
    'if [[ "${NASE_TEST_MODE:-}" != "" && " $* " == *" worktree remove "* ]]; then' \
    '  printf "automatic remove invoked\\n" >&2' \
    '  exit 99' \
    'fi' \
    'if [[ "${NASE_TEST_MODE:-}" == late-claimed && " $* " == *" ls-remote "* ]]; then' \
    '  count=0' \
    '  [[ ! -f "$NASE_TEST_COUNT_FILE" ]] || count=$(<"$NASE_TEST_COUNT_FILE")' \
    '  count=$((count + 1))' \
    '  printf "%s\\n" "$count" >"$NASE_TEST_COUNT_FILE"' \
    '  if [[ $count -eq 2 ]]; then' \
    '    claimed=$("$NASE_TEST_REAL_GIT" -C "$NASE_TEST_REPO" worktree list --porcelain | awk -v primary="$NASE_TEST_REPO" '\''/^worktree /{path=substr($0,10); if (path != primary) print path}'\'' | tail -1)' \
    '    mkdir -p "$claimed/ignored"' \
    '    printf "late-claimed-bytes\\n" >"$claimed/ignored/late.bin"' \
    '  fi' \
    'fi' \
    'if [[ "${NASE_TEST_MODE:-}" == remote-race && " $* " == *" ls-remote "* ]]; then' \
    '  count=0' \
    '  [[ ! -f "$NASE_TEST_COUNT_FILE" ]] || count=$(<"$NASE_TEST_COUNT_FILE")' \
    '  count=$((count + 1))' \
    '  printf "%s\\n" "$count" >"$NASE_TEST_COUNT_FILE"' \
    '  if [[ $count -eq 2 ]]; then' \
    '    "$NASE_TEST_REAL_GIT" --git-dir="$NASE_TEST_REMOTE" update-ref refs/heads/feature "$NASE_TEST_RACE_OID"' \
    '  fi' \
    'fi' \
    'exec "$NASE_TEST_REAL_GIT" "$@"' \
    >"$TMP/fakebin/git"
  chmod +x "$TMP/fakebin/git"
}

run_helper_injected() {
  env \
    PATH="$TMP/fakebin:$PATH" \
    NASE_TEST_REAL_GIT="$REAL_GIT" \
    NASE_TEST_MODE="$TEST_MODE" \
    NASE_TEST_OLD_PATH="$CASE_WT" \
    NASE_TEST_COUNT_FILE="$TMP/ls-remote-count" \
    NASE_TEST_REMOTE="$CASE_BASE/remote.git" \
    NASE_TEST_REPO="$CASE_REPO" \
    NASE_TEST_RACE_OID="${RACE_OID:-}" \
    python3 "$HELPER" \
      --repo "$CASE_REPO" \
      --worktree "$CASE_WT" \
      --remote origin \
      --remote-ref refs/heads/feature \
      --expected-head "$CASE_HEAD"
}

set -e
REAL_GIT=$(command -v git)
make_git_wrapper

new_case clean
expect_rc "clean exact pushed worktree is quarantined" 3 run_helper
[[ ! -e "$CASE_WT" ]] || fail "clean worktree original path still exists"
claimed_path=$(linked_worktree_path)
[[ -d "$claimed_path" ]] || fail "clean worktree quarantine is missing"
git -C "$CASE_REPO" worktree list --porcelain | grep -A5 -F "worktree $claimed_path" | grep -q '^locked nase cleanup quarantine$' || fail "clean quarantine is not locked"

new_case tracked
printf 'changed\n' >>"$CASE_WT/tracked.txt"
expect_rc "tracked change retains worktree" 3 run_helper
[[ -d "$CASE_WT" ]] || fail "tracked worktree was deleted"

new_case untracked
printf 'new\n' >"$CASE_WT/new.txt"
expect_rc "untracked file retains worktree" 3 run_helper

new_case ignored
mkdir -p "$CASE_WT/ignored"
printf 'build\n' >"$CASE_WT/ignored/output.bin"
expect_rc "ignored file retains worktree" 3 run_helper

new_case assume-unchanged
git -C "$CASE_WT" update-index --assume-unchanged tracked.txt
printf 'assume hidden bytes\n' >"$CASE_WT/tracked.txt"
expect_rc "assume-unchanged content is retained before move" 3 run_helper
[[ $(<"$CASE_WT/tracked.txt") == "assume hidden bytes" ]] || fail "assume-unchanged bytes were changed"
[[ $(linked_worktree_path) == "$CASE_WT" ]] || fail "assume-unchanged worktree moved"

new_case skip-worktree
odd_path=$'odd\nname.txt'
printf 'baseline\n' >"$CASE_WT/$odd_path"
git -C "$CASE_WT" add -- "$odd_path"
git -C "$CASE_WT" commit -qm 'add odd path'
git -C "$CASE_WT" push -q origin feature
CASE_HEAD=$(git -C "$CASE_WT" rev-parse HEAD)
git -C "$CASE_WT" update-index --skip-worktree -- "$odd_path"
printf 'skip hidden bytes\n' >"$CASE_WT/$odd_path"
expect_rc "skip-worktree unusual path content is retained before move" 3 run_helper
[[ $(<"$CASE_WT/$odd_path") == "skip hidden bytes" ]] || fail "skip-worktree bytes were changed"
[[ $(linked_worktree_path) == "$CASE_WT" ]] || fail "skip-worktree worktree moved"

new_case fsmonitor-valid
fsmonitor_supported=false
if git -C "$CASE_WT" config core.fsmonitor true &&
  git -C "$CASE_WT" update-index --fsmonitor-valid tracked.txt; then
  if fsmonitor_listing=$(git -C "$CASE_WT" ls-files -f -- tracked.txt); then
    [[ ${fsmonitor_listing:0:1} != [[:lower:]] ]] || fsmonitor_supported=true
  fi
fi
if [[ $fsmonitor_supported == true ]]; then
  printf 'fsmonitor hidden bytes\n' >"$CASE_WT/tracked.txt"
  expect_rc "fsmonitor-valid content is retained before move" 3 run_helper
  [[ $(<"$CASE_WT/tracked.txt") == "fsmonitor hidden bytes" ]] || fail "fsmonitor-valid bytes were changed"
  [[ $(linked_worktree_path) == "$CASE_WT" ]] || fail "fsmonitor-valid worktree moved"
else
  pass "fsmonitor-valid regression skipped: local Git did not expose the flag"
fi

new_case late-ignored
TEST_MODE=late
expect_rc "ignored file created after proof is preserved" 3 run_helper_injected
[[ -f "$CASE_WT/ignored/late.bin" ]] || fail "late ignored file was deleted"
claimed_path=$(linked_worktree_path)
[[ -d "$claimed_path" && "$claimed_path" != "$CASE_WT" ]] || fail "claimed worktree was not retained"

new_case late-claimed
rm -f "$TMP/ls-remote-count"
TEST_MODE=late-claimed
expect_rc "ignored file created after final scan is quarantined" 3 run_helper_injected
claimed_path=$(linked_worktree_path)
[[ $(<"$claimed_path/ignored/late.bin") == "late-claimed-bytes" ]] || fail "late claimed bytes were deleted"
[[ ! -e "$CASE_WT" ]] || fail "late claimed test recreated original path"

new_case locked
git -C "$CASE_REPO" worktree lock --reason test-lock "$CASE_WT"
expect_rc "locked worktree is retained" 3 run_helper

new_case in-progress
git_path=$(git -C "$CASE_WT" rev-parse --git-path MERGE_HEAD)
printf '%s\n' "$CASE_HEAD" >"$git_path"
expect_rc "in-progress Git state retains worktree" 3 run_helper

new_case remote-mismatch
printf 'remote advance\n' >>"$CASE_REPO/tracked.txt"
git -C "$CASE_REPO" add tracked.txt
git -C "$CASE_REPO" commit -qm advance
git -C "$CASE_REPO" push -q origin main:feature
expect_rc "remote SHA mismatch retains worktree" 3 run_helper

new_case offline
git -C "$CASE_REPO" remote set-url origin "$CASE_BASE/missing.git"
expect_rc "offline remote retains worktree" 3 run_helper

new_case primary
PRIMARY_HEAD=$(git -C "$CASE_REPO" rev-parse HEAD)
expect_rc "primary worktree is never removed" 3 python3 "$HELPER" \
  --repo "$CASE_REPO" --worktree "$CASE_REPO" --remote origin \
  --remote-ref refs/heads/main --expected-head "$PRIMARY_HEAD"

new_case detached
git -C "$CASE_REPO" worktree remove "$CASE_WT"
git -C "$CASE_REPO" branch -D feature >/dev/null
git -C "$CASE_REPO" worktree add -q --detach "$CASE_WT" main
CASE_HEAD=$(git -C "$CASE_WT" rev-parse HEAD)
git -C "$CASE_WT" push -q origin HEAD:refs/heads/detached-clean
expect_rc "detached worktree with exact remote SHA is quarantined" 3 python3 "$HELPER" \
  --repo "$CASE_REPO" --worktree "$CASE_WT" --remote origin \
  --remote-ref refs/heads/detached-clean --expected-head "$CASE_HEAD"
claimed_path=$(linked_worktree_path)
[[ $(git -C "$claimed_path" rev-parse HEAD) == "$CASE_HEAD" ]] || fail "detached quarantine lost expected HEAD"

new_case detached-remote-race
git -C "$CASE_REPO" worktree remove "$CASE_WT"
git -C "$CASE_REPO" branch -D feature >/dev/null
git -C "$CASE_REPO" worktree add -q --detach "$CASE_WT" main
CASE_HEAD=$(git -C "$CASE_WT" rev-parse HEAD)
printf 'remote moved\n' >>"$CASE_REPO/tracked.txt"
git -C "$CASE_REPO" add tracked.txt
git -C "$CASE_REPO" commit -qm 'remote race target'
RACE_OID=$(git -C "$CASE_REPO" rev-parse HEAD)
git -C "$CASE_REPO" push -q origin HEAD:refs/heads/race-seed
rm -f "$TMP/ls-remote-count"
TEST_MODE=remote-race
expect_rc "remote move during detached quarantine preserves worktree" 3 run_helper_injected
claimed_path=$(linked_worktree_path)
[[ -d "$claimed_path" ]] || fail "detached worktree was not quarantined after remote race"
[[ $(git -C "$claimed_path" rev-parse HEAD) == "$CASE_HEAD" ]] || fail "quarantined worktree lost expected HEAD"
if git -C "$claimed_path" symbolic-ref -q HEAD >/dev/null; then fail "quarantined worktree is not detached"; fi
[[ $(git --git-dir="$CASE_BASE/remote.git" rev-parse refs/heads/feature) == "$RACE_OID" ]] || fail "remote race fixture did not move ref"
[[ -z $(git -C "$CASE_REPO" for-each-ref refs/nase/worktree-cleanup/) ]] || fail "safety ref remained after restore"

new_case submodule-dirty
git init --bare -q -b main "$CASE_BASE/submodule.git"
git clone -q "$CASE_BASE/submodule.git" "$CASE_BASE/submodule-seed"
git -C "$CASE_BASE/submodule-seed" config user.name test
git -C "$CASE_BASE/submodule-seed" config user.email test@example.com
printf 'submodule\n' >"$CASE_BASE/submodule-seed/file.txt"
git -C "$CASE_BASE/submodule-seed" add file.txt
git -C "$CASE_BASE/submodule-seed" commit -qm base
git -C "$CASE_BASE/submodule-seed" push -q origin main
git -C "$CASE_WT" -c protocol.file.allow=always submodule add -q "$CASE_BASE/submodule.git" deps/sub
git -C "$CASE_WT" commit -qam 'add submodule'
git -C "$CASE_WT" push -q origin feature
CASE_HEAD=$(git -C "$CASE_WT" rev-parse HEAD)
sub_exclude=$(git -C "$CASE_WT/deps/sub" rev-parse --git-path info/exclude)
printf 'ignored.bin\n' >>"$sub_exclude"
printf 'ignored submodule content\n' >"$CASE_WT/deps/sub/ignored.bin"
expect_rc "ignored content inside submodule retains worktree" 3 run_helper

new_case invalid
expect_rc "short expected OID is invalid input" 2 python3 "$HELPER" \
  --repo "$CASE_REPO" --worktree "$CASE_WT" --remote origin \
  --remote-ref refs/heads/feature --expected-head deadbeef

if rg -n 'worktree remove[^`\n]*--force|worktree remove \{[^\n]*--force' \
  "$ROOT/CLAUDE.md" "$ROOT/.claude" "$ROOT/docs" --glob '*.md' >"$TMP/force-references"; then
  fail "documented force worktree removal remains: $(tr '\n' ' ' <"$TMP/force-references")"
else
  pass "documented consumers contain no force worktree removal"
fi

if rg -n '"worktree", "remove"' "$HELPER" >"$TMP/remove-call"; then
  fail "helper still invokes recursive worktree removal: $(tr '\n' ' ' <"$TMP/remove-call")"
else
  pass "helper contains no automatic recursive worktree removal"
fi

if rg -n 'Worktree:[[:space:]]+cleaned up' "$ROOT/.claude/commands/nase/fsd.md" >"$TMP/fsd-worktree"; then
  fail "FSD still reports unconditional worktree cleanup"
elif ! grep -Fq 'Worktree:    {worktree_report}' "$ROOT/.claude/commands/nase/fsd.md"; then
  fail "FSD report does not render conditional worktree_report"
elif ! grep -Fq 'quarantined at {exact registered-worktree path}' "$ROOT/.claude/commands/nase/fsd.md"; then
  fail "FSD does not bind quarantine report to exact returned path"
else
  pass "FSD reports removed, quarantined, retained, or n/a conditionally"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
