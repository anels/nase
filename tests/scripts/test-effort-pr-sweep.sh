#!/usr/bin/env bash
# Regression tests for .claude/scripts/effort-pr-sweep.py.
#
# The sweep's whole job is to catch delivery PRs that `effort-state.py` cannot see because
# the lifecycle row carries a non-canonical label. These tests run offline (--no-live), so
# they cover the label audit and the exclusion hints, not the gh reads.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/effort-pr-sweep.py"
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

sweep() {
  python3 "$SCRIPT" --efforts-dir "$TMPDIR_TEST/efforts" --no-live --format json \
    > "$TMPDIR_TEST/out.json"
}

mkdir -p "$TMPDIR_TEST/efforts"

# A canonical `PR opened` row plus three non-canonical rows citing real PRs. Only the
# canonical one reaches the delivery set; the other three are what this script exists to find.
cat > "$TMPDIR_TEST/efforts/multi-pr.md" <<'EOF'
---
status: in-progress
created: 2026-08-01
scope: feature
repo: platform
---

## Effort: multi-PR delivery with mixed row labels

### Lifecycle

- [x] Implementation started — 2026-08-01
- [x] PR opened — https://github.com/acme/platform/pull/1001 (draft, PR-1)
- [x] PR2 opened — https://github.com/acme/platform/pull/1002 (draft)
- [x] PR-3b (`platform-monitoring`, Steps 4-5) — https://github.com/acme/platform-monitoring/pull/2003
- [x] W8 PR opened — https://github.com/acme/platform/pull/1004
- [ ] Deployed (if applicable)
EOF

# Every non-canonical row here cites a PR the delivery set should NOT carry. A caller that
# bulk-relabels these would fire a transition on a cherry-pick and a withdrawn PR.
cat > "$TMPDIR_TEST/efforts/correctly-excluded.md" <<'EOF'
---
status: awaiting-deploy
created: 2026-08-01
scope: feature
repo: platform
---

## Effort: rows that cite PRs which are not this effort's delivery

### Lifecycle

