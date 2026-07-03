#!/usr/bin/env bash
# Regression tests for shared workflow extraction from large command files.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

TMPROOT=$(mktemp -d)
failures=0

cleanup() {
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

pass() { printf 'PASS  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_cmd() {
  local desc="$1"
  shift
  if "$@"; then
    pass "$desc"
  else
    fail "$desc"
  fi
}

assert_contains() {
  local desc="$1" file="$2" pattern="$3"
  assert_cmd "$desc" grep -qE "$pattern" "$file"
}

assert_not_contains() {
  local desc="$1" file="$2" pattern="$3"
  assert_cmd "$desc" bash -c '! grep -qE "$2" "$1"' _ "$file" "$pattern"
}

assert_cmd "codex verification bundle doc exists" test -f .claude/docs/codex-verification-bundle.md
assert_cmd "effort lifecycle doc exists" test -f .claude/docs/effort-lifecycle.md
assert_cmd "repo task flow doc exists" test -f .claude/docs/repo-task-flow.md
assert_cmd "codex verify bundle script exists" test -f .claude/scripts/codex-verify-bundle.py

assert_contains "address-comments skips PR gates" .claude/commands/nase/address-comments.md 'PR Gates .* Skip'
assert_not_contains "address-comments does not run gh pr checks" .claude/commands/nase/address-comments.md 'gh pr checks'
assert_not_contains "address-comments does not reference pr gate remediation helper" .claude/commands/nase/address-comments.md 'pr-gate-remediation'
assert_not_contains "address-comments does not claim PR gates green" .claude/commands/nase/address-comments.md 'PR gates: all green'

assert_contains "fsd uses codex bundle shared doc" .claude/commands/nase/fsd.md 'codex-verification-bundle\.md'
assert_contains "fsd uses codex bundle script" .claude/commands/nase/fsd.md 'codex-verify-bundle\.py'
assert_contains "fsd uses shared repo task flow" .claude/commands/nase/fsd.md 'repo-task-flow\.md'
assert_not_contains "fsd no inline codex diff algorithm" .claude/commands/nase/fsd.md 'Include the full diff for changed files only when'
assert_contains "codex bundle doc names script" .claude/docs/codex-verification-bundle.md 'codex-verify-bundle\.py'
assert_contains "repo task flow covers repo resolution" .claude/docs/repo-task-flow.md 'repo/PR resolution'
assert_contains "repo task flow covers mutation gates" .claude/docs/repo-task-flow.md 'GitHub mutation gates'

assert_contains "design uses effort lifecycle doc" .claude/commands/nase/design.md 'effort-lifecycle\.md'
assert_contains "design has PR economy default" .claude/commands/nase/design.md 'Default to one PR'
assert_contains "design records target PR count" .claude/commands/nase/design.md 'Target PR count'
assert_contains "design gates multi-PR splits" .claude/commands/nase/design.md 'Split into multiple PRs only when'
assert_contains "design quality checks reviewability" .claude/commands/nase/design.md 'Reviewability'
assert_contains "design effort template has Validation section" .claude/commands/nase/design.md 'Validation — how to get the real number'
assert_contains "design research doc defines validation rule C4b" .claude/docs/design-research.md 'C4b. Validation'
assert_contains "auto design preserves PR plan" .claude/docs/design-auto-mode.md 'PR Plan'
assert_contains "auto design uses full research ladder" .claude/docs/design-auto-mode.md 'After all 6'
assert_not_contains "auto design has no stale five-source ladder" .claude/docs/design-auto-mode.md 'all 5 sources'
assert_not_contains "auto design has no stale four-source ladder" .claude/docs/design-auto-mode.md 'all four research sources'
assert_contains "auto design respects higher-priority flags" .claude/docs/design-auto-mode.md 'routes `--grill` / `--review` to Grill/Review Mode before Auto Mode'
assert_contains "fsd uses effort lifecycle doc" .claude/commands/nase/fsd.md 'effort-lifecycle\.md'
assert_contains "fsd consumes design PR plan" .claude/commands/nase/fsd.md 'design_pr_plan'
assert_contains "fsd preserves one-PR default" .claude/commands/nase/fsd.md 'Default to the design PR plan'
assert_contains "fsd gates draft PR create" .claude/commands/nase/fsd.md 'Create this draft PR\?'
assert_contains "fsd gates verification PR edit" .claude/commands/nase/fsd.md 'Append this Verification section to the draft PR\?'
assert_contains "prep-merge uses effort lifecycle doc" .claude/commands/nase/prep-merge.md 'effort-lifecycle\.md'
assert_contains "prep-merge uses shared repo task flow" .claude/commands/nase/prep-merge.md 'repo-task-flow\.md'
assert_contains "address-comments uses shared repo task flow" .claude/commands/nase/address-comments.md 'repo-task-flow\.md'
assert_contains "effort lifecycle doc covers merge-ready" .claude/docs/effort-lifecycle.md 'merge-ready'

tmprepo=$(mktemp -d "$TMPROOT/codex-bundle-repo.XXXXXX")
(
  cd "$tmprepo" || exit 1
  git init -q
  git config user.email test@example.com
  git config user.name Test
  printf 'old\n' > file.txt
  git add file.txt
  git commit -q -m init
  printf 'new\n' > file.txt
  printf 'extra\n' > extra.txt
  python3 "$ROOT/.claude/scripts/codex-verify-bundle.py" \
    --repo "$tmprepo" \
    --base HEAD \
    --task "change file" \
    --output "$tmprepo/bundle.md" \
    --max-full-diff-lines 200
)
assert_contains "codex bundle includes task" "$tmprepo/bundle.md" 'change file'
assert_contains "codex bundle includes diff stat" "$tmprepo/bundle.md" '## Diff Stat'
assert_contains "codex bundle includes untracked file" "$tmprepo/bundle.md" 'extra.txt'

if [[ "$failures" -eq 0 ]]; then
  printf '\nshared workflow extraction tests passed.\n'
  exit 0
fi

printf '\n%d shared workflow extraction assertion(s) failed.\n' "$failures" >&2
exit "$failures"
