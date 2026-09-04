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

assert_cmd "verification bundle doc exists" test -f .claude/docs/verification-bundle.md
assert_cmd "effort lifecycle doc exists" test -f .claude/docs/effort-lifecycle.md
assert_cmd "repo task flow doc exists" test -f .claude/docs/repo-task-flow.md
assert_cmd "verify bundle script exists" test -f .claude/scripts/verify-bundle.py
assert_cmd "FSD review reducer exists" test -f .claude/scripts/fsd-review-gate.py
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
assert_contains "address-comments entrypoint skips PR gates" .claude/commands/nase/address-comments.md 'PR Gates are skipped'
assert_not_contains "address-comments delivery does not run gh pr checks" .claude/docs/address-comments-delivery.md 'gh pr checks'
assert_not_contains "address-comments does not reference pr gate remediation helper" .claude/docs/address-comments-delivery.md 'pr-gate-remediation'
assert_not_contains "address-comments does not claim PR gates green" .claude/docs/address-comments-delivery.md 'PR gates: all green'

assert_contains "worktree root is the fixed home directory root" .claude/docs/worktree-pattern.md '\$HOME/\.nase-worktrees'
assert_contains "worktree pattern forbids a /tmp root with the sweep reason" .claude/docs/worktree-pattern.md 'tmp_cleaner'
assert_not_contains "worktree pattern no longer places worktrees beside the repo" .claude/docs/worktree-pattern.md '\{repo_parent\}'
assert_not_contains "FSD delivery gates no longer restate sibling placement" .claude/docs/fsd-delivery-gates.md 'sibling to the repo'
assert_contains "FSD delivery gates defer worktree path to shared pattern" .claude/docs/fsd-delivery-gates.md 'Worktree path.*worktree-pattern\.md'

assert_contains "fsd uses delivery gates doc" .claude/commands/nase/fsd.md 'fsd-delivery-gates\.md'
assert_contains "fsd loads intake on demand" .claude/commands/nase/fsd.md 'fsd-intake-and-setup\.md'
assert_contains "fsd loads implementation loop on demand" .claude/commands/nase/fsd.md 'fsd-implementation-loop\.md'
assert_contains "FSD delivery gates use verification bundle script" .claude/docs/fsd-delivery-gates.md 'verify-bundle\.py'
assert_contains "FSD delivery gates retain bundle repo argument" .claude/docs/fsd-delivery-gates.md 'repo.*worktree_or_repo'
assert_not_contains "FSD delivery gates avoid unsupported bundle scope" .claude/docs/fsd-delivery-gates.md 'scope pre-push'
assert_not_contains "FSD delivery gates avoid unsupported bundle diff-base" .claude/docs/fsd-delivery-gates.md 'diff-base'
assert_contains "FSD delivery gates retain deep self-review" .claude/docs/fsd-delivery-gates.md 'Review depth'
assert_not_contains "FSD no longer has Phase 5.75" .claude/commands/nase/fsd.md '5\.75'
assert_not_contains "FSD gates no longer have Phase 5.75" .claude/docs/fsd-delivery-gates.md '5\.75'
assert_contains "FSD has post-edit deterministic gates" .claude/docs/fsd-implementation-loop.md 'Phase 6\.1'
assert_contains "FSD has final candidate review gate" .claude/docs/fsd-delivery-gates.md 'Phase 6\.4'
assert_contains "FSD autofix restarts simplification" .claude/docs/fsd-delivery-gates.md 'restart.*Phase 6'
assert_contains "FSD discloses a repair applied after its only review" .claude/docs/fsd-delivery-gates.md 'disclose_unreviewed_repair'
assert_contains "FSD review is a single pass" .claude/docs/fsd-delivery-gates.md 'no second review'
assert_not_contains "FSD no longer runs a separate spec review" .claude/docs/fsd-delivery-gates.md 'Phase 6\.5'
assert_contains "FSD uses deterministic reducer" .claude/docs/fsd-delivery-gates.md 'fsd-review-gate\.py'
assert_contains "FSD reducer uses pre-review bundle hash" .claude/docs/fsd-delivery-gates.md 'expected-bundle-sha256'
assert_contains "FSD binds approved candidate tree" .claude/commands/nase/fsd.md 'approved_candidate_tree_oid'
assert_contains "FSD delivery gates own Phase 10" .claude/docs/fsd-delivery-gates.md '## Phase 10: Report'
assert_contains "FSD delivery gates contents link Phase 10" .claude/docs/fsd-delivery-gates.md '\[Phase 10: Report\]\(#phase-10-report\)'
assert_contains "FSD delivery gates own closure ledger" .claude/docs/fsd-delivery-gates.md 'Success-Criteria Ledger'
assert_contains "FSD phase map delegates closeout" .claude/commands/nase/fsd.md '9-10.*fsd-delivery-gates'
assert_not_contains "FSD entrypoint does not inline closeout report" .claude/commands/nase/fsd.md 'Print a concise summary'
assert_cmd "FSD entrypoint keeps size headroom" bash -c 'test "$(wc -c < "$1")" -lt 9000' _ .claude/commands/nase/fsd.md
assert_contains "FSD freezes complete canonical task" .claude/docs/fsd-intake-and-setup.md 'canonical_task_spec'
assert_contains "FSD binds tests to candidate tree" .claude/docs/fsd-implementation-loop.md 'tested_candidate_tree_oid'
assert_contains "FSD state preserves changed path count" .claude/commands/nase/fsd.md 'changed_path_count'
assert_not_contains "changed-line classification never buffers a forced text patch" \
  .claude/scripts/verify-bundle.py 'forced_patch = git'
