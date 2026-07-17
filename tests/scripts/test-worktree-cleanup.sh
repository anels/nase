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
  CASE_REPO="$base/repo"
  CASE_WT="$base/wt"
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

set -e

new_case clean
expect_rc "clean exact pushed worktree is removed" 0 run_helper
[[ ! -e "$CASE_WT" ]] || fail "clean worktree path still exists"

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
expect_rc "detached worktree with exact remote SHA is removed" 0 python3 "$HELPER" \
  --repo "$CASE_REPO" --worktree "$CASE_WT" --remote origin \
  --remote-ref refs/heads/detached-clean --expected-head "$CASE_HEAD"

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

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
