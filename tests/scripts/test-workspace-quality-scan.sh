#!/usr/bin/env bash
# Regression tests for .claude/scripts/workspace-quality-scan.py.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/workspace-quality-scan.py"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

pass=0
fail=0

pass_msg() {
  pass=$((pass + 1))
  printf 'PASS  %s\n' "$1"
}

fail_msg() {
  fail=$((fail + 1))
  printf 'FAIL  %s\n' "$1" >&2
}

assert_jq() {
  local desc="$1"
  local json="$2"
  local expr="$3"
  if printf '%s' "$json" | jq -e "$expr" >/dev/null 2>&1; then
    pass_msg "$desc"
  else
    fail_msg "$desc"
    printf '%s\n' "$json" >&2
  fi
}

mkdir -p \
  "$FIXTURE/.claude/docs" \
  "$FIXTURE/workspace/efforts/archive/2031" \
  "$FIXTURE/workspace/efforts/done" \
  "$FIXTURE/workspace/kb/projects" \
  "$FIXTURE/workspace/logs" \
  "$FIXTURE/workspace/stats" \
  "$FIXTURE/workspace/tasks" \
  "$FIXTURE/workspace/tmp"

cat > "$FIXTURE/.claude/docs/effort-lifecycle.md" <<'EOF'
## Status Vocabulary

**Active**

| status | meaning |
|---|---|
| `planned` | queued |
| `in-progress` | underway |

**Done**

| status | meaning |
|---|---|
| `completed` | shipped |
| `wontfix` | closed |

## Scope Vocabulary

| scope | meaning |
|---|---|
| `quick-fix` | one PR |
| `feature` | own design |

## Next section
EOF

cat > "$FIXTURE/workspace/logs/2026-06-01.md" <<'EOF'
# Work Log — 2026-06-01

## Sessions
- 09:00 | fsd: implemented scanner
EOF

cat > "$FIXTURE/workspace/logs/2026-06-02.md" <<'EOF'
# Notes

- 10:00 [fsd] this is not canonical
EOF

cat > "$FIXTURE/workspace/logs/2026-06-02-sre-tracker.md" <<'EOF'
# SRE Incident Tracker — 2026-06-02

## Active Incidents
- **SRE-1**: tracker schema should be ignored by daily-log checks
EOF

cat > "$FIXTURE/workspace/kb/projects/example.md" <<'EOF'
# Example

## Azure Pipelines
| File | definitionId |
|---|---|
| `azure-pipelines.yml` | FILL_IN |

### 2026-06-01 — refresh
- No new commits since the last scan; HEAD remains abc1234.
EOF

cat > "$FIXTURE/workspace/kb/projects/substantive.md" <<'EOF'
# Substantive constraints

- The public JSON wire format is unchanged, so existing clients remain compatible.
- Retry code `3` means the operation already succeeded; no action needed by the operator.
EOF

cat > "$FIXTURE/workspace/stats/kb-usage.jsonl" <<'EOF'
{"ts":"2026-06-01T00:00:00Z","skill":"unknown","file":"workspace/kb/projects/example.md","access":"read","source":"read-hook","session":"s1"}
{"ts":"2026-06-01T00:01:00Z","skill":"fsd","file":"workspace/kb/projects/example.md","access":"read","source":"read-hook","session":"s1"}
EOF

cat > "$FIXTURE/workspace/efforts/invalid-status.md" <<'EOF'
---
status: in-review
---

# Invalid active status
EOF

cat > "$FIXTURE/workspace/efforts/done/active-status.md" <<'EOF'
---
status: in-progress
---

# Invalid done status
EOF

cat > "$FIXTURE/workspace/efforts/done/tracking-only.md" <<'EOF'
---
status: completed
tracking_only: true
---

# Wrong terminal destination
EOF

cat > "$FIXTURE/workspace/efforts/archive/2031/invalid-status.md" <<'EOF'
---
status: proposed
---

# Invalid archived status
EOF

cat > "$FIXTURE/workspace/efforts/invalid-scope.md" <<'EOF'
---
status: planned
scope: bugfix
---

# Scope names a change kind, not a size
EOF

cat > "$FIXTURE/workspace/efforts/valid-scope.md" <<'EOF'
---
status: planned
scope: quick-fix
---

# Canonical scope
EOF

cat > "$FIXTURE/workspace/efforts/archive/2031/invalid-tracking-only.md" <<'EOF'
---
status: completed
tracking_only: "true # literal string"
---

# Invalid tracking-only scalar
EOF

cat > "$FIXTURE/workspace/efforts/archive/2031/empty-tracking-only.md" <<'EOF'
---
status: completed
tracking_only:
---

# Empty tracking-only scalar
EOF

cat > "$FIXTURE/workspace/efforts/archive/2031/duplicate-tracking-only.md" <<'EOF'
---
status: completed
tracking_only: false
tracking_only: true
---

# Duplicate tracking-only scalar
EOF

cat > "$FIXTURE/workspace/tasks/todo.md" <<'EOF'
# Open work only

- [x] Closed item must leave the open queue -> `workspace/efforts/missing.md`
EOF