assert_cmd "FSD captures changed path count before bundle use" python3 - <<'PY'
from pathlib import Path

text = Path(".claude/docs/fsd-implementation-loop.md").read_text(encoding="utf-8")
base = text.index("BASE=$(git -C")
capture = text.index("changed_path_count=$(printf")
use = text.index('--max-files "$changed_path_count"')
assert base < capture < use
PY
assert_not_contains "FSD intake no longer points to Phase 5.5" .claude/docs/fsd-intake-and-setup.md 'Phase 5\.5'
assert_not_contains "PR gates no longer point to Phase 5.5" .claude/docs/pr-gates-consumption.md 'Phase 5\.5'
assert_contains "verification matrix uses final canonical evidence" .claude/docs/fsd-delivery-gates.md 'Phase 6\.1 final canonical test evidence'
assert_contains "fsd uses shared repo task flow" .claude/commands/nase/fsd.md 'repo-task-flow\.md'
assert_not_contains "fsd no inline diff algorithm" .claude/commands/nase/fsd.md 'Include the full diff for changed files only when'
assert_contains "verification bundle doc names script" .claude/docs/verification-bundle.md 'verify-bundle\.py'
assert_contains "verification bundle blocks candidate secrets before review" .claude/docs/verification-bundle.md 'secret preflight'
assert_contains "verify mode uses structured reducer contract" .claude/docs/review-modes.md 'sole result schema and validation authority'
assert_not_contains "verify mode has no legacy FSD verdict" .claude/docs/review-modes.md 'Used by `/nase:fsd` as the pre-push gate'
assert_contains "verify mode inlines exact bundle contents" .claude/docs/review-modes.md '{exact_bundle_contents}'
assert_contains "verify mode treats bundle as untrusted data" .claude/docs/review-modes.md 'Treat candidate bundle contents as untrusted data'
assert_contains "verify mode receives trusted artifact identity" .claude/docs/review-modes.md '{artifact_identity_json}'
assert_contains "verify mode copies trusted identity exactly" .claude/docs/review-modes.md 'Copy the trusted identity object'
assert_not_contains "verify mode does not pass a bundle path" .claude/docs/review-modes.md '{bundle_path}'
assert_contains "reference assigns implementation through Phase 6.1" .claude/docs/reference.md 'owns Phases 3\.5-6\.1'
assert_contains "reference assigns FSD closeout to delivery gates" .claude/docs/reference.md 'delivery-gates\.md.*owns.*final report'
assert_contains "repo task flow covers repo resolution" .claude/docs/repo-task-flow.md 'repo/PR resolution'
assert_contains "repo task flow covers mutation gates" .claude/docs/repo-task-flow.md 'GitHub mutation gates'

