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

# A doc with no `## Lifecycle` block is unfalsifiable: nothing can contradict its
# frontmatter, so `needs_live_verification` never fires and the status reads as
# authoritative forever. The structure block is the only place that shows up.
cat > "$TMPDIR_TEST/structure-no-lifecycle.md" <<'EOF'
---
status: completed
repo: acme/widget
---

## Effort: no lifecycle block anywhere
EOF
classify structure-no-lifecycle
assert_jq "a doc with no Lifecycle section is reported as a structural defect" \
  "$TMPDIR_TEST/structure-no-lifecycle.json" \
  '.structure.has_lifecycle_section == false and
   .structure.umbrella == false and
   (.structure.defects | index("no-lifecycle-section") != null)'

# An umbrella parent indexes child efforts and delivers nothing itself, so it has no
# deliverable to record and must not be repaired into having a lifecycle it does not have.
cat > "$TMPDIR_TEST/structure-umbrella.md" <<'EOF'
---
status: wontfix
repo: acme/widget
children:
  - child-one
  - child-two
---

## Effort: umbrella roadmap
EOF
classify structure-umbrella
assert_jq "an umbrella parent is exempt from the Lifecycle requirement" \
  "$TMPDIR_TEST/structure-umbrella.json" \
  '.structure.umbrella == true and (.structure.defects | length) == 0'

# `partial_delivery` records that the code shipped while `status` stays honest about the
# effort. `partial_delivery_prs` is a record of past merges and must not reach the delivery
# set, or a terminal doc's own history would read as fresh transition evidence.
cat > "$TMPDIR_TEST/structure-partial.md" <<'EOF'
---
status: wontfix
repo: acme/widget
partial_delivery: true
partial_delivery_prs:
  - https://github.com/acme/widget/pull/4892
---

## Lifecycle
- [x] PR opened - https://github.com/acme/widget/pull/4892
EOF
classify structure-partial
assert_jq "partial_delivery parses and partial_delivery_prs stays out of the delivery set" \
  "$TMPDIR_TEST/structure-partial.json" \
  '.structure.partial_delivery == true and
   .structure.partial_delivery_valid == true and
   .pr_references.validation_errors == [] and
   ([.pr_references.delivery[].number] | length) == 1'

# The narrow boolean contract, same as `tracking_only`: a quoted or free-text value is not
# a silent false, it is a doc defect, because "maybe" must never read as "no delivery".
cat > "$TMPDIR_TEST/structure-partial-bad.md" <<'EOF'
---
status: wontfix
repo: acme/widget
partial_delivery: "yes"
---

## Lifecycle
- [x] PR opened - https://github.com/acme/widget/pull/1
EOF
classify structure-partial-bad
assert_jq "a non-canonical partial_delivery value is a defect, not a silent false" \
  "$TMPDIR_TEST/structure-partial-bad.json" \
  '.structure.partial_delivery_valid == false and
   (.structure.defects | index("invalid-partial-delivery") != null)'

# --- next_action: what /nase:efforts does after the transition ---------------------------

next_action() {
  local name="$1" live="$2"
  shift 2
  python3 "$SCRIPT" --file "$TMPDIR_TEST/$name.md" --evaluate-transition \
    --live-json "$TMPDIR_TEST/$live.json" "$@" > "$TMPDIR_TEST/$name-next.json"
}

write_effort() {
  local name="$1" status="$2"
  {
    printf -- '---\nstatus: %s\nrepo: acme/widget\n---\n\n## Lifecycle\n' "$status"
    cat
  } > "$TMPDIR_TEST/$name.md"
}

run_py() {
  {
    cat <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("effort_state", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.path.insert(0, sys.argv[1].rsplit("/", 1)[0])
spec.loader.exec_module(module)
PY
    cat
  } | python3 - "$SCRIPT"
}

live_json() {
  local name="$1" state="$2" files="$3" checks="$4" truncated="${5:-false}"
  jq -n --arg state "$state" --argjson files "$files" --arg checks "$checks" \
    --argjson truncated "$truncated" \
    '{live: {"acme/widget#10": {state: $state, mergeCommit: "abc1234def", files: $files,
      files_truncated: $truncated, merge_checks: $checks}}}' > "$TMPDIR_TEST/$name.json"
}

safe_files='["tests/a.test.ts","docs/guide.md",".github/workflows/ci.yml","README.md","src/Foo.Tests/Bar.cs"]'
live_json live-safe MERGED "$safe_files" success
live_json live-code MERGED '["tests/a.test.ts","src/app.cs"]' success
live_json live-failing MERGED "$safe_files" failure
live_json live-unknown MERGED "$safe_files" unknown
live_json live-pending MERGED "$safe_files" pending
live_json live-none MERGED "$safe_files" none
live_json live-truncated MERGED "$safe_files" success true
live_json live-unread MERGED null success
live_json live-open OPEN "$safe_files" success

write_effort na-close awaiting-deploy <<'EOF'
- [x] Implementation started
- [x] PR opened - https://github.com/acme/widget/pull/10
- [x] Merged - 2026-11-01
- [ ] Deployed (if applicable)

## Validation
- [ ] `dotnet test` stays green
EOF
next_action na-close live-safe --delivery-pr-state MERGED
assert_jq "next_action closes a tests/CI/docs-only effort and carries the exact row edit" \
  "$TMPDIR_TEST/na-close-next.json" \
  '.next_action.kind == "close" and .next_action.reason == "tests-ci-docs-only" and
   .next_action.edit.line == 10 and
   .next_action.edit.old == "- [ ] Deployed (if applicable)" and
   (.next_action.edit.new | startswith("- [x] Deployed - n/a, tests/CI/docs only (acme/widget#10 merge checks success")) and
   .next_action.command == null'