printf 'recoverable state\n' > "$FIXTURE/workspace/tmp/old-state.json"
touch -t 202501010000 "$FIXTURE/workspace/tmp/old-state.json"

# Aged but cited by a durable workspace document: evidence, not loose state.
printf 'measurement evidence\n' > "$FIXTURE/workspace/tmp/cited-evidence.md"
touch -t 202501010000 "$FIXTURE/workspace/tmp/cited-evidence.md"
cat > "$FIXTURE/workspace/efforts/cites-tmp.md" <<'EOF'
---
status: in-progress
---

# Cites a scratch file

Baseline measured in `workspace/tmp/cited-evidence.md`.
EOF

json=$(python3 "$SCRIPT" --root "$FIXTURE" --days 999999 --json 2>&1)
rc=$?
if [ "$rc" = 0 ]; then
  pass_msg "scan exits 0 in warn mode"
else
  fail_msg "scan exits 0 in warn mode (rc=$rc)"
  printf '%s\n' "$json" >&2
fi

assert_jq "good daily log is not reported" "$json" \
  '[.findings[] | select(.path == "workspace/logs/2026-06-01.md")] | length == 0'
assert_jq "noncanonical daily log is reported" "$json" \
  'any(.findings[]; .category == "daily_log_missing_header" and .path == "workspace/logs/2026-06-02.md") and any(.findings[]; .category == "daily_log_missing_sessions" and .path == "workspace/logs/2026-06-02.md")'
assert_jq "sre tracker is ignored" "$json" \
  '[.findings[] | select(.path | contains("sre-tracker"))] | length == 0'
assert_jq "kb placeholder and refresh heartbeat are reported" "$json" \
  'any(.findings[]; .category == "kb_placeholder") and any(.findings[]; .category == "kb_refresh_block") and any(.findings[]; .category == "kb_heartbeat")'
assert_jq "substantive unchanged and no-action constraints are not heartbeats" "$json" \
  '[.findings[] | select(.path == "workspace/kb/projects/substantive.md")] | length == 0'
assert_jq "high unknown kb usage rate is reported" "$json" \
  'any(.findings[]; .category == "kb_usage_unknown_rate")'
assert_jq "invalid effort statuses and location mismatches are reported" "$json" \
  'any(.findings[]; .category == "effort_invalid_status" and .path == "workspace/efforts/invalid-status.md") and any(.findings[]; .category == "effort_status_location_mismatch" and .path == "workspace/efforts/done/active-status.md") and any(.findings[]; .category == "effort_invalid_status" and .path == "workspace/efforts/archive/2031/invalid-status.md")'
assert_jq "invalid effort scopes are reported and canonical ones are not" "$json" \
  'any(.findings[]; .category == "effort_invalid_scope" and .path == "workspace/efforts/invalid-scope.md") and ([.findings[] | select(.category == "effort_invalid_scope" and .path == "workspace/efforts/valid-scope.md")] | length == 0)'
assert_jq "efforts with no scope are reported" "$json" \
  'any(.findings[]; .category == "effort_missing_scope" and .path == "workspace/efforts/invalid-status.md")'
assert_jq "tracking-only efforts in done are reported" "$json" \
  'any(.findings[]; .category == "effort_tracking_only_destination_mismatch" and .path == "workspace/efforts/done/tracking-only.md")'
assert_jq "non-contract tracking-only scalars are reported" "$json" \
  'any(.findings[]; .category == "effort_invalid_tracking_only" and .path == "workspace/efforts/archive/2031/invalid-tracking-only.md") and any(.findings[]; .category == "effort_invalid_tracking_only" and .path == "workspace/efforts/archive/2031/empty-tracking-only.md") and any(.findings[]; .category == "effort_invalid_tracking_only" and .path == "workspace/efforts/archive/2031/duplicate-tracking-only.md")'
assert_jq "closed todo items and broken effort references are reported" "$json" \
  'any(.findings[]; .category == "todo_closed_item") and any(.findings[]; .category == "todo_broken_effort_ref")'
assert_jq "stale tmp inventory is reported without deleting it" "$json" \
  'any(.findings[]; .category == "tmp_stale_inventory") and (.summary.tmp.stale_files == 2)'
assert_jq "a cited stale tmp file is not counted as loose state" "$json" \
  '(.summary.tmp.stale_uncited_files == 1) and (.summary.tmp.stale_uncited_bytes < .summary.tmp.stale_bytes)'

window="$FIXTURE/window"
mkdir -p "$window/workspace/logs" "$window/workspace/kb/projects" "$window/workspace/stats"
cat > "$window/workspace/stats/kb-usage.jsonl" <<'EOF'
{"ts":"1970-01-01T00:00:00Z","skill":"unknown","file":"workspace/kb/projects/old.md","access":"read","source":"read-hook","session":"old"}
EOF
window_out=$(python3 "$SCRIPT" --root "$window" --days 1 --json 2>&1)
assert_jq "old kb usage does not affect current window" "$window_out" \
  '(.summary.kb_usage.events == 0) and ([.findings[] | select(.category == "kb_usage_unknown_rate")] | length == 0)'

