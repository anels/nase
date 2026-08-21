#!/usr/bin/env bash
# Regression tests for .claude/scripts/effort-state.py.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/effort-state.py"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

failures=0
tests=0

report() {
  local ok="$1" name="$2" detail="${3:-}"
  if [[ "$ok" -eq 0 ]]; then
    printf 'PASS  %s\n' "$name"
  else
    printf 'FAIL  %s%s\n' "$name" "${detail:+: $detail}" >&2
    failures=$((failures + 1))
  fi
}

assert_jq() {
  local name="$1" file="$2" filter="$3"
  tests=$((tests + 1))
  if jq -e "$filter" "$file" >/dev/null 2>&1; then
    report 0 "$name"
  else
    report 1 "$name" "$(cat "$file")"
  fi
}

classify() {
  local name="$1"
  python3 "$SCRIPT" --file "$TMPDIR_TEST/$name.md" > "$TMPDIR_TEST/$name.json"
}

transition() {
  local name="$1"
  shift
  python3 "$SCRIPT" --file "$TMPDIR_TEST/$name.md" --evaluate-transition "$@" > "$TMPDIR_TEST/$name-transition.json"
}

cat > "$TMPDIR_TEST/out-of-order.md" <<'EOF'
---
status: awaiting-deploy
---

## Lifecycle
- [x] Merged
- [x] Implementation started
- [x] PR opened https://github.com/acme/widget/pull/7
- [ ] Deployed
EOF
classify out-of-order
assert_jq "highest checked stage wins despite line order" "$TMPDIR_TEST/out-of-order.json" \
  '.stage == "awaiting_deploy" and .needs_live_verification == false and ([.evidence[].label] | index("Merged"))'

cat > "$TMPDIR_TEST/no-header.md" <<'EOF'
---
status: in-review
---

## Grill Session
- [x] Reviewed proposal

- [x] Implementation started
- [x] PR opened - acme/widget#42
EOF
classify no-header
assert_jq "canonical checkboxes work without Lifecycle header" "$TMPDIR_TEST/no-header.json" \
  '.stage == "in_review" and .method == "lifecycle"'

cat > "$TMPDIR_TEST/frontmatter.md" <<'EOF'
---
status: in-progress
---

## Plan
- [x] Step 1
EOF
classify frontmatter
assert_jq "frontmatter fallback ignores ordinary task checkboxes" "$TMPDIR_TEST/frontmatter.json" \
  '.stage == "implementing" and .method == "frontmatter" and (.evidence | length) == 0'

cat > "$TMPDIR_TEST/conflict.md" <<'EOF'
---
status: awaiting-deploy
---

- [x] Implementation started
- [x] PR opened
EOF
classify conflict
assert_jq "frontmatter conflict is explicit" "$TMPDIR_TEST/conflict.json" \
  '.stage == "in_review" and .needs_live_verification == true'

cat > "$TMPDIR_TEST/follow-up.md" <<'EOF'
---
status: awaiting-deploy
---

## Lifecycle
- [x] Implementation started
- [x] PR opened
- [x] Merged
- [x] Deployed
- [ ] Follow-up: confirm dashboard latency
EOF
classify follow-up
assert_jq "deployed effort with pending follow-up is follow-up only" "$TMPDIR_TEST/follow-up.json" \
  '.stage == "follow_up_only" and .pending_followups == 1'

transition out-of-order --delivery-pr-state MERGED --delivery-pr-state CLOSED --jira-state "done"
assert_jq "awaiting-deploy transition is idempotent" "$TMPDIR_TEST/out-of-order-transition.json" \
  '.transition == {"action":"none","reason":"already-awaiting-deploy","status":null}'

cat > "$TMPDIR_TEST/merged.md" <<'EOF'
---
status: merge-ready
---

- [x] Merged
- [ ] Deployed
EOF
transition merged --delivery-pr-state MERGED --delivery-pr-state CLOSED --jira-state "done"
assert_jq "merged delivery waits for deploy" "$TMPDIR_TEST/merged-transition.json" \
  '.transition == {"action":"update","reason":"merged-awaiting-deploy","status":"awaiting-deploy"}'

transition follow-up --delivery-pr-state MERGED --jira-state "done"
assert_jq "pending follow-up blocks completion" "$TMPDIR_TEST/follow-up-transition.json" \
  '.transition.action == "none" and .transition.reason == "already-awaiting-deploy"'

cat > "$TMPDIR_TEST/deployed.md" <<'EOF'
---
status: awaiting-deploy
---

- [x] Merged
- [x] Deployed
EOF
transition deployed --delivery-pr-state MERGED --jira-state "done"
assert_jq "deployed delivery moves to completed" "$TMPDIR_TEST/deployed-transition.json" \
  '.transition == {"action":"move","reason":"deployed","status":"completed","destination_dir":"workspace/efforts/done"}'

transition frontmatter --delivery-pr-state CLOSED --delivery-pr-state CLOSED --jira-state not-done
assert_jq "all closed delivery PRs move to wontfix" "$TMPDIR_TEST/frontmatter-transition.json" \
  '.transition == {"action":"move","reason":"all-delivery-prs-closed","status":"wontfix","destination_dir":"workspace/efforts/done"}'

transition frontmatter --delivery-pr-state UNREADABLE --jira-state "done"
assert_jq "unreadable delivery PR blocks transition" "$TMPDIR_TEST/frontmatter-transition.json" \
  '.transition.reason == "unreadable-delivery-pr" and .transition.action == "none"'

