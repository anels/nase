#!/usr/bin/env bash
# Regression tests for .claude/scripts/effort-state.py.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/effort-state.py"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

failures=0

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

printf '\n--- %d pass, %d fail ---\n' "$((5 - failures))" "$failures"
[ "$failures" -eq 0 ]