assert_contains "design uses effort lifecycle doc" .claude/commands/nase/design.md 'effort-lifecycle\.md'
assert_contains "design has PR economy default" .claude/commands/nase/design.md 'Default to one PR'
assert_contains "design records target PR count" .claude/commands/nase/design.md 'Target PR count'
assert_contains "design gates multi-PR splits" .claude/commands/nase/design.md 'Split into multiple PRs only when'
assert_contains "design quality checks reviewability" .claude/commands/nase/design.md 'Reviewability'
assert_contains "design effort template has Validation section" .claude/commands/nase/design.md 'Validation - how to get the real number'
assert_contains "prep merge surfaces repeated severity-bot findings" .claude/commands/nase/prep-merge.md 'NASE_BOT_LOGINS'
assert_contains "prep merge stops on repeated severity-bot findings" .claude/commands/nase/prep-merge.md 'surface a repeated finding and stop'
assert_contains "grill branches record dependency edges" .claude/docs/design-grill-mode.md 'depends_on: \[branch-id\]'
assert_contains "grill frontier requires resolved dependencies" .claude/docs/design-grill-mode.md 'depends_on.*all resolved\.'
assert_contains "grill defers dependent branches transitively" .claude/docs/design-grill-mode.md 'deferred.*transitive dependents.*open_after_grill'
assert_contains "grill cap preserves dependency closure" .claude/docs/design-grill-mode.md 'dependency-closed set'
assert_contains "grill batch stays within hard branch budget" .claude/docs/design-grill-mode.md '25 - user-answerable branches already resolved'
assert_contains "grill batched stop preserves sibling answers" .claude/docs/design-grill-mode.md 'record the other non-termination answers returned in the same batch'
assert_cmd "open-work freshness doc exists" test -f .claude/docs/open-work-freshness.md
assert_contains "grill uses shared open-work freshness gate" .claude/docs/design-grill-mode.md 'open-work-freshness\.md'
assert_contains "design review uses shared open-work freshness gate" .claude/docs/design-review-mode.md 'open-work-freshness\.md'
assert_contains "auto design uses shared open-work freshness gate" .claude/docs/design-auto-mode.md 'open-work-freshness\.md'
assert_contains "FSD uses shared open-work freshness gate" .claude/docs/fsd-intake-and-setup.md 'open-work-freshness\.md'
assert_contains "freshness gate resolves live remote HEAD" .claude/docs/open-work-freshness.md 'ls-remote --symref origin HEAD'
assert_not_contains "freshness gate does not trust cached remote HEAD" .claude/docs/open-work-freshness.md 'fall back to the verified `refs/remotes/origin/HEAD`'
assert_contains "freshness gate fetches exact default ref" .claude/docs/open-work-freshness.md '\+refs/heads/\{default_branch\}:refs/remotes/origin/\{default_branch\}'
assert_contains "freshness gate pins fetched default OID" .claude/docs/open-work-freshness.md 'fresh_default_oid'
assert_contains "freshness gate reads implementation at pinned OID" .claude/docs/open-work-freshness.md 'show "\{fresh_default_oid\}:\{path\}"'
assert_contains "freshness gate resolves associated merged PR" .claude/docs/open-work-freshness.md 'commits/\{shipping_commit_oid\}/pulls'
assert_contains "freshness gate filters associated PRs to merged target" .claude/docs/open-work-freshness.md 'merged_at != null and \.base\.ref == "\{default_branch\}"'
assert_contains "freshness gate rejects name-only evidence" .claude/docs/open-work-freshness.md 'Name-only grep is candidate discovery, not coverage proof'
assert_contains "freshness reducer prioritizes blocked" .claude/docs/open-work-freshness.md 'If `blocked` is non-empty, set `freshness_outcome = blocked`'
assert_contains "freshness reducer handles already shipped second" .claude/docs/open-work-freshness.md 'Else if `still_open` is empty, set `freshness_outcome = already_shipped`'
assert_contains "FSD consumes shared freshness outcome" .claude/docs/fsd-intake-and-setup.md 'freshness_outcome'
assert_contains "review has already-shipped terminal verdict" .claude/docs/design-review-mode.md '### ALREADY SHIPPED'
assert_contains "grill gates FSD handoff on freshness outcome" .claude/docs/design-grill-mode.md 'Only suggest `/nase:fsd \{slug\}` when `freshness_outcome = continue`'
assert_not_contains "auto design has no removed base phase references" .claude/docs/design-auto-mode.md 'base (skill|workflow).*(Phase|phase)|Phase (1|2c|2e|2f|4b|5c|5d)'
assert_not_contains "grill has no removed base phase references" .claude/docs/design-grill-mode.md '/nase:design.*Phase [1-5]|Phase 2b'
assert_not_contains "review has no removed base phase references" .claude/docs/design-review-mode.md '/nase:design.*Phase [1-5]'
assert_not_contains "design research has no removed base phase references" .claude/docs/design-research.md 'base skill.*Phase|/nase:design \(Phase|design\.md.*Phase'
assert_not_contains "design research has no removed option phase numbers" .claude/docs/design-research.md 'Before presenting options \(Phase'
assert_not_contains "design research does not require ignored personal KB" .claude/docs/design-research.md 'read `workspace/kb/general/dotnet\.md`'
assert_contains "design research keeps tracked telemetry protocol" .claude/docs/design-research.md 'ExcludedTypes.*SamplingPercentage.*TelemetryProcessor'
assert_contains "review rescoring ignores repaired stale items" .claude/docs/design-review-mode.md 'repaired already-shipped item remains in the audit evidence but is not reopened'
assert_not_contains "review does not fail on repaired staleness" .claude/docs/design-review-mode.md 'staleness detected'
assert_contains "auto design keeps draft in memory before freshness" .claude/docs/design-auto-mode.md 'Keep the complete effort-doc draft in memory'
assert_not_contains "auto design does not stage before freshness" .claude/docs/design-auto-mode.md 'After staging the complete effort-doc draft'
assert_contains "auto design stages final guarded bytes" .claude/docs/design-auto-mode.md 'stage the final content, show its diff, and apply it with the fresh guard metadata'
assert_contains "skill checkpoint contract preserves exact mutation gates" .claude/docs/skill-contract.md 'external-mutation-policy\.md.*show the exact payload immediately before each action'
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
assert_contains "fsd conditional closure excludes blockers" .claude/docs/fsd-delivery-gates.md 'conditional.*waiver reasons named'
assert_not_contains "fsd conditional wording does not admit blockers" .claude/docs/fsd-delivery-gates.md 'waivers/blockers named'
assert_contains "prep-merge uses effort lifecycle doc" .claude/commands/nase/prep-merge.md 'effort-lifecycle\.md'
assert_contains "prep-merge uses shared repo task flow" .claude/commands/nase/prep-merge.md 'repo-task-flow\.md'
assert_contains "address-comments uses shared repo task flow" .claude/commands/nase/address-comments.md 'repo-task-flow\.md'
assert_contains "discuss-pr loads analysis on demand" .claude/commands/nase/discuss-pr.md 'discuss-pr-analysis\.md'
assert_contains "discuss-pr loads output on demand" .claude/commands/nase/discuss-pr.md 'discuss-pr-output\.md'
assert_contains "review reference retains thread verdict contract" .claude/docs/pr-review-verification.md 'THREADS NOT ADDRESSED'
assert_contains "review reference retains pipeline specialist" .claude/docs/pr-review-verification.md 'Pipeline gates agent'
assert_contains "review reference owns security specialist contract" .claude/docs/pr-review-verification.md 'Security Specialist Contract'
assert_contains "security specialist starts with bypass paths" .claude/docs/pr-review-verification.md 'flag-bypass paths first'
assert_contains "security specialist checks removed composite headers" .claude/docs/pr-review-verification.md 'removed composite security header'
assert_contains "security specialist revalidates SSRF redirects" .claude/docs/pr-review-verification.md 'every redirect hop'
assert_contains "discuss-pr analysis loads security specialist contract" .claude/docs/discuss-pr-analysis.md 'Security Specialist Contract'
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
assert_contains "effort lifecycle routes terminal moves by destination" .claude/docs/effort-lifecycle.md 'Terminal Destination'
assert_contains "effort lifecycle archives tracking-only efforts" .claude/docs/effort-lifecycle.md 'workspace/efforts/archive/\{current year\}'
assert_contains "effort lifecycle publishes the move destination" .claude/docs/effort-lifecycle.md 'transition\.destination_dir'
assert_contains "efforts keeps dependency PRs separate" .claude/commands/nase/efforts.md 'Keep delivery, report-only, and dependency PR sets separate'
assert_contains "efforts calls executable transition decision" .claude/commands/nase/efforts.md 'effort-state\.py.*Drift Auto-Sync'
assert_contains "efforts honours the helper move destination" .claude/commands/nase/efforts.md 'transition\.destination_dir'
assert_contains "effort rollup excludes tracking-only delivery" .claude/commands/nase/effort-rollup.md 'Exclude `tracking_only: true` efforts'
assert_contains "effort rollup loads integrity contract" .claude/commands/nase/effort-rollup.md 'effort-rollup-integrity.md'
assert_contains "effort rollup invokes evidence collector" .claude/docs/effort-rollup-integrity.md 'effort-rollup-evidence.py collect'
assert_contains "effort rollup revalidates rendered markdown" .claude/docs/effort-rollup-integrity.md 'effort-rollup-evidence.py validate'
assert_contains "effort rollup invokes citation validator" .claude/docs/effort-rollup-integrity.md 'citation-validator.py'
assert_contains "effort rollup keeps partial coverage visible" .claude/docs/effort-rollup-integrity.md 'coverage=partial'
assert_contains "effort rollup keeps PR volume supporting" .claude/commands/nase/effort-rollup.md 'Merged-PR volume is supporting evidence'
assert_contains "recap remains session grounded" .claude/commands/nase/recap.md 'session'
assert_contains "today checks normalized PR references" .claude/commands/nase/today.md 'unique normalized PR reference'
assert_not_contains "today status check is not URL-only" .claude/commands/nase/today.md 'For each unique PR URL found'
assert_contains "today keeps PR roles separate" .claude/commands/nase/today.md 'Keep the three PR sets separate'
assert_not_contains "today does not silently skip effort read failures" .claude/commands/nase/today.md 'fails for any PR.*skip that PR silently'

