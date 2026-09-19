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

# Every stamp in the fixture is UTC and --date is a local calendar day, so each run
# pins TZ: unpinned, the same fixture answers differently per machine.
out=$(TZ=UTC python3 "$SCRIPT" --root "$tmp" --date 2026-06-01)

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

# An evening local session carries the next UTC date. It belongs to the local day it
# was worked, not to the UTC day its stamp names.
cat > "$tmp/workspace/stats/skill-usage.jsonl" <<'JSONL'
{"skill":"recap","ts":"2026-06-02T04:12:14Z","status":"success","source":"prompt"}
{"skill":"wrap-up","ts":"2026-06-02T08:00:00Z","status":"success","source":"prompt"}
JSONL

out=$(TZ=America/Los_Angeles python3 "$SCRIPT" --root "$tmp" --date 2026-06-01)
assert_line "total_invocations=1"
assert_line "skill recap 1"

out=$(TZ=America/Los_Angeles python3 "$SCRIPT" --root "$tmp" --date 2026-06-02)
assert_line "total_invocations=1"
assert_line "skill wrap-up 1"

# A spring-forward local day is 23 hours long, so the window closes at the next local
# midnight. A fixed 24-hour delta would reach into the following day.
cat > "$tmp/workspace/stats/skill-usage.jsonl" <<'JSONL'
{"skill":"standup","ts":"2026-03-08T18:00:00Z","status":"success","source":"prompt"}
{"skill":"recap","ts":"2026-03-09T07:30:00Z","status":"success","source":"prompt"}
JSONL

out=$(TZ=America/Los_Angeles python3 "$SCRIPT" --root "$tmp" --date 2026-03-08)
assert_line "total_invocations=1"
assert_line "skill standup 1"

out=$(TZ=America/Los_Angeles python3 "$SCRIPT" --root "$tmp" --date 2026-03-09)
assert_line "total_invocations=1"
assert_line "skill recap 1"

# /nase:stats reads a range, so both ends are inclusive and the window spans the days
# between them. A missing --since keeps the one-day window /nase:wrap-up expects.
cat > "$tmp/workspace/stats/skill-usage.jsonl" <<'JSONL'
{"skill":"before","ts":"2026-06-01T12:00:00Z","status":"success","source":"prompt"}
{"skill":"first","ts":"2026-06-02T12:00:00Z","status":"success","source":"prompt"}
{"skill":"middle","ts":"2026-06-03T12:00:00Z","status":"success","source":"prompt"}
{"skill":"last","ts":"2026-06-04T12:00:00Z","status":"success","source":"prompt"}
{"skill":"after","ts":"2026-06-05T12:00:00Z","status":"success","source":"prompt"}
JSONL

out=$(TZ=UTC python3 "$SCRIPT" --root "$tmp" --since 2026-06-02 --date 2026-06-04)
assert_line "total_invocations=3"
assert_line "unique_skills=3"
assert_line "skill first 1"
assert_line "skill middle 1"
assert_line "skill last 1"

out=$(TZ=UTC python3 "$SCRIPT" --root "$tmp" --date 2026-06-03)
assert_line "total_invocations=1"
assert_line "skill middle 1"

if TZ=UTC python3 "$SCRIPT" --root "$tmp" --since 2026-06-04 --date 2026-06-02 2>/dev/null; then
  printf 'FAIL: an inverted window was accepted\n' >&2
  exit 1
fi

printf 'today-stats regression tests passed.\n'
