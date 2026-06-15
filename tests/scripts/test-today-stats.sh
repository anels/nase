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
{"skill":"old","ts":"2026-05-31T23:59:59Z","status":"success"}
JSONL

out=$(python3 "$SCRIPT" --root "$tmp" --date 2026-06-01)
compat_out=$(python3 "$SCRIPT" --root "$tmp" --workspace ignored --date 2026-06-01)

if [ "$compat_out" != "$out" ]; then
  printf 'FAIL: --workspace compatibility output changed\nOutput:\n%s\nCompat:\n%s\n' "$out" "$compat_out" >&2
  exit 1
fi

assert_line() {
  local needle="$1"
  if ! grep -qxF "$needle" <<< "$out"; then
    printf 'FAIL: missing line: %s\nOutput:\n%s\n' "$needle" "$out" >&2
    exit 1
  fi
}

assert_line "total_invocations=4"
assert_line "unique_skills=3"
assert_line "skill help 1"
assert_line "skill reflect 2"
assert_line "skill today 1"

printf 'today-stats regression tests passed.\n'
