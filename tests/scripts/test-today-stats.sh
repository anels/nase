#!/usr/bin/env bash
# Regression tests for .claude/scripts/today-stats.py

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/today-stats.py"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/workspace/stats"
cat > "$tmp/workspace/stats/skill-usage.jsonl" <<'JSONL'
{"skill":"help","ts":"2026-06-01T00:00:00Z","status":"success","source":"prompt"}
{"skill":"help","ts":"2026-06-01T00:00:05Z","status":"success","duration_ms":3}
{"skill":"reflect","ts":"2026-06-01T00:01:00Z","status":"success","source":"prompt"}
{"skill":"reflect","ts":"2026-06-01T00:02:05Z","status":"success","duration_ms":4}
{"skill":"today","ts":"2026-06-01T00:03:00Z","status":"success"}
{"skill":"new","ts":"2026-06-01T00:04:00Z","event_type":"requested","source":"prompt","session_id":"s1"}
{"skill":"new","ts":"2026-06-01T00:04:01Z","event_type":"activated","source":"prompt-expansion","session_id":"s1"}
{"skill":"new","ts":"2026-06-01T00:04:02Z","event_type":"tool_succeeded","source":"skill-hook","session_id":"s1"}
{"skill":"failed","ts":"2026-06-01T00:04:03Z","event_type":"tool_failed","source":"skill-hook","session_id":"s2"}
{"skill":"old","ts":"2026-05-31T23:59:59Z","status":"success"}
JSONL

out=$(python3 "$SCRIPT" --root "$tmp" --date 2026-06-01)

assert_line() {
  local needle="$1"
  if ! grep -qxF "$needle" <<< "$out"; then
    printf 'FAIL: missing line: %s\nOutput:\n%s\n' "$needle" "$out" >&2
    exit 1
  fi
}

assert_line "total_invocations=5"
assert_line "unique_skills=4"
assert_line "skill help 1"
assert_line "skill new 1"
assert_line "skill reflect 2"
assert_line "skill today 1"

printf 'today-stats regression tests passed.\n'