malformed="$FIXTURE/malformed"
mkdir -p "$malformed/workspace/stats"
cat > "$malformed/workspace/stats/kb-usage.jsonl" <<'EOF'
{"ts":"2026-06-01T00:00:00Z","skill":"fsd"}

not-json
["not", "an", "event"]
EOF
{
  printf '1'
  for ((i = 0; i < 5000; i++)); do
    printf '0'
  done
  printf '\n'
  for ((i = 0; i < 1100; i++)); do
    printf '['
  done
  printf '0'
  for ((i = 0; i < 1100; i++)); do
    printf ']'
  done
  printf '\n'
} >> "$malformed/workspace/stats/kb-usage.jsonl"
printf '%s\n' '{"ts":"2026-06-01T00:00:00Z","skill":NaN}' \
  >> "$malformed/workspace/stats/kb-usage.jsonl"
printf '{"ts":"2026-06-01T00:00:00Z","skill":"bad\377"}\n' \
  >> "$malformed/workspace/stats/kb-usage.jsonl"
cp "$malformed/workspace/stats/kb-usage.jsonl" "$malformed/ledger.before"

malformed_warn_out=$(python3 "$SCRIPT" --root "$malformed" --days 999999 --json 2>&1)
malformed_warn_rc=$?
if [ "$malformed_warn_rc" = 0 ]; then
  pass_msg "malformed kb usage keeps warn mode successful"
else
  fail_msg "malformed kb usage keeps warn mode successful (rc=$malformed_warn_rc)"
  printf '%s\n' "$malformed_warn_out" >&2
fi
assert_jq "malformed kb usage is aggregated into one finding" "$malformed_warn_out" \
  '(.summary.kb_usage.events == 1) and (.summary.kb_usage.malformed == 6) and ([.findings[] | select(.category == "kb_usage_malformed" and .path == "workspace/stats/kb-usage.jsonl" and (.message | contains("6 malformed")))] | length == 1)'

malformed_strict_out=$(python3 "$SCRIPT" --root "$malformed" --days 999999 --strict --json 2>&1)
malformed_strict_rc=$?
if [ "$malformed_strict_rc" = 1 ]; then
  pass_msg "strict mode rejects malformed-only kb usage"
else
  fail_msg "strict mode rejects malformed-only kb usage (rc=$malformed_strict_rc)"
  printf '%s\n' "$malformed_strict_out" >&2
fi
assert_jq "strict malformed output stays parseable and precise" "$malformed_strict_out" \
  '(.summary.kb_usage.malformed == 6) and ([.findings[] | select(.category == "kb_usage_malformed" and .path == "workspace/stats/kb-usage.jsonl")] | length == 1)'

if cmp -s "$malformed/ledger.before" "$malformed/workspace/stats/kb-usage.jsonl"; then
  pass_msg "kb usage scan does not modify malformed input"
else
  fail_msg "kb usage scan does not modify malformed input"
fi

blank="$FIXTURE/blank"
mkdir -p "$blank/workspace/stats"
printf '\n  \n' > "$blank/workspace/stats/kb-usage.jsonl"
blank_out=$(python3 "$SCRIPT" --root "$blank" --days 999999 --strict --json 2>&1)
blank_rc=$?
if [ "$blank_rc" = 0 ]; then
  pass_msg "blank-only kb usage stays clean in strict mode"
else
  fail_msg "blank-only kb usage stays clean in strict mode (rc=$blank_rc)"
  printf '%s\n' "$blank_out" >&2
fi
assert_jq "blank kb usage records are not malformed" "$blank_out" \
  '(.summary.kb_usage.malformed == 0) and ([.findings[] | select(.category == "kb_usage_malformed")] | length == 0)'

strict_out=$(python3 "$SCRIPT" --root "$FIXTURE" --days 999999 --strict 2>&1)
strict_rc=$?
if [ "$strict_rc" != 0 ]; then
  pass_msg "strict mode exits nonzero when findings exist"
else
  fail_msg "strict mode exits nonzero when findings exist"
  printf '%s\n' "$strict_out" >&2
fi

clean="$FIXTURE/clean"
mkdir -p "$clean/workspace/logs" "$clean/workspace/kb/projects" "$clean/workspace/stats"
cat > "$clean/workspace/logs/2026-06-01.md" <<'EOF'
# Work Log — 2026-06-01

## Sessions
- 09:00 | review: clean log
EOF
cat > "$clean/workspace/kb/projects/clean.md" <<'EOF'
# Clean

## Overview
- Durable fact.
EOF
clean_out=$(python3 "$SCRIPT" --root "$clean" --days 999999 --strict --json 2>&1)
clean_rc=$?
if [ "$clean_rc" = 0 ]; then
  pass_msg "strict mode exits 0 when no findings exist"
else
  fail_msg "strict mode exits 0 when no findings exist"
  printf '%s\n' "$clean_out" >&2
fi
assert_jq "clean fixture has zero findings" "$clean_out" \
  '(.summary.total == 0) and (.summary.kb_usage.malformed == 0)'

total=$((pass + fail))
printf '\n%d/%d assertions passed\n' "$pass" "$total"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