assert_not_contains "architecture does not claim native mirror generation" docs/architecture.md 'wrappers and hidden.*native skills'
assert_contains "architecture documents legacy mirror cleanup" docs/architecture.md 'removes legacy generated native mirrors'
assert_contains "architecture names deterministic skill scanner" docs/architecture.md 'skill-audit-scan\.py'
assert_contains "doctor rejects legacy native mirrors" .claude/commands/nase/doctor.md 'no legacy generated native mirror remains'
assert_contains "write guard matches legacy mirror policy" .claude/docs/workspace-write-guard.md 'no legacy generated native mirror'

tmprepo=$(mktemp -d "$TMPROOT/verify-bundle-repo.XXXXXX")
bundle_path="$TMPROOT/bundle.md"
bundle_identity="$TMPROOT/bundle-identity.json"
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
  python3 "$ROOT/.claude/scripts/verify-bundle.py" \
    --repo "$tmprepo" \
    --base HEAD \
    --task "change file" \
    --reviewer-identity-output "$bundle_identity" \
    --output "$bundle_path" \
    --max-full-diff-lines 200
)
assert_contains "verification bundle includes task" "$bundle_path" 'change file'
assert_contains "verification bundle includes diff stat" "$bundle_path" '## Diff Stat'
assert_contains "verification bundle includes untracked file" "$bundle_path" 'extra.txt'
if python3 - "$bundle_identity" "$bundle_path" <<'PY'
import hashlib
import json
import sys

identity = json.loads(open(sys.argv[1], encoding="utf-8").read())
bundle = open(sys.argv[2], "rb").read()
prefix = b"<!-- fsd-artifact: "
metadata = json.loads(bundle.splitlines()[0][len(prefix):-4])
assert set(identity) == {
    "base_oid",
    "bundle_sha256",
    "candidate_tree_oid",
    "contract_inventory_sha256",
}
assert identity["base_oid"] == metadata["base_oid"]
assert identity["candidate_tree_oid"] == metadata["candidate_tree_oid"]
assert identity["contract_inventory_sha256"] == metadata["contract_inventory_sha256"]
assert identity["bundle_sha256"] == hashlib.sha256(bundle).hexdigest()
PY
then
  pass "trusted reviewer identity matches exact bundle bytes"
else
  fail "trusted reviewer identity matches exact bundle bytes"
fi

candidate_before=$(python3 .claude/scripts/verify-bundle.py \
  --repo "$tmprepo" \
  --base HEAD \
  --candidate-tree-only | jq -r .candidate_tree_oid)
index_before=$(git -C "$tmprepo" write-tree)
git -C "$tmprepo" add -A -- .
candidate_staged=$(git -C "$tmprepo" write-tree)
git -C "$tmprepo" commit -q -m candidate
candidate_committed=$(git -C "$tmprepo" rev-parse 'HEAD^{tree}')
assert_cmd "candidate tree does not mutate real index" test "$index_before" != "$candidate_before"
assert_cmd "candidate tree matches explicit staging" test "$candidate_before" = "$candidate_staged"
assert_cmd "candidate tree survives commit" test "$candidate_before" = "$candidate_committed"

tree_repo=$(mktemp -d "$TMPROOT/candidate-tree-repo.XXXXXX")
(
  cd "$tree_repo" || exit 1
  git init -q
  git config user.email test@example.com
  git config user.name Test
  printf 'ignored.txt\n' > .gitignore
  printf 'tracked\n' > tracked.txt
  printf 'delete\n' > delete.txt
  printf 'rename\n' > old-name.txt
  printf '#!/bin/sh\nexit 0\n' > mode.sh
  git add .gitignore tracked.txt delete.txt old-name.txt mode.sh
  git commit -q -m init
)
tree_base=$(git -C "$tree_repo" rev-parse HEAD)
tree_initial=$(python3 .claude/scripts/verify-bundle.py \
  --repo "$tree_repo" --base "$tree_base" --candidate-tree-only | jq -r .candidate_tree_oid)
