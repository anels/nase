#!/usr/bin/env bash
# Regression tests for .claude/scripts/kb-usage-report.py.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/kb-usage-report.py"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/workspace/kb/projects" "$FIXTURE/workspace/kb/general" "$FIXTURE/workspace/kb/ops" "$FIXTURE/workspace/stats"
cat > "$FIXTURE/workspace/kb/.domain-map.md" <<'EOF'
# Domain map

- project-a → workspace/kb/projects/a.md
- general-b → workspace/kb/general/b.sql
- unused → workspace/kb/ops/unused.md
EOF
printf '# a\n' > "$FIXTURE/workspace/kb/projects/a.md"
printf 'select 1;\n' > "$FIXTURE/workspace/kb/general/b.sql"
printf '# unused\n' > "$FIXTURE/workspace/kb/ops/unused.md"

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

assert_contains() {
  local desc="$1"
  local text="$2"
  local needle="$3"
  if printf '%s' "$text" | grep -qF "$needle"; then
    pass_msg "$desc"
  else
    fail_msg "$desc (missing $needle)"
    printf '%s\n' "$text" >&2
  fi
}

assert_not_contains() {
  local desc="$1"
  local text="$2"
  local needle="$3"
  if printf '%s' "$text" | grep -qF "$needle"; then
    fail_msg "$desc (unexpected $needle)"
    printf '%s\n' "$text" >&2
  else
    pass_msg "$desc"
  fi
}

empty_report="$FIXTURE/workspace/stats/kb-usage-empty.md"
empty_out=$(NASE_ROOT="$FIXTURE" python3 "$SCRIPT" --window 30 --top 5 --now 2026-06-13T12:00:00Z --output "$empty_report" 2>&1)
rc=$?
if [ "$rc" = 0 ] && [ -f "$empty_report" ]; then
  pass_msg "T1: no-data report writes artifact"
else
  fail_msg "T1: no-data report failed (exit $rc)"
fi
assert_contains "T1: no-data summary shows zero files" "$empty_out" "KB files used: 0"
assert_contains "T1: no-data report explains empty ledger" "$(cat "$empty_report" 2>/dev/null)" "No KB usage data yet."

cat > "$FIXTURE/workspace/stats/kb-usage.jsonl" <<'EOF'
not-json
{"ts":"2026-06-12T00:00:00Z","skill":"fsd","file":"workspace/kb/projects/a.md","access":"read","source":"read-hook","session":"s1"}
{"ts":"2026-06-12T01:00:00Z","skill":"fsd","file":"workspace/kb/projects/a.md","access":"resolve","source":"kb-domain-resolve","session":"s1"}
{"ts":"2026-06-11T00:00:00Z","skill":"unknown","file":"workspace/kb/general/b.sql","access":"search-result","source":"kb-search","session":"s2"}
{"ts":"2026-04-01T00:00:00Z","skill":"old","file":"workspace/kb/projects/old.md","access":"read","source":"read-hook","session":"s3"}
EOF

report="$FIXTURE/workspace/stats/kb-usage-2026-06-13.md"
out=$(NASE_ROOT="$FIXTURE" python3 "$SCRIPT" --window 30 --top 1 --now 2026-06-13T12:00:00Z --output "$report" 2>&1)
rc=$?
if [ "$rc" = 0 ] && [ -f "$report" ]; then
  pass_msg "T2: populated report writes artifact"
else
  fail_msg "T2: populated report failed (exit $rc)"
fi

body=$(cat "$report" 2>/dev/null)
assert_contains "T2: summary counts unique KB files" "$out" "KB files used: 2"
assert_contains "T2: summary counts skills including unknown" "$out" "Skills using KB: 2"
assert_contains "T2: summary counts unused mapped files" "$out" "Unused mapped KB files: 1"
assert_contains "T2: report records malformed lines skipped" "$body" "Malformed lines skipped: 1"
assert_contains "T2: top files sorted by event count" "$body" "workspace/kb/projects/a.md"
assert_contains "T2: source breakdown includes search results" "$body" "search-result"
assert_contains "T2: unused mapped file is listed" "$body" "workspace/kb/ops/unused.md"
assert_not_contains "T2: old event outside window is excluded" "$body" "workspace/kb/projects/old.md"

total=$((pass + fail))
printf '\n%d/%d assertions passed\n' "$pass" "$total"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
