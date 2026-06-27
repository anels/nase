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

mkdir -p "$FIXTURE/workspace/logs" "$FIXTURE/workspace/kb/projects" "$FIXTURE/workspace/stats"

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

cat > "$FIXTURE/workspace/stats/kb-usage.jsonl" <<'EOF'
{"ts":"2026-06-01T00:00:00Z","skill":"unknown","file":"workspace/kb/projects/example.md","access":"read","source":"read-hook","session":"s1"}
{"ts":"2026-06-01T00:01:00Z","skill":"fsd","file":"workspace/kb/projects/example.md","access":"read","source":"read-hook","session":"s1"}
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
assert_jq "high unknown kb usage rate is reported" "$json" \
  'any(.findings[]; .category == "kb_usage_unknown_rate")'

window="$FIXTURE/window"
mkdir -p "$window/workspace/logs" "$window/workspace/kb/projects" "$window/workspace/stats"
cat > "$window/workspace/stats/kb-usage.jsonl" <<'EOF'
{"ts":"1970-01-01T00:00:00Z","skill":"unknown","file":"workspace/kb/projects/old.md","access":"read","source":"read-hook","session":"old"}
EOF
window_out=$(python3 "$SCRIPT" --root "$window" --days 1 --json 2>&1)
assert_jq "old kb usage does not affect current window" "$window_out" \
  '(.summary.kb_usage.events == 0) and ([.findings[] | select(.category == "kb_usage_unknown_rate")] | length == 0)'

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
assert_jq "clean fixture has zero findings" "$clean_out" '.summary.total == 0'

total=$((pass + fail))
printf '\n%d/%d assertions passed\n' "$pass" "$total"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