next_action na-close live-safe --delivery-pr-state MERGED --jira-state "done"
assert_jq "next_action closes when the tracked Jira issue is Done" \
  "$TMPDIR_TEST/na-close-next.json" '.next_action.kind == "close"'

next_action na-close live-code --delivery-pr-state MERGED
assert_jq "one file outside the set blocks the close and names it" \
  "$TMPDIR_TEST/na-close-next.json" \
  '.next_action.kind == "ask" and .next_action.reason == "validation-heavy-not-run" and
   (.next_action.context | contains("src/app.cs"))'

write_effort na-code awaiting-deploy <<'EOF'
- [x] PR opened - https://github.com/acme/widget/pull/10
- [x] Merged
- [ ] Deployed
EOF
next_action na-code live-code --delivery-pr-state MERGED
assert_jq "one file outside the set asks for ring evidence" \
  "$TMPDIR_TEST/na-code-next.json" \
  '.next_action.kind == "ask" and .next_action.reason == "files-outside-tests-ci-docs"'

for checks in failing:merge-checks-failing unknown:merge-checks-unknown pending:merge-checks-unknown none:merge-checks-unknown; do
  next_action na-code "live-${checks%%:*}" --delivery-pr-state MERGED
  assert_jq "merge checks ${checks%%:*} never close an effort" \
    "$TMPDIR_TEST/na-code-next.json" \
    ".next_action.kind == \"ask\" and .next_action.reason == \"${checks##*:}\""
done

next_action na-code live-truncated --delivery-pr-state MERGED
assert_jq "a truncated file list is not proof and is never a close" \
  "$TMPDIR_TEST/na-code-next.json" \
  '.next_action.kind == "ask" and .next_action.reason == "files-unverified"'
next_action na-code live-unread --delivery-pr-state MERGED
assert_jq "an unread file list is not proof" \
  "$TMPDIR_TEST/na-code-next.json" '.next_action.reason == "files-unverified"'

next_action na-code live-safe --delivery-pr-state MERGED --jira-state not-done
assert_jq "Jira not Done blocks the close" \
  "$TMPDIR_TEST/na-code-next.json" \
  '.next_action.kind == "ask" and .next_action.reason == "jira-not-done"'
next_action na-code live-safe --delivery-pr-state MERGED --blocked-by-unresolved
assert_jq "an unresolved blocker blocks the close" \
  "$TMPDIR_TEST/na-code-next.json" '.next_action.reason == "delivery-state-unresolved"'
next_action na-code live-open --delivery-pr-state OPEN
assert_jq "an open delivery PR is not merged" \
  "$TMPDIR_TEST/na-code-next.json" '.next_action.reason == "delivery-pr-not-merged"'
python3 "$SCRIPT" --file "$TMPDIR_TEST/na-code.md" --evaluate-transition --delivery-pr-state MERGED \
  > "$TMPDIR_TEST/na-code-nolive.json"
assert_jq "without a live file the effort cannot close" \
  "$TMPDIR_TEST/na-code-nolive.json" \
  '.next_action.kind == "ask" and .next_action.reason == "delivery-state-unresolved"'

write_effort na-prose-row awaiting-deploy <<'EOF'
- [x] PR opened - https://github.com/acme/widget/pull/10
- [x] Merged
- [ ] Deployed to alpha - still owed: the first-time deploy on a fresh cluster
EOF
next_action na-prose-row live-safe --delivery-pr-state MERGED
assert_jq "a Deployed row with prose is never auto-ticked" \
  "$TMPDIR_TEST/na-prose-row-next.json" \
  '.next_action.kind == "ask" and .next_action.reason == "deployed-needs-ring-evidence"'

write_effort na-undelivered awaiting-deploy <<'EOF'
- [x] PR opened - https://github.com/acme/widget/pull/10
- [x] Merged
- [ ] PR-2 wire the probe
- [ ] Deployed
EOF
next_action na-undelivered live-safe --delivery-pr-state MERGED
assert_jq "an undelivered Lifecycle row blocks the close" \
  "$TMPDIR_TEST/na-undelivered-next.json" '.next_action.reason == "undelivered-row-stale"'

write_effort na-followup awaiting-deploy <<'EOF'
- [x] PR opened - https://github.com/acme/widget/pull/10
- [x] Merged
- [ ] Follow-up: tidy the helper
- [ ] Deployed
EOF
next_action na-followup live-safe --delivery-pr-state MERGED
assert_jq "a pending follow-up blocks the close" \
  "$TMPDIR_TEST/na-followup-next.json" '.next_action.reason == "pending-followups"'

write_effort na-validate awaiting-deploy <<'EOF'
- [x] PR opened - https://github.com/acme/widget/pull/10
- [x] Merged
- [x] Deployed to alpha
- [ ] Post-deploy: confirm the merge checks with `gh api -X GET repos/acme/widget/commits/abc1234def/check-runs`
- [ ] Post-deploy: grep the flag with `git grep -n NewFlag origin/main`
EOF
next_action na-validate live-code --delivery-pr-state MERGED
assert_jq "read-only post-deploy rows become a validate action with exact rows" \
  "$TMPDIR_TEST/na-validate-next.json" \
  '.next_action.kind == "validate" and (.next_action.rows | length) == 2 and
   .next_action.rows[0].line == 10 and
   .next_action.command == "gh api -X GET repos/acme/widget/commits/abc1234def/check-runs"'

write_effort na-validate-write awaiting-deploy <<'EOF'
- [x] PR opened - https://github.com/acme/widget/pull/10
- [x] Merged
- [ ] Post-deploy: re-run `gh run rerun 55 && echo done`
- [ ] Deployed
EOF
next_action na-validate-write live-code --delivery-pr-state MERGED
assert_jq "a post-deploy row that is not clearly read-only is asked, not run" \
  "$TMPDIR_TEST/na-validate-write-next.json" \
  '.next_action.kind == "ask" and .next_action.reason == "validation-not-readonly"'