transition frontmatter --delivery-pr-state MERGED --jira-state unreadable
assert_jq "unreadable Jira blocks transition" "$TMPDIR_TEST/frontmatter-transition.json" \
  '.transition.reason == "unreadable-jira" and .transition.action == "none"'

transition frontmatter --delivery-pr-state MERGED --jira-state not-done
assert_jq "unfinished Jira blocks merged transition" "$TMPDIR_TEST/frontmatter-transition.json" \
  '.transition.reason == "jira-not-done" and .transition.action == "none"'

transition frontmatter --delivery-pr-state OPEN --delivery-pr-state MERGED --jira-state "done"
assert_jq "open delivery PR blocks transition" "$TMPDIR_TEST/frontmatter-transition.json" \
  '.transition.reason == "open-delivery-pr" and .transition.action == "none"'

transition frontmatter --delivery-pr-state MERGED --jira-state "done" --blocked-by-unresolved
assert_jq "unresolved blocker blocks transition" "$TMPDIR_TEST/frontmatter-transition.json" \
  '.transition.reason == "unresolved-blocker" and .transition.action == "none"'

transition frontmatter --jira-state untracked
assert_jq "missing delivery PR blocks transition" "$TMPDIR_TEST/frontmatter-transition.json" \
  '.transition.reason == "no-delivery-pr" and .transition.action == "none"'

# Multi-PR efforts: PRs that were planned but never opened have no entry in
# delivery_pr_states, so merged evidence alone used to read as "all done" and
# archive live work.

cat > "$TMPDIR_TEST/multi-pr-placeholder.md" <<'EOF'
---
status: in-progress
scope: initiative
---

## Lifecycle
- [x] Implementation started
- [x] PR opened - PR1 https://github.com/acme/platform/pull/101
- [ ] PR2 - cache the health probe - not started
- [ ] PR3 - add deployment verification - not started
- [ ] Deployed (if applicable)
EOF

classify multi-pr-placeholder
assert_jq "unchecked lifecycle rows are reported as undelivered" "$TMPDIR_TEST/multi-pr-placeholder.json" \
  '(.undelivered | length) == 2 and (.undelivered[0].text | startswith("PR2"))'

transition multi-pr-placeholder --delivery-pr-state MERGED --jira-state untracked
assert_jq "undelivered lifecycle rows block the merged transition" "$TMPDIR_TEST/multi-pr-placeholder-transition.json" \
  '.transition.reason == "undelivered-lifecycle-rows" and .transition.action == "none" and (.transition.undelivered | length) == 2'

transition multi-pr-placeholder --delivery-pr-state CLOSED --jira-state untracked
assert_jq "undelivered lifecycle rows block the all-closed transition" "$TMPDIR_TEST/multi-pr-placeholder-transition.json" \
  '.transition.reason == "undelivered-lifecycle-rows" and .transition.action == "none" and (.transition.undelivered | length) == 2'

# The outstanding PRs are recorded as a trailing clause on the *checked* row
# instead of getting rows of their own in a legacy multi-PR document.
cat > "$TMPDIR_TEST/multi-pr-inline.md" <<'EOF'
---
status: awaiting-deploy
---

