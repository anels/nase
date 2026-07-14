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
assert_cmd "FSD delivery gates doc exists" test -f .claude/docs/fsd-delivery-gates.md
for doc in \
  fsd-intake-and-setup \
  fsd-implementation-loop \
  address-comments-analysis \
  address-comments-delivery \
  discuss-pr-analysis \
  discuss-pr-output
do
  assert_cmd "$doc phase doc exists" test -f ".claude/docs/$doc.md"
done

assert_contains "address-comments loads analysis on demand" .claude/commands/nase/address-comments.md 'address-comments-analysis\.md'
assert_contains "address-comments loads delivery after confirmation" .claude/commands/nase/address-comments.md 'address-comments-delivery\.md'
assert_contains "address-comments delivery skips PR gates" .claude/docs/address-comments-delivery.md 'PR Gates .* Skip'
assert_not_contains "address-comments delivery does not run gh pr checks" .claude/docs/address-comments-delivery.md 'gh pr checks'
assert_not_contains "address-comments does not reference pr gate remediation helper" .claude/docs/address-comments-delivery.md 'pr-gate-remediation'
assert_not_contains "address-comments does not claim PR gates green" .claude/docs/address-comments-delivery.md 'PR gates: all green'

assert_contains "fsd uses delivery gates doc" .claude/commands/nase/fsd.md 'fsd-delivery-gates\.md'
assert_contains "fsd loads intake on demand" .claude/commands/nase/fsd.md 'fsd-intake-and-setup\.md'
assert_contains "fsd loads implementation loop on demand" .claude/commands/nase/fsd.md 'fsd-implementation-loop\.md'
assert_contains "FSD delivery gates use codex bundle script" .claude/docs/fsd-delivery-gates.md 'codex-verify-bundle\.py'
assert_contains "FSD delivery gates retain bundle repo argument" .claude/docs/fsd-delivery-gates.md 'repo.*worktree_or_repo'
assert_not_contains "FSD delivery gates avoid unsupported bundle scope" .claude/docs/fsd-delivery-gates.md 'scope pre-push'
assert_not_contains "FSD delivery gates avoid unsupported bundle diff-base" .claude/docs/fsd-delivery-gates.md 'diff-base'
assert_contains "FSD delivery gates retain deep self-review" .claude/docs/fsd-delivery-gates.md 'Review depth'
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
assert_contains "fsd intake preserves one-PR default" .claude/docs/fsd-intake-and-setup.md 'Default to the design PR plan'
assert_contains "FSD delivery gates draft PR create" .claude/docs/fsd-delivery-gates.md 'Create this draft PR\?'
assert_contains "FSD delivery gates verification PR edit" .claude/docs/fsd-delivery-gates.md 'Append this Verification section to the draft PR\?'
assert_contains "fsd conditional closure excludes blockers" .claude/commands/nase/fsd.md 'conditional.*waiver reasons named'
assert_not_contains "fsd conditional wording does not admit blockers" .claude/commands/nase/fsd.md 'waivers/blockers named'
assert_contains "prep-merge uses effort lifecycle doc" .claude/commands/nase/prep-merge.md 'effort-lifecycle\.md'
assert_contains "prep-merge uses shared repo task flow" .claude/commands/nase/prep-merge.md 'repo-task-flow\.md'
assert_contains "address-comments uses shared repo task flow" .claude/commands/nase/address-comments.md 'repo-task-flow\.md'
assert_contains "discuss-pr loads analysis on demand" .claude/commands/nase/discuss-pr.md 'discuss-pr-analysis\.md'
assert_contains "discuss-pr loads output on demand" .claude/commands/nase/discuss-pr.md 'discuss-pr-output\.md'
assert_contains "review reference retains thread verdict contract" .claude/docs/pr-review-verification.md 'THREADS NOT ADDRESSED'
assert_contains "review reference retains pipeline specialist" .claude/docs/pr-review-verification.md 'Pipeline gates agent'
assert_contains "effort lifecycle doc covers merge-ready" .claude/docs/effort-lifecycle.md 'merge-ready'
assert_contains "effort lifecycle defines PR reference resolution" .claude/docs/effort-lifecycle.md 'PR Reference Resolution'
assert_contains "effort lifecycle requires structured delivery PRs" .claude/docs/effort-lifecycle.md 'pr`, `prs`, and `phase_\*_pr` frontmatter'
assert_contains "effort lifecycle rejects body PRs as delivery evidence" .claude/docs/effort-lifecycle.md 'Other body PR references are'
assert_contains "effort lifecycle preserves unresolved blockers" .claude/docs/effort-lifecycle.md 'Any unresolved `blocked-by` referent'
assert_contains "effort lifecycle handles merged plus closed PRs" .claude/docs/effort-lifecycle.md 'closed superseded siblings do not block it'
assert_contains "effort lifecycle handles all-closed PRs" .claude/docs/effort-lifecycle.md 'all readable delivery PRs are `CLOSED`'
assert_contains "effort lifecycle requires deploy evidence" .claude/docs/effort-lifecycle.md 'checked `Deployed` evidence'
assert_contains "effort lifecycle documents automatic awaiting-deploy" .claude/docs/effort-lifecycle.md 'awaiting-deploy` is set by the Drift Auto-Sync rule'
assert_contains "effort lifecycle uses wontfix terminal status" .claude/docs/effort-lifecycle.md 'status: wontfix'
assert_not_contains "effort lifecycle never emits invalid closed status" .claude/docs/effort-lifecycle.md 'status: closed'
assert_contains "effort lifecycle uses guarded move" .claude/docs/effort-lifecycle.md 'apply-move'
assert_contains "effort lifecycle uses executable transition decision" .claude/docs/effort-lifecycle.md 'transition\.action'
assert_contains "efforts keeps dependency PRs separate" .claude/commands/nase/efforts.md 'Keep delivery, report-only, and dependency PR sets separate'
assert_contains "efforts calls executable transition decision" .claude/commands/nase/efforts.md 'effort-state\.py.*Drift Auto-Sync'
assert_contains "today checks normalized PR references" .claude/commands/nase/today.md 'unique normalized PR reference'
assert_not_contains "today status check is not URL-only" .claude/commands/nase/today.md 'For each unique PR URL found'
assert_contains "today keeps PR roles separate" .claude/commands/nase/today.md 'Keep the three PR sets separate'
assert_not_contains "today does not silently skip effort read failures" .claude/commands/nase/today.md 'fails for any PR.*skip that PR silently'

assert_not_contains "architecture does not claim native mirror generation" docs/architecture.md 'wrappers and hidden.*native skills'
assert_contains "architecture documents legacy mirror cleanup" docs/architecture.md 'removes legacy generated native mirrors'
assert_contains "doctor rejects legacy native mirrors" .claude/commands/nase/doctor.md 'no legacy generated native mirror remains'
assert_contains "write guard matches legacy mirror policy" .claude/docs/workspace-write-guard.md 'no legacy generated native mirror'

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