touch "$tree_repo/tracked.txt"
printf 'ignored\n' > "$tree_repo/ignored.txt"
tree_mtime=$(python3 .claude/scripts/verify-bundle.py \
  --repo "$tree_repo" --base "$tree_base" --candidate-tree-only | jq -r .candidate_tree_oid)
assert_cmd "mtime-only change keeps candidate tree" test "$tree_initial" = "$tree_mtime"
rm "$tree_repo/delete.txt"
mv "$tree_repo/old-name.txt" "$tree_repo/new-name.txt"
chmod +x "$tree_repo/mode.sh"
printf 'changed\n' > "$tree_repo/tracked.txt"
printf 'untracked\n' > "$tree_repo/untracked.txt"
tree_changed=$(python3 .claude/scripts/verify-bundle.py \
  --repo "$tree_repo" --base "$tree_base" --candidate-tree-only | jq -r .candidate_tree_oid)
tree_status=$(git -C "$tree_repo" diff --name-status --find-renames "$tree_base" "$tree_changed")
assert_cmd "tracked untracked delete rename and mode change alter tree" test "$tree_changed" != "$tree_initial"
assert_cmd "candidate tree records deletion" grep -q '^D.*delete.txt' <<<"$tree_status"
assert_cmd "candidate tree records rename" grep -q '^R.*old-name.txt.*new-name.txt' <<<"$tree_status"
assert_cmd "candidate tree records untracked file" grep -q 'untracked.txt' <<<"$tree_status"
assert_cmd "ignored file does not enter candidate tree" bash -c '! git -C "$1" ls-tree -r "$2" -- ignored.txt | grep -q .' _ "$tree_repo" "$tree_changed"
git -C "$tree_repo" add tracked.txt
partial_tree=$(git -C "$tree_repo" write-tree)
assert_cmd "partial staging fails approved-tree assertion" test "$partial_tree" != "$tree_changed"

sample_repo=$(mktemp -d "$TMPROOT/large-sample-repo.XXXXXX")
sample_bundle="$TMPROOT/large-sample.md"
sample_error="$TMPROOT/large-sample.err"
(
  cd "$sample_repo" || exit 1
  git init -q
  git config user.email test@example.com
  git config user.name Test
  git config diff.hide.textconv true
  printf 'seed\n' > seed.txt
  git add seed.txt
  git commit -q -m init
  for index in 1 2 3 4 5 6; do
    printf 'changed %s\n' "$index" > "change-$index.py"
  done
  printf '[[package]]\nname = "review-me"\nversion = "1.0.0"\n' > Cargo.lock
  printf '*.py binary diff=hide\n' > .gitattributes
)
if python3 .claude/scripts/verify-bundle.py \
  --repo "$sample_repo" --base HEAD --task sample \
  --max-full-diff-lines 0 --max-files 5 --output "$sample_bundle" \
  > /dev/null 2> "$sample_error"
then
  fail "large diff refuses to omit a text path"
else
  pass "large diff refuses to omit a text path"
fi
assert_contains "large diff omission error names the required limit" "$sample_error" \
  '8 text paths; --max-files 5 would omit review evidence'
assert_cmd "raised large diff budget samples every text path" \
  python3 .claude/scripts/verify-bundle.py \
    --repo "$sample_repo" --base HEAD --task sample \
    --max-full-diff-lines 0 --max-files 8 --output "$sample_bundle"
for index in 1 2 3 4 5 6; do
  assert_contains "large diff bundle includes change-$index.py" "$sample_bundle" \
    "### change-$index.py"
done
assert_contains "large diff bundle includes Cargo.lock" "$sample_bundle" '### Cargo.lock'
assert_contains "large diff bundle includes candidate attributes" "$sample_bundle" '### \.gitattributes'
assert_contains "candidate attributes and textconv cannot hide source content" "$sample_bundle" '^\+changed 1$'

context_repo=$(mktemp -d "$TMPROOT/context-repo.XXXXXX")
context_bundle="$TMPROOT/context-initial.md"
context_augmented="$TMPROOT/context-augmented.md"
context_request="$TMPROOT/context-request.json"
context_request_bare="$TMPROOT/context-request-bare.json"
context_request_missing="$TMPROOT/context-request-missing.json"
context_request_null="$TMPROOT/context-request-null.json"
(
  cd "$context_repo" || exit 1
  git init -q
  git config user.email test@example.com
  git config user.name Test
  printf 'base\n' > bound.txt
  git add bound.txt
  git commit -q -m init
  printf 'bound\n' > bound.txt
)
python3 .claude/scripts/verify-bundle.py \
  --repo "$context_repo" --base HEAD --task context --output "$context_bundle" >/dev/null
context_metadata=$(head -1 "$context_bundle" | sed -e 's/^<!-- fsd-artifact: //' -e 's/ -->$//')
context_tree=$(jq -r .candidate_tree_oid <<<"$context_metadata")
context_base=$(jq -r .base_oid <<<"$context_metadata")
context_inventory=$(jq -r .contract_inventory_sha256 <<<"$context_metadata")
jq -n \
  --arg tree "$context_tree" \
  --arg base "$context_base" \
  --arg inventory "$context_inventory" \
  '{candidate_tree_oid:$tree,base_oid:$base,contract_inventory_sha256:$inventory,context_requests:[{tree:"CANDIDATE",path:"bound.txt"},{tree:"BASE",path:"bound.txt"}]}' \
  > "$context_request"