write_effort na-heavy awaiting-deploy <<'EOF'
- [x] PR opened - https://github.com/acme/widget/pull/10
- [x] Merged
- [ ] Post-deploy: run `dotnet test src/Foo.Tests` against alpha
- [ ] Deployed
EOF
next_action na-heavy live-code --delivery-pr-state MERGED
assert_jq "a heavy local suite in a post-deploy row is asked, never run" \
  "$TMPDIR_TEST/na-heavy-next.json" \
  '.next_action.kind == "ask" and .next_action.reason == "validation-heavy-not-run"'

tests=$((tests + 1))
if run_py <<'PY'
allowed = [
    "gh api -X GET repos/acme/widget/pulls/1",
    "gh api --method GET repos/acme/widget/commits/abc/status --jq .state",
    "gh pr view 5 --repo acme/widget --json state",
    "gh pr checks 5",
    "gh run list --repo acme/widget --limit 3",
    "gh release view v1.2.3",
    "az monitor log-analytics query -w ws --analytics-query 'T | where x > 1'",
    "az monitor app-insights query --app a --analytics-query 'requests | take 1'",
    "az monitor metrics list --resource r --metric Requests",
    "az monitor activity-log list --resource-group rg",
    "gh api repos/acme/widget/issues",
    "gh api repos/$OWNER/$REPO",
    "gh api repos/$OWNER/$REPO/pulls/1",
    "gh api -X GET repos/acme/widget/issues -f state=open",
    "gh api -XGET repos/acme/widget/issues",
    "gh api -XGET repos/o/r/pulls/1",
    "gh api -i -X GET repos/o/r/pulls/1",
    "git grep -n NewFlag origin/main",
    "git grep -o foo",
    "git grep -n -i -e NewFlag -- src",
    "git log --oneline -5",
    "git log -n 5 --format=%H --author=bob",
    "git --no-pager log -1",
    "git show --stat abc1234",
    "git -C /clones/widget show abc1234",
]
refused = [
    "gh api -X POST repos/acme/widget/issues",
    "gh api repos/acme/widget/issues -f title=x",
    "gh api -X GET graphql",
    "gh api -X GET /graphql",
    "gh api -X GET repos/o/graphql",
    "gh api -X GET -X POST repos/o/r/issues -f a=b",
    "gh api -X GET --method POST repos/o/r/issues",
    "gh api -X POST -X GET repos/o/r/issues",
    "gh api -XPOST repos/o/r/issues",
    "gh api repos/o/r/issues -if title=x",
    "gh api repos/o/r/issues/1 -iXPOST",
    "gh api -X GET repos/o/r/issues -ftitle=x",
    "gh api --method=POST repos/o/r/issues",
    "gh api -X GET repos/o/r -H 'X-HTTP-Method-Override: DELETE'",
    "gh pr view 5#;rm x",
    "gh pr view 5 #; rm x",
    "git grep -O'touch /tmp/pwn' foo",
    "git grep --open-files-in-pager=sh foo",
    "git grep --open-files-in-pager sh foo",
    "git grep -e foo -Osh",
    "git log --output=/tmp/x",
    "git show --output /tmp/x abc",
    "git log --ext-diff",
    "git status",
    "git --exec-path log",
    "git --config-env=a=B log",
    "git -c core.pager=evil show abc",
    "gh api -X GET repos/a/b --input body.json",
    "gh api $X",
    "gh api ${ENDPOINT}",
    "gh api -X $METHOD repos/o/r/issues",
    "gh pr view $N",
    "gh api $X/pulls/1",
    "gh pr merge 5",
    "gh pr view 5 --web",
    "gh run rerun 55",
    "gh pr view 5 && rm -rf x",
    "gh pr view 5; rm x",
    "gh pr view 5 | tee out",
    "gh pr view 5 > out.json",
    "gh pr view $(echo 5)",
    "az monitor log-analytics query -w ws && az group delete -n x",
    "az group delete -n x",
    "az monitor metrics alert delete -n x",
    "az monitor metrics alert delete query",
    "az monitor metrics query",
    "az monitor log-analytics workspace delete query",
    "gh pr view 1\nrm -rf x",
    "gh pr view 1\rrm -rf x",
    "gh pr view 1\tx",
    "git log --oneline\x00",
    "git push origin main",
    "kubectl get pods",
    "FOO=1 gh pr view 5",
    "gh 'pr view",
    "",
]
for command in allowed:
    assert module.is_read_only_command(command), command
for command in refused:
    assert not module.is_read_only_command(command), command
PY
then
  report 0 "read-only allowlist accepts reads and refuses every write shape"
else
  report 1 "read-only allowlist accepts reads and refuses every write shape"
fi

cat > "$TMPDIR_TEST/na-plan.md" <<'EOF'
---
status: in-progress
repo: acme/widget
---

## Lifecycle
- [x] Implementation started
- [x] PR opened - **PR1** - https://github.com/acme/widget/pull/10
- [x] Merged

### PR Plan
Target PR count: 4

| PR | Scope | Depends on | External blockers | Touches | fsd-ready |
|---|---|---|---|---|---|
| PR1 | add the cache | none | none | `src/cache/*` | yes |
| PR2 | wire the probe | PR1 | none | `src/health/*` | yes |
| PR3 | switch callers | PR2 | none | `src/api/*` | no - waits on PR2 |
| PR4 | rollout flag | none | waiting on team X | `src/flags/*` | no |
EOF
next_action na-plan live-safe --delivery-pr-state MERGED
assert_jq "advance proposes the one PR whose dependencies merged and has no blockers" \
  "$TMPDIR_TEST/na-plan-next.json" \
  '.next_action.kind == "advance" and .next_action.command == "/nase:fsd na-plan PR2" and
   .next_action.context == "1 PR(s) startable: PR2"'