## Lifecycle
- [x] Implementation started - PR-1 of 3
- [x] PR opened - PR-1 https://github.com/acme/dashboard/pull/173 (draft); PR-1b (propagation) + PR-2 (monitoring) still pending
- [x] Review passed
- [x] Merged — 2026-06-30 (#173)
- [ ] Deployed (if applicable)
EOF

transition multi-pr-inline --delivery-pr-state MERGED --jira-state untracked
assert_jq "outstanding-PR clause on a checked row blocks the transition" "$TMPDIR_TEST/multi-pr-inline-transition.json" \
  '.transition.reason == "undelivered-lifecycle-rows" and .transition.action == "none"'

cat > "$TMPDIR_TEST/nested-lifecycle.md" <<'EOF'
---
status: awaiting-deploy
---

## Lifecycle
- [x] PR opened - PR1 https://github.com/acme/platform/pull/103
- [x] Merged
- [x] Deployed

### Remaining deliverables
- [ ] PR2 - second deliverable
EOF

transition nested-lifecycle --delivery-pr-state MERGED --jira-state untracked
assert_jq "nested lifecycle headings retain undelivered rows" "$TMPDIR_TEST/nested-lifecycle-transition.json" \
  '.transition.reason == "undelivered-lifecycle-rows" and .transition.action == "none"'

cat > "$TMPDIR_TEST/duplicate-lifecycle.md" <<'EOF'
---
status: awaiting-deploy
---

## Lifecycle
- [x] PR opened - PR1 https://github.com/acme/platform/pull/104
- [x] Merged
- [x] Deployed

## Notes
First delivery completed.

## Lifecycle
- [ ] PR2 - second deliverable
EOF

transition duplicate-lifecycle --delivery-pr-state MERGED --jira-state untracked
assert_jq "all lifecycle sections retain undelivered rows" "$TMPDIR_TEST/duplicate-lifecycle-transition.json" \
  '.transition.reason == "undelivered-lifecycle-rows" and .transition.action == "none"'

cat > "$TMPDIR_TEST/validation-deliverable.md" <<'EOF'
---
status: in-progress
---

## Lifecycle
- [x] PR opened - PR1 https://github.com/acme/platform/pull/105
- [ ] PR2 validation endpoint rollout - not started
- [ ] Deployed (if applicable)
EOF

transition validation-deliverable --delivery-pr-state MERGED --jira-state untracked
assert_jq "validation wording does not hide a planned deliverable" "$TMPDIR_TEST/validation-deliverable-transition.json" \
  '.transition.reason == "undelivered-lifecycle-rows" and .transition.action == "none"'

cat > "$TMPDIR_TEST/legacy-target-count.md" <<'EOF'
---
status: awaiting-deploy
---

Target PR count: 2

## Lifecycle
- [x] PR opened - PR1 https://github.com/acme/platform/pull/106
- [x] Merged
- [x] Deployed
EOF

transition legacy-target-count --delivery-pr-state MERGED --jira-state untracked
assert_jq "legacy target PR count blocks a partial delivery" "$TMPDIR_TEST/legacy-target-count-transition.json" \
  '.transition.reason == "undelivered-lifecycle-rows" and .transition.action == "none" and (.transition.undelivered[0].text | contains("Target PR count: 2"))'

# The same reasoning applies to the terminal wontfix path: a plan whose first PR
# was closed is not abandoned while later PRs are still owed.
cat > "$TMPDIR_TEST/multi-pr-closed.md" <<'EOF'
---
status: in-progress
---

## Lifecycle
- [x] PR opened - PR1 https://github.com/acme/platform/pull/102
- [ ] PR2 - second deliverable, not started
- [ ] Deployed (if applicable)
EOF

transition multi-pr-closed --delivery-pr-state CLOSED --jira-state untracked
assert_jq "undelivered rows also block the wontfix transition" "$TMPDIR_TEST/multi-pr-closed-transition.json" \
  '.transition.reason == "undelivered-lifecycle-rows" and .transition.action == "none"'

# The rows that stay unchecked *because* an effort is awaiting deploy must not
# block the very transition that sets awaiting-deploy, or nothing could ever move.
cat > "$TMPDIR_TEST/benign-rows.md" <<'EOF'
---
status: in-progress
---

## Lifecycle
- [x] Implementation started
- [x] PR opened - https://github.com/acme/widget/pull/201
- [ ] Review passed
- [ ] Merged
- [ ] Deployed (if applicable)
- [ ] Deployed to alpha
- [ ] Alpha validation complete
- [ ] Outcome: promote to prod / park
- [ ] Effort doc moved to `workspace/efforts/done/`
EOF

classify benign-rows
assert_jq "deploy and bookkeeping rows are not undelivered work" "$TMPDIR_TEST/benign-rows.json" \
  '(.undelivered | length) == 0 and (.pending_postdeploy_validation | length) == 2'

transition benign-rows --delivery-pr-state MERGED --jira-state untracked
assert_jq "benign unchecked rows still allow awaiting-deploy" "$TMPDIR_TEST/benign-rows-transition.json" \
  '.transition.reason == "merged-awaiting-deploy" and .transition.status == "awaiting-deploy"'

cat > "$TMPDIR_TEST/pending-postdeploy.md" <<'EOF'
---
status: awaiting-deploy
---

## Lifecycle
- [x] PR opened - https://github.com/acme/widget/pull/203
- [x] Merged
- [x] Deployed to alpha
- [ ] Alpha validation complete
EOF

transition pending-postdeploy --delivery-pr-state MERGED --jira-state "done"
assert_jq "pending post-deploy validation blocks completion" "$TMPDIR_TEST/pending-postdeploy-transition.json" \
  '.transition == {"action":"none","reason":"pending-postdeploy-validation","status":null}'

cat > "$TMPDIR_TEST/validated-deploy.md" <<'EOF'
---
status: awaiting-deploy
---

## Lifecycle
- [x] PR opened - https://github.com/acme/widget/pull/204
- [x] Merged
- [x] Deployed to alpha
- [x] Alpha validation complete
EOF

transition validated-deploy --delivery-pr-state MERGED --jira-state "done"
assert_jq "checked post-deploy validation allows completion" "$TMPDIR_TEST/validated-deploy-transition.json" \
  '.transition == {"action":"move","reason":"deployed","status":"completed","destination_dir":"workspace/efforts/done"}'

# Unchecked rows outside the Lifecycle section are implementation-plan steps that
# authors routinely leave unticked after the work lands; treating them as owed
# deliverables would hold back nearly every effort.
cat > "$TMPDIR_TEST/plan-steps-outside.md" <<'EOF'
---
status: in-progress
---

## Lifecycle
- [x] Implementation started
- [x] PR opened - https://github.com/acme/widget/pull/202
- [ ] Deployed (if applicable)

## Implementation Plan
- [ ] **Step 1** — add the taxonomy
- [ ] **Step 2** — wire the caller guard
EOF

classify plan-steps-outside
assert_jq "plan steps outside Lifecycle are not undelivered work" "$TMPDIR_TEST/plan-steps-outside.json" \
  '(.undelivered | length) == 0'

transition plan-steps-outside --delivery-pr-state MERGED --jira-state untracked
assert_jq "plan steps outside Lifecycle do not block the transition" "$TMPDIR_TEST/plan-steps-outside-transition.json" \
  '.transition.status == "awaiting-deploy"'

# `done/` is the record of what this workspace delivered, so an effort someone else
# owns closes straight into the yearly archive instead of padding that record.
cat > "$TMPDIR_TEST/tracking-only.md" <<'EOF'
---
status: awaiting-deploy
tracking_only: true
owner: someone-else
---

## Lifecycle
- [x] PR opened - https://github.com/acme/widget/pull/301
- [x] Merged
- [x] Deployed to prod
EOF

classify tracking-only
assert_jq "tracking_only frontmatter is surfaced" "$TMPDIR_TEST/tracking-only.json" \
  '.tracking_only == true'

transition tracking-only --delivery-pr-state MERGED --jira-state "done" --archive-year 2031
assert_jq "tracking-only completion archives instead of done/" "$TMPDIR_TEST/tracking-only-transition.json" \
  '.transition == {"action":"move","reason":"deployed","status":"completed","destination_dir":"workspace/efforts/archive/2031"}'

sed 's/tracking_only: true/tracking_only: true # another engineer owns delivery/' \
  "$TMPDIR_TEST/tracking-only.md" > "$TMPDIR_TEST/tracking-only-commented.md"
transition tracking-only-commented --delivery-pr-state MERGED --jira-state "done" --archive-year 2031
assert_jq "valid inline YAML comment preserves tracking-only routing" \
  "$TMPDIR_TEST/tracking-only-commented-transition.json" \
  '.tracking_only == true and .tracking_only_valid == true and .transition.destination_dir == "workspace/efforts/archive/2031"'

transition tracking-only --delivery-pr-state CLOSED --jira-state "done" --archive-year 2031
assert_jq "tracking-only wontfix archives instead of done/" "$TMPDIR_TEST/tracking-only-transition.json" \
  '.transition.destination_dir == "workspace/efforts/archive/2031" and .transition.status == "wontfix"'

# The routing flag must not leak into non-terminal decisions.
transition tracking-only --delivery-pr-state OPEN --jira-state "done" --archive-year 2031
assert_jq "non-terminal transitions carry no destination" "$TMPDIR_TEST/tracking-only-transition.json" \
  '.transition.action == "none" and (.transition | has("destination_dir") | not)'

# `status: tracked` is a lifecycle status the transitions overwrite; it must not be
# mistaken for the ownership flag, or every planning-stage effort would archive.
cat > "$TMPDIR_TEST/status-tracked.md" <<'EOF'
---
status: tracked
---

## Lifecycle
- [x] PR opened - https://github.com/acme/widget/pull/302
- [x] Merged
- [x] Deployed to prod
EOF

classify status-tracked
assert_jq "status: tracked alone is not tracking_only" "$TMPDIR_TEST/status-tracked.json" \
  '.tracking_only == false'

transition status-tracked --delivery-pr-state MERGED --jira-state "done" --archive-year 2031
assert_jq "status: tracked still completes into done/" "$TMPDIR_TEST/status-tracked-transition.json" \
  '.transition.destination_dir == "workspace/efforts/done"'

sed 's/tracking_only: true/tracking_only: sometimes/' \
  "$TMPDIR_TEST/tracking-only.md" > "$TMPDIR_TEST/tracking-only-invalid.md"
transition tracking-only-invalid --delivery-pr-state MERGED --jira-state "done" --archive-year 2031
assert_jq "invalid tracking-only scalar blocks terminal mutation" \
  "$TMPDIR_TEST/tracking-only-invalid-transition.json" \
  '.tracking_only_valid == false and .transition == {"action":"none","reason":"invalid-tracking-only","status":null}'

for invalid_scalar in '"true # literal string"' yes 1; do
  sed "s/tracking_only: true/tracking_only: $invalid_scalar/" \
    "$TMPDIR_TEST/tracking-only.md" > "$TMPDIR_TEST/tracking-only-invalid-quoted.md"
  transition tracking-only-invalid-quoted --delivery-pr-state MERGED --jira-state "done" --archive-year 2031
  assert_jq "non-contract tracking-only scalar '$invalid_scalar' fails closed" \
    "$TMPDIR_TEST/tracking-only-invalid-quoted-transition.json" \
    '.tracking_only_valid == false and .transition.reason == "invalid-tracking-only"'
done

for escaped_scalar in '"true"' '"tr\\ue"' '"tru\\e"'; do
  sed "s/tracking_only: true/tracking_only: $escaped_scalar/" \
    "$TMPDIR_TEST/tracking-only.md" > "$TMPDIR_TEST/tracking-only-invalid-escaped.md"
  transition tracking-only-invalid-escaped --delivery-pr-state MERGED --jira-state "done" --archive-year 2031
  assert_jq "quoted or escaped tracking-only scalar '$escaped_scalar' fails closed" \
    "$TMPDIR_TEST/tracking-only-invalid-escaped-transition.json" \
    '.tracking_only_valid == false and .transition.reason == "invalid-tracking-only"'
done

sed 's/tracking_only: true/tracking_only:/' \
  "$TMPDIR_TEST/tracking-only.md" > "$TMPDIR_TEST/tracking-only-empty.md"
transition tracking-only-empty --delivery-pr-state MERGED --jira-state "done" --archive-year 2031
assert_jq "empty tracking-only scalar fails closed" \
  "$TMPDIR_TEST/tracking-only-empty-transition.json" \
  '.tracking_only_valid == false and .transition.reason == "invalid-tracking-only"'

for duplicate_order in false-true true-false; do
  if [ "$duplicate_order" = false-true ]; then
    first='tracking_only: false'
    second='tracking_only: true'
  else
    first='tracking_only: true'
    second='tracking_only: false'
  fi
  awk -v first="$first" -v second="$second" \
    '{ if ($0 == "tracking_only: true") { print first; print second } else print }' \
    "$TMPDIR_TEST/tracking-only.md" > "$TMPDIR_TEST/tracking-only-duplicate.md"
  transition tracking-only-duplicate --delivery-pr-state MERGED --jira-state "done" --archive-year 2031
  assert_jq "duplicate tracking-only scalar fails closed" \
    "$TMPDIR_TEST/tracking-only-duplicate-transition.json" \
    '.tracking_only_valid == false and .transition.reason == "invalid-tracking-only"'
done

# --- unticked `Merged` row: offered only where the merge is provable ---

cat > "$TMPDIR_TEST/stale-merged.md" <<'EOF'
---
status: in-progress
repo: Widgets
pr: https://github.com/acme/widget/pull/91
---

## Lifecycle
- [x] Implementation started
- [x] PR opened - https://github.com/acme/widget/pull/91
- [ ] Merged
- [ ] Deployed (if applicable)
EOF
classify stale-merged
assert_jq "unticked Merged row is reported by classify" "$TMPDIR_TEST/stale-merged.json" \
  '(.unticked_canonical_rows | length) == 1 and .unticked_canonical_rows[0].line == 10 and .unticked_canonical_rows[0].bare_label == true'
assert_jq "unticked Merged row is not counted as owed delivery" "$TMPDIR_TEST/stale-merged.json" \
  '.undelivered == []'
transition stale-merged --delivery-pr-state MERGED --jira-state "done"
assert_jq "merged path authorizes the Merged tick alongside the status write" \
  "$TMPDIR_TEST/stale-merged-transition.json" \
  '.transition.status == "awaiting-deploy" and (.transition.stale_canonical_rows | length) == 1'

sed 's/^status: in-progress$/status: awaiting-deploy/' "$TMPDIR_TEST/stale-merged.md" \
  > "$TMPDIR_TEST/stale-merged-synced.md"
transition stale-merged-synced --delivery-pr-state MERGED --jira-state "done"
assert_jq "already-awaiting-deploy still authorizes the lagging row" \
  "$TMPDIR_TEST/stale-merged-synced-transition.json" \
  '.transition.action == "none" and .transition.reason == "already-awaiting-deploy" and (.transition.stale_canonical_rows | length) == 1'

transition stale-merged --delivery-pr-state OPEN --jira-state "done"
assert_jq "an open delivery PR authorizes no tick" \
  "$TMPDIR_TEST/stale-merged-transition.json" \
  '.transition.reason == "open-delivery-pr" and (.transition | has("stale_canonical_rows") | not)'

transition stale-merged --delivery-pr-state MERGED --jira-state not-done
assert_jq "a not-done Jira authorizes no tick" \
  "$TMPDIR_TEST/stale-merged-transition.json" \
  '.transition.reason == "jira-not-done" and (.transition | has("stale_canonical_rows") | not)'

cat > "$TMPDIR_TEST/stale-merged-ledger.md" <<'EOF'
---
status: in-progress
repo: Widgets
prs: https://github.com/acme/widget/pull/91
---

## Lifecycle
- [x] PR opened - PR1 https://github.com/acme/widget/pull/91
- [x] Merged - PR1 2026-02-01
- [ ] Merged - PR2
EOF
classify stale-merged-ledger
assert_jq "a per-PR Merged ledger offers no row to tick" "$TMPDIR_TEST/stale-merged-ledger.json" \
  '.unticked_canonical_rows == []'

cat > "$TMPDIR_TEST/stale-merged-multi.md" <<'EOF'
---
status: in-progress
repo: Widgets
pr: https://github.com/acme/widget/pull/91
---

## Lifecycle
- [x] PR opened - https://github.com/acme/widget/pull/91
- [ ] Merged - PR1
- [ ] Merged - PR2
EOF
classify stale-merged-multi
assert_jq "several unticked Merged rows stay ambiguous" "$TMPDIR_TEST/stale-merged-multi.json" \
  '.unticked_canonical_rows == []'

cat > "$TMPDIR_TEST/stale-merged-clause.md" <<'EOF'
---
status: in-progress
repo: Widgets
pr: https://github.com/acme/widget/pull/91
---

## Lifecycle
- [x] PR opened - https://github.com/acme/widget/pull/91
- [ ] Merged - PR-2 still pending
EOF
classify stale-merged-clause
assert_jq "an outstanding clause withholds the Merged row" "$TMPDIR_TEST/stale-merged-clause.json" \
  '.unticked_canonical_rows == []'
transition stale-merged-clause --delivery-pr-state MERGED --jira-state "done"
assert_jq "an outstanding unchecked Merged row blocks the merged transition" \
  "$TMPDIR_TEST/stale-merged-clause-transition.json" \
  '.transition.reason == "undelivered-lifecycle-rows"'

sed 's/PR-2 still pending/PR-1 only/' "$TMPDIR_TEST/stale-merged-clause.md" \
  > "$TMPDIR_TEST/stale-merged-only.md"
classify stale-merged-only
assert_jq "a partial Merged row ending in only is withheld" "$TMPDIR_TEST/stale-merged-only.json" \
  '.unticked_canonical_rows == []'
transition stale-merged-only --delivery-pr-state MERGED --jira-state "done"
assert_jq "a partial unchecked Merged row blocks the merged transition" \
  "$TMPDIR_TEST/stale-merged-only-transition.json" \
  '.transition.reason == "undelivered-lifecycle-rows"'

sed 's/- \[ \] Merged - PR-1 only/- [x] Merged - PR-1 only/' "$TMPDIR_TEST/stale-merged-only.md" \
  > "$TMPDIR_TEST/stale-merged-withdrawn.md"
transition stale-merged-withdrawn --delivery-pr-state MERGED --jira-state "done"
assert_jq "a checked Merged PR-only row is not treated as outstanding work" \
  "$TMPDIR_TEST/stale-merged-withdrawn-transition.json" \
  '.transition.reason == "merged-awaiting-deploy"'

# --- PR reference resolution ---

cat > "$TMPDIR_TEST/pr-refs.md" <<'EOF'
---
status: in-progress
repo: Widgets
pr: https://github.com/acme/widget/pull/91
phase_2_pr: acme/widget#92
blocked-by: acme/widget#70
---

## Lifecycle
- [x] PR opened - #93 (draft)
EOF
classify pr-refs
assert_jq "delivery set spans pr, phase_*_pr and a Lifecycle bare number" \
  "$TMPDIR_TEST/pr-refs.json" \
  '[.pr_references.delivery[] | "\(.owner)/\(.repo)#\(.number)"]
   == ["acme/widget#91","acme/widget#92","acme/widget#93"]'
assert_jq "blocked-by resolves into the dependency set, not delivery" \
  "$TMPDIR_TEST/pr-refs.json" \
  '[.pr_references.dependency[] | "\(.owner)/\(.repo)#\(.number)"] == ["acme/widget#70"]'

cat > "$TMPDIR_TEST/pr-refs-root-list.md" <<'EOF'
---
status: in-progress
repo: Widgets
prs:
- acme/widget#94
blocked-by:
- "#71"
---
EOF
classify pr-refs-root-list
assert_jq "root-level YAML lists retain delivery and dependency PRs" \
  "$TMPDIR_TEST/pr-refs-root-list.json" \
  '[.pr_references.delivery[] | "\(.owner)/\(.repo)#\(.number)"] == ["acme/widget#94"] and
   [.pr_references.dependency[] | "\(.owner)/\(.repo)#\(.number)"] == ["acme/widget#71"]'

cat > "$TMPDIR_TEST/pr-refs-spaced-list.md" <<'EOF'
---
status: in-progress
repo: acme/widget
prs:
- "#94"

# second delivery
- "#95"
blocked-by:
- "#70"

# second dependency
- "#71"
---
EOF
classify pr-refs-spaced-list
assert_jq "blank lines and comments retain every YAML list PR" \
  "$TMPDIR_TEST/pr-refs-spaced-list.json" \
  '[.pr_references.delivery[] | "\(.owner)/\(.repo)#\(.number)"] == ["acme/widget#94","acme/widget#95"] and
   [.pr_references.dependency[] | "\(.owner)/\(.repo)#\(.number)"] == ["acme/widget#70","acme/widget#71"]'

cat > "$TMPDIR_TEST/pr-refs-casefold.md" <<'EOF'
---
status: in-progress
repo: Acme/Widget
pr: Acme/Widget#95
phase_2_pr: acme/widget#95
---

Target PR count: 2
EOF
classify pr-refs-casefold
assert_jq "PR references dedupe GitHub owner and repository case" \
  "$TMPDIR_TEST/pr-refs-casefold.json" \
  '(.pr_references.delivery | length) == 1'
transition pr-refs-casefold --delivery-pr-state MERGED --jira-state untracked
assert_jq "case-only duplicate PRs cannot satisfy the target PR count" \
  "$TMPDIR_TEST/pr-refs-casefold-transition.json" \
  '.transition.reason == "undelivered-lifecycle-rows" and (.transition.undelivered | length) == 1'

cat > "$TMPDIR_TEST/pr-refs-invalid-scalar.md" <<'EOF'
---
status: in-progress
repo: acme/widget
pr: "#1 #2"
- "#3"
---
EOF
classify pr-refs-invalid-scalar
assert_jq "singular pr fields never yield multiple live references" \
  "$TMPDIR_TEST/pr-refs-invalid-scalar.json" \
  '.pr_references.delivery == [] and .pr_references.validation_errors == ["unresolved-pr"]'

cat > "$TMPDIR_TEST/pr-refs-invalid-list.md" <<'EOF'
---
status: in-progress
repo: acme/widget
prs: [acme/widget#1, acme/widget#2]
---
EOF
classify pr-refs-invalid-list
assert_jq "inline prs values never yield live references" \
  "$TMPDIR_TEST/pr-refs-invalid-list.json" \
  '.pr_references.delivery == [] and .pr_references.validation_errors == ["invalid-prs"]'

cat > "$TMPDIR_TEST/pr-refs-invalid-list-item.md" <<'EOF'
---
status: in-progress
repo: acme/widget
prs:
- acme/widget#1
- definitely-not-a-pr
---
EOF
classify pr-refs-invalid-list-item
assert_jq "malformed prs list entries fail closed" \
  "$TMPDIR_TEST/pr-refs-invalid-list-item.json" \
  '.pr_references.validation_errors == ["unresolved-prs"]'

cat > "$TMPDIR_TEST/pr-refs-duplicates.md" <<'EOF'
---
status: in-progress
repo: acme/a
repo: acme/b
pr: acme/a#1
pr: acme/a#2
prs:
- acme/a#3
prs:
- acme/a#4
blocked-by: acme/a#5
blocked-by: acme/a#6
---
EOF
classify pr-refs-duplicates
assert_jq "duplicate structured keys fail closed before live transition" \
  "$TMPDIR_TEST/pr-refs-duplicates.json" \
  '.pr_references.delivery == [] and
   .pr_references.dependency == [] and
   .pr_references.validation_errors == ["invalid-blocked-by","invalid-pr","invalid-prs","invalid-repo"]'
transition pr-refs-duplicates --delivery-pr-state MERGED --jira-state "done"
assert_jq "invalid structured references block transition" \
  "$TMPDIR_TEST/pr-refs-duplicates-transition.json" \
  '.transition.reason == "invalid-pr-reference"'

cat > "$TMPDIR_TEST/pr-refs-markdown-links.md" <<'EOF'
---
status: in-progress
repo: Acme/Widget
---

## Lifecycle
- [x] PR opened - [#4682](https://github.com/acme/widget/pull/4682); [#3012](https://github.com/acme/widget-monitoring/pull/3012)
EOF
classify pr-refs-markdown-links
assert_jq "Markdown link labels do not create bare PR duplicates" \
  "$TMPDIR_TEST/pr-refs-markdown-links.json" \
  '[.pr_references.delivery[] | "\(.owner)/\(.repo)#\(.number)"]
   == ["acme/widget#4682","acme/widget-monitoring#3012"]'

cat > "$TMPDIR_TEST/pr-refs-markdown-label-mismatch.md" <<'EOF'
---
status: in-progress
repo: acme/widget
---

## Lifecycle
- [x] PR opened - [#999](https://github.com/acme/widget/pull/1)
EOF
classify pr-refs-markdown-label-mismatch
assert_jq "a Markdown label is never a second PR citation" \
  "$TMPDIR_TEST/pr-refs-markdown-label-mismatch.json" \
  '[.pr_references.delivery[] | "\(.owner)/\(.repo)#\(.number)"] == ["acme/widget#1"]'

cat > "$TMPDIR_TEST/pr-refs-markdown-qualified-label.md" <<'EOF'
---
status: in-progress
repo: acme/widget
---

## Lifecycle
- [x] PR opened - [acme/a#1](https://github.com/acme/b/pull/2)
EOF
classify pr-refs-markdown-qualified-label
assert_jq "a qualified Markdown label is never a second PR citation" \
  "$TMPDIR_TEST/pr-refs-markdown-qualified-label.json" \
  '[.pr_references.delivery[] | "\(.owner)/\(.repo)#\(.number)"] == ["acme/b#2"]'

cat > "$TMPDIR_TEST/pr-refs-invalid-number.md" <<'EOF'
---
status: in-progress
repo: acme/widget
pr: "#0"
phase_2_pr: "#01"
---
EOF
classify pr-refs-invalid-number
assert_jq "zero and leading-zero PR numbers never become delivery evidence" \
  "$TMPDIR_TEST/pr-refs-invalid-number.json" \
  '.pr_references.delivery == [] and .stage != "in_review"'

cat > "$TMPDIR_TEST/pr-refs-slash-list.md" <<'EOF'
---
status: in-progress
repo: acme/widget
prs:
- "#101/#102/#103"
---
EOF
classify pr-refs-slash-list
assert_jq "slash-separated bare PRs retain every reference" \
  "$TMPDIR_TEST/pr-refs-slash-list.json" \
  '[.pr_references.delivery[] | "\(.owner)/\(.repo)#\(.number)"] == ["acme/widget#101","acme/widget#102","acme/widget#103"]'

cat > "$TMPDIR_TEST/pr-refs-nearest.md" <<'EOF'
---
status: in-progress
repo: multiple
prs:
- acme/a#1, acme/b#2, #3
---
EOF
classify pr-refs-nearest
assert_jq "each bare number uses its nearest same-line repository context" \
  "$TMPDIR_TEST/pr-refs-nearest.json" \
  '[.pr_references.delivery[] | "\(.owner)/\(.repo)#\(.number)"]
   == ["acme/a#1","acme/b#2","acme/b#3"]'

cat > "$TMPDIR_TEST/pr-refs-nearest-url.md" <<'EOF'
---
status: in-progress
repo: multiple
prs:
- https://github.com/acme/very-long-repository-name/pull/1 acme/b#2 #3
---
EOF
classify pr-refs-nearest-url
assert_jq "same-line full URLs do not shift bare reference proximity" \
  "$TMPDIR_TEST/pr-refs-nearest-url.json" \
  '[.pr_references.delivery[] | "\(.owner)/\(.repo)#\(.number)"]
   == ["acme/b#2","acme/b#3","acme/very-long-repository-name#1"]'

cat > "$TMPDIR_TEST/pr-refs-same-number.md" <<'EOF'
---
status: in-progress
repo: multiple
prs:
- acme/a#1, acme/b#2, #1
---
EOF
classify pr-refs-same-number
assert_jq "a bare PR sharing another repository's number remains evidence" \
  "$TMPDIR_TEST/pr-refs-same-number.json" \
  '[.pr_references.delivery[] | "\(.owner)/\(.repo)#\(.number)"]
   == ["acme/a#1","acme/b#1","acme/b#2"]'

cat > "$TMPDIR_TEST/pr-refs-denied-context.md" <<'EOF'
---
status: in-progress
repo: multiple
---

## Lifecycle
- [x] PR opened - #310

## Notes
Query numbers, **not** PR numbers: acme/wrong#5
EOF
classify pr-refs-denied-context
assert_jq "denied shorthand does not supply bare PR repository context" \
  "$TMPDIR_TEST/pr-refs-denied-context.json" \
  '.pr_references.delivery == [] and
   [.pr_references.discarded_bare[] | select(.number == 310).reason] == ["no-repo-context"]'

cat > "$TMPDIR_TEST/pr-refs-denied.md" <<'EOF'
---
status: awaiting-deploy
repo: Widgets
---

## Lifecycle
- [x] PR opened - [#310](https://github.com/acme/widget/pull/310) - wraps queries 5/6/7 (query numbers, **not** PR numbers - a bare sweep resolved `#5` to the unrelated CLOSED `acme/widget#5`)
EOF
classify pr-refs-denied
assert_jq "a row disclaiming its numbers keeps only the full URL" \
  "$TMPDIR_TEST/pr-refs-denied.json" \
  '[.pr_references.delivery[] | "\(.owner)/\(.repo)#\(.number)"] == ["acme/widget#310"]'
assert_jq "the disclaimed numbers are reported as discarded" \
  "$TMPDIR_TEST/pr-refs-denied.json" \
  '[.pr_references.discarded_bare[] | .number] == [5] and
   (.pr_references.discarded_bare[0].reason == "denied-in-row")'

cat > "$TMPDIR_TEST/pr-refs-prose.md" <<'EOF'
---
status: in-progress
---

## Plan
Ship it. Fixes #4321 per the CHANGELOG and closes grill #3.

## Lifecycle
- [x] Implementation started
EOF
classify pr-refs-prose
assert_jq "bare numbers outside Lifecycle and without repo context stay out" \
  "$TMPDIR_TEST/pr-refs-prose.json" \
  '.pr_references.delivery == [] and .pr_references.dependency == []'

cat > "$TMPDIR_TEST/pr-refs-freetext-blocker.md" <<'EOF'
---
status: blocked
repo: widget
blocked-by: Helen / PO - business element list definition; 3 DMs sent, no reply
pr: https://github.com/acme/widget/pull/12
---

## Lifecycle
- [x] PR opened - https://github.com/acme/widget/pull/12
EOF
classify pr-refs-freetext-blocker
assert_jq "a free-text scalar blocked-by is a legal shape, not a reference defect" \
  "$TMPDIR_TEST/pr-refs-freetext-blocker.json" \
  '.pr_references.validation_errors == [] and .pr_references.dependency == []'
transition pr-refs-freetext-blocker --delivery-pr-state MERGED --jira-state untracked --blocked-by-unresolved
assert_jq "a free-text blocker reports its own reason, never invalid-pr-reference" \
  "$TMPDIR_TEST/pr-refs-freetext-blocker-transition.json" \
  '.transition.reason != "invalid-pr-reference"'

cat > "$TMPDIR_TEST/pr-refs-annotated-repo.md" <<'EOF'
---
status: in-progress
repo: acme/widget (live; was greenfield at kickoff)
---

## Lifecycle
- [x] PR opened - #21
EOF
classify pr-refs-annotated-repo
assert_jq "trailing prose after an owner-qualified repo still resolves bare numbers" \
  "$TMPDIR_TEST/pr-refs-annotated-repo.json" \
  '.pr_references.validation_errors == [] and
   [.pr_references.delivery[] | "\(.owner)/\(.repo)#\(.number)"] == ["acme/widget#21"]'

cat > "$TMPDIR_TEST/pr-refs-annotated-alias.md" <<'EOF'
---
status: in-progress
repo: widget (+ acme/frontend coordination)
---

## Lifecycle
- [x] PR opened - #22
EOF
classify pr-refs-annotated-alias
assert_jq "an annotated bare repo alias supplies no owner and is reported, not rejected" \
  "$TMPDIR_TEST/pr-refs-annotated-alias.json" \
  '.pr_references.validation_errors == [] and
   .pr_references.delivery == [] and
   [.pr_references.discarded_bare[] | .reason] == ["no-repo-context"]'

cat > "$TMPDIR_TEST/pr-refs-malformed-repo.md" <<'EOF'
---
status: in-progress
repo: acme/widget/extra
---

## Lifecycle
- [x] PR opened - #23
EOF
classify pr-refs-malformed-repo
assert_jq "a repo identifier that is not owner/repo still fails closed" \
  "$TMPDIR_TEST/pr-refs-malformed-repo.json" \
  '.pr_references.validation_errors == ["invalid-repo"]'

cat > "$TMPDIR_TEST/pr-refs-no-lifecycle-section.md" <<'EOF'
---
status: in-progress
repo: acme/widget
---

- [x] PR opened - #24
EOF
classify pr-refs-no-lifecycle-section
assert_jq "a bare number on a canonical row outside any Lifecycle section is reported, not silently dropped" \
  "$TMPDIR_TEST/pr-refs-no-lifecycle-section.json" \
  '.pr_references.delivery == [] and
   [.pr_references.discarded_bare[] | "\(.number):\(.reason)"] == ["24:outside-lifecycle"]'

printf '\n--- %d pass, %d fail ---\n' "$((tests - failures))" "$failures"
[ "$failures" -eq 0 ]
