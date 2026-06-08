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

assert_cmd "pr gate remediation doc exists" test -f .claude/docs/pr-gate-remediation.md
assert_cmd "codex verification bundle doc exists" test -f .claude/docs/codex-verification-bundle.md
assert_cmd "effort lifecycle doc exists" test -f .claude/docs/effort-lifecycle.md
assert_cmd "pr gate remediation script exists" test -f .claude/scripts/pr-gate-remediation.py
assert_cmd "codex verify bundle script exists" test -f .claude/scripts/codex-verify-bundle.py

assert_contains "address-comments uses PR gate shared doc" .claude/commands/nase/address-comments.md 'pr-gate-remediation\.md'
assert_not_contains "address-comments no inline PR gate recipe table" .claude/commands/nase/address-comments.md '^\| `Commit Lint`'
assert_contains "PR gate doc owns Commit Lint recipe" .claude/docs/pr-gate-remediation.md 'Commit Lint'
assert_contains "PR gate script classifies commitlint" .claude/scripts/pr-gate-remediation.py 'commitlint'

assert_contains "fsd uses codex bundle shared doc" .claude/commands/nase/fsd.md 'codex-verification-bundle\.md'
assert_contains "fsd uses codex bundle script" .claude/commands/nase/fsd.md 'codex-verify-bundle\.py'
assert_not_contains "fsd no inline codex diff algorithm" .claude/commands/nase/fsd.md 'Include the full diff for changed files only when'
assert_contains "codex bundle doc names script" .claude/docs/codex-verification-bundle.md 'codex-verify-bundle\.py'

assert_contains "design uses effort lifecycle doc" .claude/commands/nase/design.md 'effort-lifecycle\.md'
assert_contains "fsd uses effort lifecycle doc" .claude/commands/nase/fsd.md 'effort-lifecycle\.md'
assert_contains "prep-merge uses effort lifecycle doc" .claude/commands/nase/prep-merge.md 'effort-lifecycle\.md'
assert_contains "effort lifecycle doc covers merge-ready" .claude/docs/effort-lifecycle.md 'merge-ready'

python3 .claude/scripts/pr-gate-remediation.py classify --name 'Commit Lint' > "$TMPROOT/pr-gate.json"
assert_contains "pr gate script emits commitlint recipe" "$TMPROOT/pr-gate.json" '"recipe": "commitlint"'

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
