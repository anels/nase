#!/usr/bin/env bash
# Regression tests for .claude/scripts/scope-files.sh.
#
# The oracle below is the inline block /nase:simplify used before the helper existed.
# Every documented scope must resolve to the same file list, byte for byte.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/scope-files.sh"
TMPROOT=$(mktemp -d)
failures=0
source "$ROOT/tests/lib/assert.sh"
trap 'rm -rf "$TMPROOT"' EXIT

REPO="$TMPROOT/work"
REMOTE="$TMPROOT/origin.git"

git init --quiet --bare "$REMOTE"
git init --quiet -b main "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
git -C "$REPO" remote add origin "$REMOTE"

# Mixed case lives in a filename, not a directory: macOS filesystems are
# case-insensitive, so src/ and Src/ would be the same directory here.
mkdir -p "$REPO/src"
printf 'base\n' > "$REPO/src/base.txt"
printf 'cased\n' > "$REPO/src/Cased.txt"
git -C "$REPO" add -A
git -C "$REPO" commit --quiet -m "base"
git -C "$REPO" push --quiet -u origin main
git -C "$REPO" remote set-head origin -a >/dev/null 2>&1

# One commit past the merge base, plus staged / unstaged / untracked work.
printf 'committed\n' > "$REPO/src/committed.txt"
git -C "$REPO" add -A
git -C "$REPO" commit --quiet -m "committed change"
printf 'staged\n' > "$REPO/src/staged.txt"
git -C "$REPO" add "$REPO/src/staged.txt"
printf 'changed\n' >> "$REPO/src/base.txt"
printf 'untracked\n' > "$REPO/src/untracked.txt"

# --- oracle: the pre-helper inline block, unchanged ---------------------------
oracle() {
  local ARGUMENTS="$1"
  git fetch origin --quiet
  local DEFAULT BASE_REF MERGE_BASE GLOB FILES
  DEFAULT=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
  [ -z "$DEFAULT" ] && DEFAULT=main
  BASE_REF="origin/$DEFAULT"
  MERGE_BASE=$(git merge-base HEAD "$BASE_REF" 2>/dev/null || git rev-parse HEAD)

  case "$ARGUMENTS" in
    *--scope=*) GLOB="${ARGUMENTS##*--scope=}"; GLOB="${GLOB%% *}"
                FILES=$({
                  git ls-files -- "$GLOB"
                  git ls-files --others --exclude-standard -- "$GLOB"
                } | sort -u) ;;
    *unstaged*) FILES=$({
                  git diff --name-only
                  git ls-files --others --exclude-standard
                } | sort -u) ;;
    *staged*)   FILES=$(git diff --name-only --cached | sort -u) ;;
    *"last-commit"*|*"last commit"*)
                FILES=$(git diff --name-only HEAD~1 HEAD | sort -u) ;;
    *)          FILES=$({
                  git diff --name-only "$MERGE_BASE" HEAD
                  git diff --name-only
                  git diff --name-only --cached
                  git ls-files --others --exclude-standard
                } | sort -u) ;;
  esac
  printf '%s\n' "$FILES"
}

# Blank lines are stripped from both sides because the oracle's `printf '%s\n'` emits a
# lone newline for an empty scope where the helper emits nothing. Both callers read the
# result through command substitution, which strips trailing newlines, so the two are
# indistinguishable at the consumer.
assert_same_as_oracle() {
  local desc="$1" args="$2" expected actual
  expected=$(cd "$REPO" && oracle "$args")
  actual=$(cd "$REPO" && bash "$SCRIPT" "$args")
  if [ "$(printf '%s' "$expected" | sed '/^$/d')" = "$(printf '%s' "$actual" | sed '/^$/d')" ]; then
    printf 'PASS  %s\n' "$desc"
  else
    failures=$((failures + 1))
    printf 'FAIL  %s\n  oracle: %s\n  helper: %s\n' "$desc" "$expected" "$actual" >&2
  fi
}

assert_same_as_oracle "default scope matches the inline block" ""
assert_same_as_oracle "unstaged scope matches the inline block" "unstaged"
assert_same_as_oracle "staged scope matches the inline block" "staged files"
assert_same_as_oracle "last-commit scope matches the inline block" "last-commit"
assert_same_as_oracle "last commit (spaced) scope matches the inline block" "last commit"
assert_same_as_oracle "glob scope matches the inline block" "--scope=src/*"

# unstaged must win over staged: "unstaged" contains "staged".
unstaged_out=$(cd "$REPO" && bash "$SCRIPT" "unstaged")
staged_out=$(cd "$REPO" && bash "$SCRIPT" "staged")
assert_cmd "unstaged branch is matched before staged" test "$unstaged_out" != "$staged_out"
assert_cmd "unstaged scope includes untracked files" \
  bash -c "printf '%s\n' \"\$1\" | grep -qx src/untracked.txt" _ "$unstaged_out"
assert_cmd "staged scope is limited to the index" test "$staged_out" = "src/staged.txt"

# Documented behaviour: selection matches case-insensitively, the glob keeps its case.
upper_out=$(cd "$REPO" && bash "$SCRIPT" "UNSTAGED")
assert_cmd "scope selection is case-insensitive" test "$upper_out" = "$unstaged_out"
cased_out=$(cd "$REPO" && bash "$SCRIPT" "--scope=src/C*")
assert_cmd "glob keeps its original case" test "$cased_out" = "src/Cased.txt"
upper_flag_out=$(cd "$REPO" && bash "$SCRIPT" "--SCOPE=src/C*")
assert_cmd "an upper-cased --scope flag still yields the same glob" \
  test "$upper_flag_out" = "src/Cased.txt"

# The repo argument lets a caller scope a checkout other than the current directory.
elsewhere_out=$(cd "$TMPROOT" && bash "$SCRIPT" "staged" "$REPO")
assert_cmd "repo argument scopes another checkout" test "$elsewhere_out" = "src/staged.txt"

# A repo with nothing in scope prints nothing and still exits 0.
CLEAN="$TMPROOT/clean"
git init --quiet -b main "$CLEAN"
git -C "$CLEAN" config user.email test@example.com
git -C "$CLEAN" config user.name test
printf 'x\n' > "$CLEAN/only.txt"
git -C "$CLEAN" add -A
git -C "$CLEAN" commit --quiet -m "only"
clean_out=$(cd "$CLEAN" && bash "$SCRIPT" "staged")
clean_rc=$?
assert_cmd "empty scope exits 0" test "$clean_rc" = 0
assert_cmd "empty scope prints nothing" test -z "$clean_out"

if [[ "$failures" -eq 0 ]]; then
  printf '\nscope-files tests passed.\n'
  exit 0
fi

printf '\n%d scope-files assertion(s) failed.\n' "$failures" >&2
exit "$failures"