grep -v '^- \[x\] Merged$' "$TMPDIR_TEST/na-plan.md" > "$TMPDIR_TEST/na-plan-open.md"
next_action na-plan-open live-open --delivery-pr-state OPEN
assert_jq "advance waits while the dependency PR is still open" \
  "$TMPDIR_TEST/na-plan-open-next.json" '.next_action.kind == "none"'

sed -e 's/^| PR2 | wire the probe | PR1 | none | `src\/health\/\*` | yes |$/| PR2 | wire the probe | PR1 | none | `src\/health\/*` | yes - stacks on PR1 |/' \
  "$TMPDIR_TEST/na-plan-open.md" > "$TMPDIR_TEST/na-plan-stacked.md"
next_action na-plan-stacked live-open --delivery-pr-state OPEN
assert_jq "advance starts a stacked PR while its parent is still open" \
  "$TMPDIR_TEST/na-plan-stacked-next.json" \
  '.next_action.kind == "advance" and .next_action.command == "/nase:fsd na-plan-stacked PR2" and
   (.next_action.evidence[0] | contains("stackable"))'
cp "$TMPDIR_TEST/na-plan-stacked.md" "$TMPDIR_TEST/na-plan-stacked-closed.md"
live_json live-closed CLOSED "$safe_files" success
cat > "$TMPDIR_TEST/na-plan-chain.md" <<'EOF'
---
status: in-progress
repo: acme/widget
---

## Lifecycle
- [x] Implementation started
- [x] PR opened - **PR1** - https://github.com/acme/widget/pull/10

### PR Plan

| PR | Scope | Depends on | External blockers | Touches | fsd-ready |
|---|---|---|---|---|---|
| PR1 | add the cache | none | none | `src/cache/*` | yes |
| PR2 | wire the probe | PR1 | none | `src/health/*` | yes - stacks on PR1 |
| PR3 | switch callers | PR1, PR2 | none | `src/api/*` | yes - stacks on PR2 |
EOF
next_action na-plan-chain live-open --delivery-pr-state OPEN
assert_jq "advance proposes the next PR of a chain while its parent is open" \
  "$TMPDIR_TEST/na-plan-chain-next.json" '.next_action.kind == "advance" and (.next_action.context | contains("PR2"))'
cat > "$TMPDIR_TEST/na-plan-diamond.md" <<'EOF'
---
status: in-progress
repo: acme/widget
---

## Lifecycle
- [x] Implementation started
- [x] PR opened - **PR1** - https://github.com/acme/widget/pull/10
- [x] PR opened - **PR2** - https://github.com/acme/widget/pull/11

### PR Plan

| PR | Scope | Depends on | External blockers | Touches | fsd-ready |
|---|---|---|---|---|---|
| PR1 | add the cache | none | none | `src/cache/*` | yes |
| PR2 | wire the probe | none | none | `src/health/*` | yes |
| PR3 | switch callers | PR1, PR2 | none | `src/api/*` | yes - stacks on PR2 |
EOF
jq '.live["acme/widget#11"] = .live["acme/widget#10"]' "$TMPDIR_TEST/live-open.json" > "$TMPDIR_TEST/live-open2.json"
next_action na-plan-diamond live-open2 --delivery-pr-state OPEN --delivery-pr-state OPEN
assert_jq "advance does not start a row that stacks on one open parent but needs an unrelated open PR" \
  "$TMPDIR_TEST/na-plan-diamond-next.json" '.next_action.reason == "no-startable-pr"'
sed -e 's/| yes - stacks on PR1 |/| yes - stacks on PR9 |/' "$TMPDIR_TEST/na-plan-stacked.md" > "$TMPDIR_TEST/na-plan-stacked-stray.md"
next_action na-plan-stacked-stray live-open --delivery-pr-state OPEN
assert_jq "advance ignores a stacks-on parent that is not one of the dependencies" \
  "$TMPDIR_TEST/na-plan-stacked-stray-next.json" '.next_action.kind == "none"'
sed -e 's/| yes - stacks on PR1 |/| yes \xe2\x80\x93 stacks on PR1 |/' "$TMPDIR_TEST/na-plan-stacked.md" > "$TMPDIR_TEST/na-plan-stacked-dash.md"
next_action na-plan-stacked-dash live-open --delivery-pr-state OPEN
assert_jq "advance reads an en-dash stacks-on cell" \
  "$TMPDIR_TEST/na-plan-stacked-dash-next.json" '.next_action.kind == "advance"'
next_action na-plan-stacked-closed live-closed --delivery-pr-state CLOSED
assert_jq "advance does not stack on a parent PR that was closed" \
  "$TMPDIR_TEST/na-plan-stacked-closed-next.json" '.next_action.kind == "none"'

cat > "$TMPDIR_TEST/na-plan-unattributed.md" <<'EOF'
---
status: in-progress
repo: acme/widget
---

## Lifecycle
- [x] PR opened - https://github.com/acme/widget/pull/10

### PR Plan

| PR | Scope | Depends on | External blockers | Touches | fsd-ready |
|---|---|---|---|---|---|
| PR1 | add the cache | none | none | `src/cache/*` | yes |
EOF
next_action na-plan-unattributed live-open --delivery-pr-state OPEN
assert_jq "advance never re-proposes a PR whose delivery row names no plan id" \
  "$TMPDIR_TEST/na-plan-unattributed-next.json" \
  '.next_action.kind == "none" and .next_action.reason == "plan-prs-unattributed"'

cat > "$TMPDIR_TEST/na-prose-plan.md" <<'EOF'
---
status: in-review
repo: acme/widget
---