jq -n '[{tree:"CANDIDATE",path:"bound.txt"}]' > "$context_request_bare"
jq -n --arg inventory "$context_inventory" \
  '{contract_inventory_sha256:$inventory,context_requests:[]}' > "$context_request_missing"
jq -n --arg inventory "$context_inventory" \
  '{candidate_tree_oid:null,base_oid:null,contract_inventory_sha256:$inventory,context_requests:[]}' > "$context_request_null"
for invalid_request in "$context_request_bare" "$context_request_missing" "$context_request_null"; do
  assert_cmd "unbound context request fails closed: $(basename "$invalid_request")" \
    bash -c '! python3 .claude/scripts/verify-bundle.py --repo "$1" --base HEAD --task invalid --context-request-file "$2" --output "$3" >/dev/null 2>&1' \
    _ "$context_repo" "$invalid_request" "$TMPROOT/invalid-context.md"
done
printf 'live worktree\n' > "$context_repo/bound.txt"
git -C "$context_repo" add bound.txt
git -C "$context_repo" commit -q -m live
python3 .claude/scripts/verify-bundle.py \
  --repo "$context_repo" --base HEAD --task context \
  --context-request-file "$context_request" --output "$context_augmented" >/dev/null
assert_contains "context reads the bound candidate blob" "$context_augmented" 'bound\\n'
assert_contains "context reads the bound base blob" "$context_augmented" '"content": "base\\n"'
assert_not_contains "context never reads later worktree content" "$context_augmented" 'live worktree'

cap_repo=$(mktemp -d "$TMPROOT/context-cap-repo.XXXXXX")
cap_request="$TMPROOT/context-cap-request.json"
cap_bundle="$TMPROOT/context-cap-bundle.md"
cap_evidence="$TMPROOT/context-cap-evidence.json"
(
  cd "$cap_repo" || exit 1
  git init -q
  git config user.email test@example.com
  git config user.name Test
  for n in 1 2 3 4 5; do
    head -c 70000 /dev/zero | tr '\0' x > "large-$n.txt"
  done
  printf 'target\n' > target.txt
  ln -s target.txt link.txt
  git add .
  git commit -q -m init
)
cap_tree=$(git -C "$cap_repo" rev-parse 'HEAD^{tree}')
cap_base=$(git -C "$cap_repo" rev-parse HEAD)
cap_inventory=$(python3 -c 'import hashlib; print(hashlib.sha256(b"[]").hexdigest())')
jq -n --arg tree "$cap_tree" --arg base "$cap_base" --arg inventory "$cap_inventory" \
  '{candidate_tree_oid:$tree,base_oid:$base,contract_inventory_sha256:$inventory,context_requests:([range(1;6)|{tree:"BASE",path:("large-"+(.|tostring)+".txt")}] + [{tree:"BASE",path:"link.txt"}])}' \
  > "$cap_request"
python3 - "$cap_evidence" "$cap_tree" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(
        {
            "candidate_tree_oid": sys.argv[2],
            "commands": [
                {"command": "verify", "exit_code": 0, "summary": "x" * 70000}
            ],
        },
        handle,
    )
PY
python3 .claude/scripts/verify-bundle.py \
  --repo "$cap_repo" --base HEAD --task caps \
  --evidence-file "$cap_evidence" --context-request-file "$cap_request" \
  --output "$cap_bundle" >/dev/null
cap_metadata=$(head -1 "$cap_bundle" | sed -e 's/^<!-- fsd-artifact: //' -e 's/ -->$//')
assert_cmd "evidence payload records original bytes and truncation" jq -e '.evidence | .byte_count > 65536 and .truncated == true' <<<"$cap_metadata"
assert_cmd "context item records original bytes and truncation" jq -e '.context_blob_metadata[0] | .byte_count == 70000 and .truncated == true' <<<"$cap_metadata"
assert_cmd "context total cap records an evidence gap" jq -e '[.context_blob_metadata[] | select(.evidence_gap == "context_total_limit")] | length >= 1' <<<"$cap_metadata"
assert_cmd "symlink context is an evidence gap" jq -e '[.context_blob_metadata[] | select(.evidence_gap == "symlink")] | length == 1' <<<"$cap_metadata"
assert_contains "context blob projection uses bounded streaming" .claude/scripts/verify-bundle.py 'def project_blob'
assert_not_contains "context resolver does not buffer a full Git blob" .claude/scripts/verify-bundle.py 'blob = git\(repo, "cat-file", "blob"'
if python3 - "$ROOT/.claude/scripts/verify-bundle.py" <<'PY'
import importlib.util
import sys
from pathlib import Path
from unittest import mock

