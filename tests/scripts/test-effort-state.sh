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
- [x] PR opened - UiPath/Widgets#42
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
  '.transition == {"action":"move","reason":"deployed","status":"completed"}'

transition frontmatter --delivery-pr-state CLOSED --delivery-pr-state CLOSED --jira-state not-done
assert_jq "all closed delivery PRs move to wontfix" "$TMPDIR_TEST/frontmatter-transition.json" \
  '.transition == {"action":"move","reason":"all-delivery-prs-closed","status":"wontfix"}'

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
  '.transition == {"action":"move","reason":"deployed","status":"completed"}'

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

printf '\n--- %d pass, %d fail ---\n' "$((tests - failures))" "$failures"
[ "$failures" -eq 0 ]