## Lifecycle
- [x] PR opened - PR1 - https://github.com/acme/widget/pull/10

### PR Plan
1. PR1 - add the cache
2. PR2 - wire the probe, after PR1 merges
EOF
next_action na-prose-plan live-safe --delivery-pr-state MERGED
assert_jq "a prose plan without columns is not advanceable" \
  "$TMPDIR_TEST/na-prose-plan-next.json" '.next_action.kind == "none"'

cat > "$TMPDIR_TEST/na-planned.md" <<'EOF'
---
status: planned
repo: acme/widget
---

## Plan
- [ ] Do the thing
EOF
next_action na-planned live-safe
assert_jq "a planned effort with no PR proposes fsd for the whole effort" \
  "$TMPDIR_TEST/na-planned-next.json" \
  '.next_action.kind == "advance" and .next_action.command == "/nase:fsd na-planned"'
next_action na-planned live-safe --blocked-by-unresolved
assert_jq "a blocked planned effort proposes nothing" \
  "$TMPDIR_TEST/na-planned-next.json" '.next_action.kind == "none"'

cat > "$TMPDIR_TEST/na-ready.md" <<'EOF'
---
status: merge-ready
repo: acme/widget
---

## Lifecycle
- [x] PR opened - https://github.com/acme/widget/pull/10
EOF
next_action na-ready live-open --delivery-pr-state OPEN
assert_jq "merge-ready with an open PR proposes prep-merge on that PR" \
  "$TMPDIR_TEST/na-ready-next.json" \
  '.next_action.kind == "advance" and
   .next_action.command == "/nase:prep-merge https://github.com/acme/widget/pull/10"'

cat > "$TMPDIR_TEST/na-stalled.md" <<'EOF'
---
status: in-progress
repo: acme/widget
---

## Plan
- [ ] Start
EOF
touch -t 202001010000 "$TMPDIR_TEST/na-stalled.md"
next_action na-stalled live-safe
assert_jq "an effort with no PR and no change for 14+ days is stalled" \
  "$TMPDIR_TEST/na-stalled-next.json" \
  '.next_action.kind == "ask" and .next_action.reason == "stalled"'
touch "$TMPDIR_TEST/na-stalled.md"
next_action na-stalled live-safe
assert_jq "a recently touched effort with no PR is not stalled" \
  "$TMPDIR_TEST/na-stalled-next.json" '.next_action.kind == "none"'

tests=$((tests + 1))
if run_py <<'PY'
inside = [
    "tests/a.cs", "src/tests/a.cs", "src/__tests__/a.ts",
    "src/Foo.Tests/Bar.cs", "src/foo.test.ts", "src/a.spec.tsx", "src/a.test.cs",
    "src/a_test.spec.py", ".github/workflows/ci.yml", ".github/workflows/lint.yml",
    ".github/workflows/ci-linux.yml", ".github/workflows/test.yaml",
    ".github/workflows/test-unit.yaml", ".github/CODEOWNERS",
    ".github/ISSUE_TEMPLATE/bug.yml", ".github/pull_request_template.md",
    "docs/a.md",
    # Root-level markdown is decided in: a repo README or CHANGELOG ships nothing.
    "README.md", "CONTRIBUTING.md",
]
outside = [
    "src/app.cs", "src/contest/a.cs", "latest/a.cs", "mydocs/a.txt", "src/docs/a.txt",
    "package.json", ".githubx/a.yml", "src/a.test", "src/attest.ts",
    # Markdown outside the root and docs/ may be a runtime resource.
    "src/deep/NOTES.md", "packages/x/README.md",
    # `.test.`/`.spec.` only counts on source extensions.
    "appsettings.Test.json", "openapi.spec.yaml", "src/fixtures.test.json",
    # A workflow outside the CI allow-list can build, push or apply, whatever it is named.
    ".github/workflows/build-and-push.yml", ".github/workflows/terraform.yml",
    ".github/workflows/azure-webapps-node.yml", ".github/workflows/abcde.yml",
    ".github/workflows/citation.yml", ".github/scripts/deploy.sh",
    ".github/workflows/ci-terraform-apply.yml", ".github/workflows/ci-push-image.yml",
    ".github/workflows/pr-build-and-push.yaml", ".github/workflows/pr_checks.yml",
    # Synthetic probes ship; only markdown under docs/ is documentation.
    "e2e/login.ts", "docs/guide.txt", "docs/diagram.png",
]
denied = [
    ".claude/commands/nase/efforts.md", ".claude/settings.json", "CLAUDE.md",
    "packages/x/CLAUDE.md", "skills/review/SKILL.md", "src/SKILL.md",
    "docs/prompts/review.md", "src/prompt/system.txt", "tests/prompts/a.test.ts",
    "src/agents/planner.ts", "docs/skills/a.md", "src/commands/run.ts",
    "appsettings.json", "src/appsettings.Production.json", "tests/appsettings.Test.json",
    ".github/actions/setup/action.yml", ".github/workflows/deploy.yml",
    ".github/workflows/release-prod.yml", ".github/workflows/publish.yml",
    ".github/workflows/promote.yml", ".github/workflows/cd.yml",
    ".github/workflows/ci-cd.yml",
]
for path in inside:
    assert module.is_non_deployed_path(path), path
for path in outside + denied:
    assert not module.is_non_deployed_path(path), path
PY
then
  report 0 "non-deployed path set matches tests, CI and docs only"
else
  report 1 "non-deployed path set matches tests, CI and docs only"
fi

assert_jq "an ask carries how many distinct reasons block the close" \
  "$TMPDIR_TEST/na-code-next.json" '.next_action | has("blocking")'
next_action na-code live-code --delivery-pr-state MERGED
assert_jq "one blocking reason is counted as one" \
  "$TMPDIR_TEST/na-code-next.json" '.next_action.blocking == 1'