spec = importlib.util.spec_from_file_location("verify_bundle", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

total = 16 * 1024 * 1024


class Stream:
    def __init__(self):
        self.remaining = total

    def read(self, size=-1):
        assert size == module.SCAN_CHUNK
        count = min(size, self.remaining)
        self.remaining -= count
        return b"x" * count

    def close(self):
        pass


class ErrorStream:
    def read(self):
        return b""


class Process:
    def __init__(self):
        self.stdout = Stream()
        self.stderr = ErrorStream()

    def wait(self):
        return 0


with mock.patch.object(module, "blob_size", return_value=total), mock.patch.object(
    module.subprocess, "Popen", return_value=Process()
):
    projection = module.project_blob(Path("."), {"oid": "0" * 40}, module.ITEM_LIMIT)

assert projection["byte_count"] == total
assert projection["truncated"] is True
assert len(projection["content"].encode("utf-8")) <= module.ITEM_LIMIT
PY
then
  pass "large context blob is read only in bounded chunks"
else
  fail "large context blob is read only in bounded chunks"
fi

missing_repo=$(mktemp -d "$TMPROOT/missing-blob-repo.XXXXXX")
missing_request="$TMPROOT/missing-blob-request.json"
missing_bundle="$TMPROOT/missing-blob-bundle.md"
(
  cd "$missing_repo" || exit 1
  git init -q
  git config user.email test@example.com
  git config user.name Test
  printf 'missing later\n' > missing.txt
  git add missing.txt
  git commit -q -m init
)
missing_tree=$(git -C "$missing_repo" rev-parse 'HEAD^{tree}')
missing_base=$(git -C "$missing_repo" rev-parse HEAD)
missing_blob=$(git -C "$missing_repo" rev-parse 'HEAD:missing.txt')
rm "$missing_repo/.git/objects/${missing_blob:0:2}/${missing_blob:2}"
rm "$missing_repo/missing.txt"
jq -n --arg tree "$missing_tree" --arg base "$missing_base" --arg inventory "$cap_inventory" \
  '{candidate_tree_oid:$tree,base_oid:$base,contract_inventory_sha256:$inventory,context_requests:[{tree:"BASE",path:"missing.txt"}]}' \
  > "$missing_request"
python3 .claude/scripts/verify-bundle.py \
  --repo "$missing_repo" --base HEAD --task missing \
  --context-request-file "$missing_request" --output "$missing_bundle" >/dev/null
missing_metadata=$(head -1 "$missing_bundle" | sed -e 's/^<!-- fsd-artifact: //' -e 's/ -->$//')
assert_cmd "missing blob is an evidence gap" jq -e '[.context_blob_metadata[] | select(.evidence_gap == "missing_blob")] | length == 1' <<<"$missing_metadata"

sub_source=$(mktemp -d "$TMPROOT/sub-source.XXXXXX")
sub_parent=$(mktemp -d "$TMPROOT/sub-parent.XXXXXX")
(
  cd "$sub_source" || exit 1
  git init -q
  git config user.email test@example.com
  git config user.name Test
  printf 'sub\n' > file.txt
  git add file.txt
  git commit -q -m init
)
(
  cd "$sub_parent" || exit 1
  git init -q
  git config user.email test@example.com
  git config user.name Test
  git -c protocol.file.allow=always submodule add -q "$sub_source" sub
  git commit -q -am init
  printf 'dirty\n' > sub/file.txt
)
sub_bundle="$TMPROOT/submodule-bundle.md"
python3 .claude/scripts/verify-bundle.py \
  --repo "$sub_parent" --base HEAD --task submodule --output "$sub_bundle" >/dev/null
sub_metadata=$(head -1 "$sub_bundle" | sed -e 's/^<!-- fsd-artifact: //' -e 's/ -->$//')
assert_cmd "dirty submodule is an evidence gap" jq -e '[.evidence_gaps[] | select(.reason == "dirty_submodule")] | length == 1' <<<"$sub_metadata"

binary_repo=$(mktemp -d "$TMPROOT/binary-bundle-repo.XXXXXX")
binary_bundle="$TMPROOT/binary-bundle.md"
(
  cd "$binary_repo" || exit 1
  git init -q
  git config user.email test@example.com
  git config user.name Test
  printf 'base\n' > README.txt
  git add README.txt
  git commit -q -m init
  head -c 1048576 /dev/urandom > large.bin
  printf 'prefix\0suffix\n' > nul.bin
)
python3 .claude/scripts/verify-bundle.py \
  --repo "$binary_repo" --base HEAD --task binary --output "$binary_bundle" >/dev/null
assert_cmd "binary patch is never embedded" bash -c '! grep -q "GIT binary patch" "$1"' _ "$binary_bundle"
assert_cmd "binary bundle is byte bounded" test "$(wc -c < "$binary_bundle")" -lt 524288
assert_contains "binary bundle retains object metadata" "$binary_bundle" '## Binary Path Metadata'
assert_contains "binary bundle records original byte count" "$binary_bundle" '"byte_count": 1048576'
assert_contains "NUL-bearing blob retains binary metadata" "$binary_bundle" '"path": "nul.bin"'
assert_cmd "NUL-bearing patch is never embedded" python3 - "$binary_bundle" <<'PY'
from pathlib import Path
import sys

assert b"\0" not in Path(sys.argv[1]).read_bytes()
PY

rename_repo=$(mktemp -d "$TMPROOT/rename-bundle-repo.XXXXXX")
rename_bundle="$TMPROOT/rename-bundle.md"
(
  cd "$rename_repo" || exit 1
  git init -q
  git config user.email test@example.com
  git config user.name Test
  seq 1 5000 | sed 's/^/base-/' > old.txt
  git add old.txt
  git commit -q -m init
  mv old.txt new.txt
  seq 1 2501 | sed 's/^/added-/' >> new.txt
)
python3 .claude/scripts/verify-bundle.py \
  --repo "$rename_repo" --base HEAD --task rename --output "$rename_bundle" \
  --max-full-diff-lines 10 >/dev/null
assert_contains "large rename sample uses destination path" "$rename_bundle" 'old.txt -> new.txt'
assert_contains "large rename sample includes appended behavior" "$rename_bundle" 'added-2500'

removed_secret_repo=$(mktemp -d "$TMPROOT/removed-secret-repo.XXXXXX")
removed_secret_bundle="$TMPROOT/removed-secret-bundle.md"
removed_payload='Authorization: Bearer '"removed_diff_canary_17a2"
(
  cd "$removed_secret_repo" || exit 1
  git init -q
  git config user.email test@example.com
  git config user.name Test
  printf '%s\n' "$removed_payload" > config.txt
  git add config.txt
  git commit -q -m init
  printf 'credential removed\n' > config.txt
)
python3 .claude/scripts/verify-bundle.py \
  --repo "$removed_secret_repo" --base HEAD --task removal --output "$removed_secret_bundle" >/dev/null
assert_contains "credential-bearing deletion omits the unsafe diff" "$removed_secret_bundle" 'credential_like_diff_omitted'
assert_cmd "credential-bearing deletion never reaches the bundle" \
  bash -c '! grep -q removed_diff_canary_17a2 "$1"' _ "$removed_secret_bundle"

secret_repo=$(mktemp -d "$TMPROOT/secret-bundle-repo.XXXXXX")
secret_bundle="$TMPROOT/secret-bundle.md"
secret_error="$TMPROOT/secret-bundle.err"
(
  cd "$secret_repo" || exit 1
  git init -q
  git config user.email test@example.com
  git config user.name Test
  printf 'base\n' > safe.txt
  git add safe.txt
  git commit -q -m init
  candidate_payload='Authorization: Bearer '"fsd_candidate_canary_17a2" # pragma: allowlist secret
  printf '%s\n' "$candidate_payload" > local-credentials.txt
)
assert_cmd "candidate secret fails before bundle write" \
  bash -c '! python3 "$1" --repo "$2" --base HEAD --task secret --output "$3" >"$4.out" 2>"$4"' \
  _ "$ROOT/.claude/scripts/verify-bundle.py" "$secret_repo" "$secret_bundle" "$secret_error"
assert_cmd "candidate secret value is not echoed" bash -c '! grep -q fsd_candidate_canary "$1"' _ "$secret_error"
assert_cmd "candidate secret leaves no bundle" test ! -e "$secret_bundle"
rm "$secret_repo/local-credentials.txt"

printf -v escaped_candidate '{\\"%s\\":\\"%s\\"}' \
  'ADMIN_PASSWORD' 'fsd_escaped_canary_17a2'
printf '%s\n' "$escaped_candidate" > "$secret_repo/escaped.json"
assert_cmd "escaped candidate secret fails before bundle write" \
  bash -c '! python3 "$1" --repo "$2" --base HEAD --task secret --output "$3" >"$4.out" 2>"$4"' \
  _ "$ROOT/.claude/scripts/verify-bundle.py" "$secret_repo" "$secret_bundle" "$secret_error"
assert_cmd "escaped candidate secret value is not echoed" \
  bash -c '! grep -q fsd_escaped_canary "$1"' _ "$secret_error"
rm "$secret_repo/escaped.json"

triple_quote='"""'
printf '%s=%s%s%s\n' 'ADMIN_PASSWORD' "$triple_quote" "fsd_triple_canary_17a2" "$triple_quote" \
  > "$secret_repo/triple.py"
assert_cmd "triple-quoted candidate secret fails before bundle write" \
  bash -c '! python3 "$1" --repo "$2" --base HEAD --task secret --output "$3" >"$4.out" 2>"$4"' \
  _ "$ROOT/.claude/scripts/verify-bundle.py" "$secret_repo" "$secret_bundle" "$secret_error"
assert_cmd "triple-quoted candidate secret value is not echoed" \
  bash -c '! grep -q fsd_triple_canary "$1"' _ "$secret_error"
rm "$secret_repo/triple.py"

evidence_tree=$(python3 .claude/scripts/verify-bundle.py \
  --repo "$secret_repo" --base HEAD --candidate-tree-only | jq -r .candidate_tree_oid)
evidence_payload='Authorization: Bearer '"fsd_evidence_canary_17a2" # pragma: allowlist secret
jq -n --arg tree "$evidence_tree" --arg summary "$evidence_payload" \
  '{candidate_tree_oid:$tree,commands:[{command:"verify",exit_code:0,summary:$summary}]}' \
  > "$TMPROOT/secret-evidence.json"
assert_cmd "evidence secret fails before bundle write" \
  bash -c '! python3 "$1" --repo "$2" --base HEAD --task evidence --evidence-file "$3" --output "$4" >"$5.out" 2>"$5"' \
  _ "$ROOT/.claude/scripts/verify-bundle.py" "$secret_repo" "$TMPROOT/secret-evidence.json" "$secret_bundle" "$secret_error"
assert_cmd "evidence secret value is not echoed" bash -c '! grep -q fsd_evidence_canary "$1"' _ "$secret_error"

inventory_payload='client_''secret''='"fsd_inventory_canary_17a2"
jq -n --arg summary "$inventory_payload" \
  '[{ref:"REQ-001",id:"REQ-001",summary:$summary}]' > "$TMPROOT/secret-inventory.json"
assert_cmd "inventory secret fails before bundle write" \
  bash -c '! python3 "$1" --repo "$2" --base HEAD --task inventory --inventory-file "$3" --output "$4" >"$5.out" 2>"$5"' \
  _ "$ROOT/.claude/scripts/verify-bundle.py" "$secret_repo" "$TMPROOT/secret-inventory.json" "$secret_bundle" "$secret_error"
assert_cmd "inventory secret value is not echoed" bash -c '! grep -q fsd_inventory_canary "$1"' _ "$secret_error"

if [[ "$failures" -eq 0 ]]; then
  printf '\nshared workflow extraction tests passed.\n'
  exit 0
fi

printf '\n%d shared workflow extraction assertion(s) failed.\n' "$failures" >&2
exit "$failures"