- [x] PR opened — https://github.com/acme/platform/pull/2001 (draft)
- [x] Merged — 2026-08-05 (#2001)
- [x] Cherry-picked to release lines — 🍒 https://github.com/acme/platform/pull/2002
- [x] PR-2 withdrawn — https://github.com/acme/platform/pull/2003 closed without merging
- [x] Spike B code implemented + PR merged — https://github.com/acme/platform/pull/2004
- [x] Step 0 — sibling's PR merged, prerequisite for PR 1 — https://github.com/acme/platform/pull/2005
- [x] Phase 2 — pattern adoption complete — https://github.com/acme/platform/pull/2006
- [x] Follow-up — deploy-window test — https://github.com/acme/platform/pull/2007
- [ ] Deployed (if applicable)
EOF

# Effort prose is full of `owner/repo#n` lookalikes. They must not surface as phantom PRs.
cat > "$TMPDIR_TEST/efforts/prose-lookalikes.md" <<'EOF'
---
status: in-progress
created: 2026-08-01
scope: feature
repo: platform
---

## Effort: prose that looks like a qualified PR reference

### Lifecycle

- [x] PR opened — https://github.com/acme/platform/pull/3001 (draft)
- [x] Review-mode pass — 2026-07-11 (grill round 2/SC#5 and C3/SC#5 both re-grounded)
- [ ] Deployed (if applicable)
EOF

sweep

# --- multi-pr: the three non-canonical rows are found, the canonical one is not flagged
assert_jq "multi-pr: delivery set carries only the canonical row" "$TMPDIR_TEST/out.json" \
  '[.efforts[] | select(.effort == "multi-pr")][0].delivery == [1001]'
assert_jq "multi-pr: all three non-canonical PRs reported invisible" "$TMPDIR_TEST/out.json" \
  '[.efforts[] | select(.effort == "multi-pr")][0].invisible | length == 3'
assert_jq "multi-pr: PR2-opened row hinted likely-delivery" "$TMPDIR_TEST/out.json" \
  '[.efforts[] | select(.effort == "multi-pr")][0].invisible
   | map(select(.pr == "acme/platform#1002"))[0].hint == "likely-delivery"'
assert_jq "multi-pr: W8-prefixed PR opened row is still caught" "$TMPDIR_TEST/out.json" \
  '[.efforts[] | select(.effort == "multi-pr")][0].invisible
   | map(select(.pr == "acme/platform#1004")) | length == 1'
assert_jq "multi-pr: cross-repo PR-3b row is caught" "$TMPDIR_TEST/out.json" \
  '[.efforts[] | select(.effort == "multi-pr")][0].invisible
   | map(select(.pr == "acme/platform-monitoring#2003")) | length == 1'

# --- correctly-excluded: every row gets a hint that is NOT likely-delivery
assert_jq "excluded: cherry-pick hinted" "$TMPDIR_TEST/out.json" \
  '[.efforts[] | select(.effort == "correctly-excluded")][0].invisible
   | map(select(.pr == "acme/platform#2002"))[0].hint == "likely-cherry-pick"'
assert_jq "excluded: withdrawn hinted" "$TMPDIR_TEST/out.json" \
  '[.efforts[] | select(.effort == "correctly-excluded")][0].invisible
   | map(select(.pr == "acme/platform#2003"))[0].hint == "likely-withdrawn"'
assert_jq "excluded: spike hinted" "$TMPDIR_TEST/out.json" \
  '[.efforts[] | select(.effort == "correctly-excluded")][0].invisible
   | map(select(.pr == "acme/platform#2004"))[0].hint == "likely-spike"'
assert_jq "excluded: sibling dependency hinted" "$TMPDIR_TEST/out.json" \
  '[.efforts[] | select(.effort == "correctly-excluded")][0].invisible
   | map(select(.pr == "acme/platform#2005"))[0].hint == "likely-sibling-dependency"'
assert_jq "excluded: phase summary hinted" "$TMPDIR_TEST/out.json" \
  '[.efforts[] | select(.effort == "correctly-excluded")][0].invisible
   | map(select(.pr == "acme/platform#2006"))[0].hint == "likely-phase-summary"'
assert_jq "excluded: follow-up hinted" "$TMPDIR_TEST/out.json" \
  '[.efforts[] | select(.effort == "correctly-excluded")][0].invisible
   | map(select(.pr == "acme/platform#2007"))[0].hint == "likely-follow-up"'
assert_jq "excluded: no row is misread as likely-delivery" "$TMPDIR_TEST/out.json" \
  '[.efforts[] | select(.effort == "correctly-excluded")][0].invisible
   | map(select(.hint == "likely-delivery")) | length == 0'

# --- prose-lookalikes: `2/SC#5` and `C3/SC#5` must not become phantom PRs
assert_jq "prose: no phantom PR from owner/repo#n lookalikes" "$TMPDIR_TEST/out.json" \
  '[.efforts[] | select(.effort == "prose-lookalikes")][0].invisible | length == 0'

# Sibling repos reuse PR numbers. A number-only membership test would read the monitoring
# PR as already delivered because the main repo happens to have the same number.
cat > "$TMPDIR_TEST/efforts/same-number-sibling-repo.md" <<'EOF'
---
status: in-progress
created: 2026-08-01
scope: feature
repo: platform
---

## Effort: sibling repo reuses the delivery PR number

### Lifecycle

- [x] PR opened — https://github.com/acme/platform/pull/5001 (draft)
- [x] PR-2 (monitoring side) — https://github.com/acme/platform-monitoring/pull/5001
- [ ] Deployed (if applicable)
EOF

sweep
assert_jq "sibling repo with the same PR number is still invisible" "$TMPDIR_TEST/out.json" \
  '[.efforts[] | select(.effort == "same-number-sibling-repo")][0].invisible
   | map(select(.pr == "acme/platform-monitoring#5001")) | length == 1'

# --- an unchecked row citing a PR is not a delivery claim and must not be flagged
cat > "$TMPDIR_TEST/efforts/planned-row.md" <<'EOF'
---
status: in-progress
created: 2026-08-01
scope: feature
repo: platform
---

## Effort: a planned PR that has not been opened

### Lifecycle

- [x] PR opened — https://github.com/acme/platform/pull/4001 (draft)
- [ ] PR-2 — will land in https://github.com/acme/platform/pull/4002 once PR-1 deploys
EOF

sweep
assert_jq "unchecked row citing a PR is not flagged" "$TMPDIR_TEST/out.json" \
  '[.efforts[] | select(.effort == "planned-row")][0].invisible | length == 0'

# The failing/pending name lists are capped for display, so the rendered count has
# to come from a separate total. A PR with more failing checks than the cap must
# not report the cap as its count.
tests=$((tests + 1))
if python3 - "$SCRIPT" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("sweep", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

payload = {
    "state": "OPEN",
    "statusCheckRollup": [
        {"name": f"check-{index}", "conclusion": "FAILURE"} for index in range(14)
    ]
    + [{"name": f"queued-{index}", "status": "QUEUED"} for index in range(9)],
}
state = module.classify_state(payload)
assert len(state["failing"]) == 6, state["failing"]
assert state["failingCount"] == 14, state["failingCount"]
assert len(state["pending"]) == 6, state["pending"]
assert state["pendingCount"] == 9, state["pendingCount"]
PY
then
  report 0 "capped check lists carry their true totals"
else
  report 1 "capped check lists carry their true totals"
fi

printf '\n%d assertions, %d failures\n' "$tests" "$failures"
[[ "$failures" -eq 0 ]]