next_action na-heavy live-code --delivery-pr-state MERGED
assert_jq "several blocking reasons are counted" \
  "$TMPDIR_TEST/na-heavy-next.json" '.next_action.blocking >= 2'

cat > "$TMPDIR_TEST/na-validate-undeployed.md" <<'EOF'
---
status: awaiting-deploy
repo: acme/widget
---

## Lifecycle
- [x] PR opened - https://github.com/acme/widget/pull/10
- [x] Merged
- [ ] Deployed
- [ ] Post-deploy: confirm the state with `gh pr view 10 --repo acme/widget --json state`
EOF
next_action na-validate-undeployed live-code --delivery-pr-state MERGED
assert_jq "a read-only post-deploy row never runs before Deployed is ticked" \
  "$TMPDIR_TEST/na-validate-undeployed-next.json" \
  '.next_action.kind == "ask" and .next_action.reason == "deployed-needs-ring-evidence"'

cat > "$TMPDIR_TEST/na-validate-expect.md" <<'EOF'
---
status: awaiting-deploy
repo: acme/widget
---

## Lifecycle
- [x] PR opened - https://github.com/acme/widget/pull/10
- [x] Merged
- [x] Deployed to alpha
- [ ] Post-deploy: expects `"state":"MERGED"` from `gh pr view 10 --repo acme/widget --json state`
- [ ] Post-deploy: list runs with `gh run list --repo acme/widget --limit 1`
EOF
next_action na-validate-expect live-code --delivery-pr-state MERGED
assert_jq "a stated expectation travels with its row and is null otherwise" \
  "$TMPDIR_TEST/na-validate-expect-next.json" \
  '.next_action.kind == "validate" and .next_action.rows[0].expect == "\"state\":\"MERGED\""
   and .next_action.rows[1].expect == null'

write_effort na-deployed-checked awaiting-deploy <<'EOF'
- [x] PR opened - https://github.com/acme/widget/pull/10
- [x] Merged
- [x] Deployed to prod
- [ ] Post-deploy: run `dotnet test src/Foo.Tests` against prod
EOF
next_action na-deployed-checked live-safe --delivery-pr-state MERGED
assert_jq "a ticked Deployed row adds no ring-evidence failure to the blocking count" \
  "$TMPDIR_TEST/na-deployed-checked-next.json" \
  '.next_action.kind == "ask" and .next_action.reason == "validation-heavy-not-run" and
   .next_action.blocking == 1 and (.next_action.context | contains("Deployed") | not)'

plan_table_head='### PR Plan

| PR | Scope | Depends on | External blockers | Touches | fsd-ready |
|---|---|---|---|---|---|'
write_effort na-plan-close awaiting-deploy <<EOF
- [x] PR opened - **PR1** - https://github.com/acme/widget/pull/10
- [x] Merged
- [ ] Deployed (if applicable)

$plan_table_head
| PR1 | add the cache | none | none | \`src/cache/*\` | yes |
| PR2 | wire the probe | PR1 | none | \`src/health/*\` | yes |
EOF
next_action na-plan-close live-safe --delivery-pr-state MERGED
assert_jq "a startable plan row is proposed instead of closing the effort" \
  "$TMPDIR_TEST/na-plan-close-next.json" \
  '.next_action.kind == "advance" and .next_action.reason == "plan-row-startable"'
write_effort na-plan-blocked awaiting-deploy <<EOF
- [x] PR opened - **PR1** - https://github.com/acme/widget/pull/10
- [x] Merged
- [ ] Deployed (if applicable)

$plan_table_head
| PR1 | add the cache | none | none | \`src/cache/*\` | yes |
| PR2 | wire the probe | PR1 | waiting on team X | \`src/health/*\` | no |
EOF
next_action na-plan-blocked live-safe --delivery-pr-state MERGED
assert_jq "a plan row with no merged PR blocks the close" \
  "$TMPDIR_TEST/na-plan-blocked-next.json" \
  '.next_action.kind == "ask" and .next_action.reason == "plan-rows-pending" and
   (.next_action.context | contains("PR2"))'
write_effort na-plan-done awaiting-deploy <<EOF
- [x] PR opened - **PR1** - https://github.com/acme/widget/pull/10
- [x] PR opened - **PR2** - https://github.com/acme/widget/pull/11
- [x] Merged
- [ ] Deployed (if applicable)

$plan_table_head
| PR1 | add the cache | none | none | \`src/cache/*\` | yes |
| PR2 | wire the probe | PR1 | none | \`src/health/*\` | yes |
EOF
jq -n --argjson files "$safe_files" \
  '{live: {"acme/widget#10": {state: "MERGED", files: $files, files_truncated: false, merge_checks: "success"},
           "acme/widget#11": {state: "MERGED", files: $files, files_truncated: false, merge_checks: "success"}}}' \
  > "$TMPDIR_TEST/live-two.json"
next_action na-plan-done live-two --delivery-pr-state MERGED --delivery-pr-state MERGED
assert_jq "a plan whose rows are all merged still closes" \
  "$TMPDIR_TEST/na-plan-done-next.json" '.next_action.kind == "close"'

cat > "$TMPDIR_TEST/na-attrib.md" <<'EOF'
---
status: in-progress
repo: acme/widget
prs:
  - https://github.com/acme/widget/pull/10
---

## Lifecycle
- [x] PR opened: PR1 - https://github.com/acme/widget/pull/10

### PR Plan

| PR | Scope | Depends on | External blockers | Touches | fsd-ready |
|---|---|---|---|---|---|
| PR1 | add the cache | none | none | `src/cache/*` | yes |
| PR2 | wire the probe | PR1 | none | `src/health/*` | yes |
EOF
next_action na-attrib live-safe --delivery-pr-state MERGED
assert_jq "a PR cited bare in frontmatter and with its plan id in a row is attributed" \
  "$TMPDIR_TEST/na-attrib-next.json" \
  '.next_action.kind == "advance" and .next_action.command == "/nase:fsd na-attrib PR2"'

jq -n --argjson files "$safe_files" \
  '{live: {"acme/widget#10": {state: "MERGED"},
           "ACME/Widget#10": {state: "MERGED", files: $files, files_truncated: false, merge_checks: "success"}}}' \
  > "$TMPDIR_TEST/live-case-a.json"
jq -n --argjson files "$safe_files" \
  '{live: {"ACME/Widget#10": {state: "MERGED", files: $files, files_truncated: false, merge_checks: "success"},
           "acme/widget#10": {state: "MERGED"}}}' \
  > "$TMPDIR_TEST/live-case-b.json"
for casing in a b; do
  next_action na-close "live-case-$casing" --delivery-pr-state MERGED
  assert_jq "records differing only in key case merge, keeping the detail fields ($casing)" \
    "$TMPDIR_TEST/na-close-next.json" '.next_action.kind == "close"'
done

next_action na-close live-safe --delivery-pr-state OPEN
assert_jq "a flag state that disagrees with the sweep refuses instead of closing" \
  "$TMPDIR_TEST/na-close-next.json" \
  '.next_action.kind == "ask" and .next_action.reason == "delivery-state-unresolved" and
   (.next_action.context | contains("acme/widget#10"))'
next_action na-close live-safe --delivery-pr-state MERGED --delivery-pr-state MERGED
assert_jq "a flag count that does not match the delivery PRs refuses" \
  "$TMPDIR_TEST/na-close-next.json" '.next_action.reason == "delivery-state-unresolved"'

write_effort na-env-row awaiting-deploy <<'EOF'
- [x] PR opened - https://github.com/acme/widget/pull/10
- [x] Merged
- [x] Deployed to alpha
- [ ] Post-deploy: confirm with `GH_HOST=x gh api -X GET repos/acme/widget/pulls/10`
EOF
next_action na-env-row live-safe --delivery-pr-state MERGED
assert_jq "an env-prefixed post-deploy command is never auto-run" \
  "$TMPDIR_TEST/na-env-row-next.json" \
  '.next_action.kind == "ask" and .next_action.reason == "validation-not-readonly"'

na_close_text=$(cat "$TMPDIR_TEST/na-close.md")
printf '%s\n' "${na_close_text/repo: acme\/widget/repo: acme/widget
jira: PROJ-5}" > "$TMPDIR_TEST/na-jira.md"
next_action na-jira live-safe --delivery-pr-state MERGED
assert_jq "a tracked Jira issue with no live state fails closed" \
  "$TMPDIR_TEST/na-jira-next.json" \
  '.next_action.kind == "ask" and .next_action.reason == "delivery-state-unresolved"
   and (.next_action.context | contains("Jira"))'
next_action na-jira live-safe --delivery-pr-state MERGED --jira-state untracked
assert_jq "an explicit untracked state does not clear a tracked Jira issue" \
  "$TMPDIR_TEST/na-jira-next.json" '.next_action.reason == "delivery-state-unresolved"'
next_action na-jira live-safe --delivery-pr-state MERGED --jira-state "done"
assert_jq "a tracked Jira issue that is Done lets the effort close" \
  "$TMPDIR_TEST/na-jira-next.json" '.next_action.kind == "close"'
next_action na-jira live-safe --delivery-pr-state MERGED --jira-state not-done
assert_jq "a tracked Jira issue that is not Done blocks the close" \
  "$TMPDIR_TEST/na-jira-next.json" '.next_action.reason == "jira-not-done"'
python3 "$SCRIPT" --file "$TMPDIR_TEST/na-jira.md" --evaluate-transition --delivery-pr-state MERGED \
  > "$TMPDIR_TEST/na-jira-transition.json"
assert_jq "the transition itself keeps its untracked default" \
  "$TMPDIR_TEST/na-jira-transition.json" '.transition.reason == "already-awaiting-deploy"'

for label in "Deployed (optional)" "Deployed (n/a)"; do
  printf '%s\n' "${na_close_text/Deployed (if applicable)/$label}" > "$TMPDIR_TEST/na-deployed-ok.md"
  next_action na-deployed-ok live-safe --delivery-pr-state MERGED
  assert_jq "a bare Deployed row labelled \"$label\" can be auto-ticked" \
    "$TMPDIR_TEST/na-deployed-ok-next.json" '.next_action.kind == "close"'
done
for label in "Deployed (to alpha)" "Deployed (if applicable, but not on SC2)"; do
  printf '%s\n' "${na_close_text/Deployed (if applicable)/$label}" > "$TMPDIR_TEST/na-deployed-bad.md"
  next_action na-deployed-bad live-safe --delivery-pr-state MERGED
  assert_jq "a Deployed row labelled \"$label\" is never auto-ticked" \
    "$TMPDIR_TEST/na-deployed-bad-next.json" \
    '.next_action.reason == "deployed-needs-ring-evidence"'
done

printf '%s' '{"live": {"acme/widget#10": "oops", "acme/widget#11": [1]}}' > "$TMPDIR_TEST/live-bad-values.json"
printf '%s' '[1, 2]' > "$TMPDIR_TEST/live-bad-list.json"
printf '%s' '{"live": 5}' > "$TMPDIR_TEST/live-bad-live.json"
printf '%s' '{"live": {"acme/widget#10": {"state": "MERGED", "files": [1, 2], "merge_checks": "success"}}}' \
  > "$TMPDIR_TEST/live-bad-files.json"
for bad in live-bad-values live-bad-list live-bad-live; do
  next_action na-code "$bad" --delivery-pr-state MERGED
  assert_jq "a malformed live file ($bad) fails closed instead of crashing" \
    "$TMPDIR_TEST/na-code-next.json" '.next_action.reason == "delivery-state-unresolved"'
done
next_action na-code live-bad-files --delivery-pr-state MERGED
assert_jq "a file list of the wrong type is not proof" \
  "$TMPDIR_TEST/na-code-next.json" '.next_action.reason == "files-unverified"'

tests=$((tests + 1))
if run_py <<'PY'
classify = module.classify_validation_row
assert classify("verify with `git grep -n vitest src`")[0] == "run"
assert classify("verify with `gh pr view 5 --repo a/b`")[0] == "run"
assert classify("run `npx vitest run`")[0] == "heavy"
assert classify("run `FOO=1 dotnet test src/X`")[0] == "heavy"
assert classify("run `pnpm test`")[0] == "heavy"
assert classify("run `python3 -m pytest tests`")[0] == "heavy"
assert classify("run `bash tests/check-all.sh`")[0] == "heavy"
assert classify("run `GH_HOST=x gh api -X GET repos/o/r/pulls/1`")[0] == "not-readonly"
assert classify("run `GIT_DIR=x git log -1`") == ("not-readonly", "GIT_DIR=x git log -1")
assert not module.is_read_only_command("GH_HOST=x gh api -X GET repos/o/r/pulls/1")
assert classify("see `src/x.cs` and note")[0] == "none"
assert classify("run `gh pr merge 5`")[0] == "not-readonly"
assert classify("run `gh pr view 5` and `gh run list`")[0] == "not-readonly"
assert module.validation_expectation("expects `ok` back") == "ok"
assert module.validation_expectation("expected: `ok` back") == "ok"
assert module.validation_expectation("check `gh pr view 5`") is None
PY
then
  report 0 "validation rows classify by command head and carry their expectation"
else
  report 1 "validation rows classify by command head and carry their expectation"
fi

printf '\xff\xfe not utf-8' > "$TMPDIR_TEST/live-bad-utf8.json"
printf '{not json' > "$TMPDIR_TEST/live-bad-syntax.json"
for bad in live-bad-utf8 live-bad-syntax; do
  tests=$((tests + 1))
  rc=0
  python3 "$SCRIPT" --file "$TMPDIR_TEST/na-code.md" --evaluate-transition \
    --live-json "$TMPDIR_TEST/$bad.json" > /dev/null 2> "$TMPDIR_TEST/$bad.err" || rc=$?
  if [[ "$rc" -eq 2 ]] && grep -q '^ERROR: cannot read input' "$TMPDIR_TEST/$bad.err"; then
    report 0 "an unreadable --live-json ($bad) exits 2 with the documented error"
  else
    report 1 "an unreadable --live-json ($bad) exits 2 with the documented error" "exit $rc: $(cat "$TMPDIR_TEST/$bad.err")"
  fi
done
python3 "$SCRIPT" --file "$TMPDIR_TEST/na-code.md" --live-json "$TMPDIR_TEST/live-bad-utf8.json" \
  > "$TMPDIR_TEST/na-code-plain.json"
assert_jq "a corrupt --live-json does not break a plain classify" \
  "$TMPDIR_TEST/na-code-plain.json" '.stage == "awaiting_deploy" and (has("next_action") | not)'

tests=$((tests + 1))
if run_py <<'PY'
import re
from pathlib import Path

doc = Path(sys.argv[1]).parents[1] / "docs" / "effort-drift.md"
text = doc.read_text(encoding="utf-8")
section = text.split("\n## Next actions\n", 1)[1].split("\n## ", 1)[0]
line = next(l for l in section.splitlines() if l.startswith("**`ask` reason codes**"))
ask_codes = set(re.findall(r"`([a-z]+(?:-[a-z]+)+)`", line.split(". ", 1)[0]))
assert ask_codes, "no ask reason codes parsed"
reasons = module.NEXT_ACTION_REASONS
assert ask_codes <= reasons, sorted(ask_codes - reasons)
unnamed = {r for r in reasons if f"`{r}`" not in section}
assert not unnamed, sorted(unnamed)

import ast

tree = ast.parse(Path(sys.argv[1]).read_text(encoding="utf-8"))
emitting = {"advance_action", "close_gate", "ask_reason", "next_action"}


def literal(node):
    return node.value if isinstance(node, ast.Constant) and isinstance(node.value, str) else None


emitted = set()
for func in (n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name in emitting):
    for node in ast.walk(func):
        if isinstance(node, ast.Call):
            if getattr(node.func, "id", None) == "_action" and len(node.args) > 1:
                emitted.add(literal(node.args[1]))
            elif getattr(node.func, "attr", None) == "append" and node.args:
                first = node.args[0]
                if isinstance(first, ast.Tuple) and first.elts:
                    emitted.add(literal(first.elts[0]))
        elif isinstance(node, ast.Return) and isinstance(node.value, ast.Tuple):
            emitted.add(literal(node.value.elts[0]))
        elif isinstance(node, ast.Assign) and any(
            getattr(t, "id", None) == "reason" for t in node.targets
        ):
            emitted.add(literal(node.value))
emitted.discard(None)
assert len(emitted) > 20, sorted(emitted)
skill_only = {"validation-failed", "validation-inconclusive"}
assert emitted <= reasons, sorted(emitted - reasons)
assert reasons - emitted == skill_only, sorted(reasons - emitted)
PY
then
  report 0 "NEXT_ACTION_REASONS matches the reason codes effort-drift.md names"
else
  report 1 "NEXT_ACTION_REASONS matches the reason codes effort-drift.md names"
fi

printf '\n--- %d pass, %d fail ---\n' "$((tests - failures))" "$failures"
[ "$failures" -eq 0 ]
