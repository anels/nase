#!/usr/bin/env bash
# Regression tests for .claude/scripts/workspace-data-scan.py.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/workspace-data-scan.py"

pass=0
fail=0

assert_cmd() {
  local desc="$1"
  shift
  if "$@"; then
    printf 'PASS  %s\n' "$desc"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s\n' "$desc" >&2
    fail=$((fail + 1))
  fi
}

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/workspace/tasks" "$fixture/workspace/kb" "$fixture/workspace/journals" "$fixture/workspace/logs"

cat > "$fixture/workspace/context.md" <<'MD'
# Context
RepoA=/tmp/repo-a
MD

cat > "$fixture/workspace/tasks/todo.md" <<'MD'
# Todos
- [ ] Follow up on PR
MD

cat > "$fixture/workspace/kb/.domain-map.md" <<'MD'
RepoA=workspace/kb/projects/repo-a.md
MD

cat > "$fixture/workspace/tasks/lessons.md" <<'MD'
# Lessons

## workflow -- 2026-06-04 -- Out of range
Do not include this lesson.

## debugging -- 2026-06-05 -- In range
Include this lesson.
MD

cat > "$fixture/workspace/journals/2026-06-05.md" <<'MD'
# Journal

## Sessions
Journal wins over log for this day.
MD

cat > "$fixture/workspace/logs/2026-06-05.md" <<'MD'
# Log

## Sessions
This fallback log should not be selected when the journal exists.
MD

{
  printf '# Log\n\n## Sessions\n'
  printf 'noise line %.0s\n' {1..80}
  printf 'decision: keep the exact source path for fallback\n'
  printf 'https://github.com/acme/widgets/pull/42\n'
  printf 'noise line %.0s\n' {1..80}
} > "$fixture/workspace/logs/2026-06-06.md"

out="$fixture/out.json"
python3 "$SCRIPT" 2026-06-05 2026-06-06 --root "$fixture" --scope range --max-day-chars 260 > "$out"

assert_cmd "filters lessons to date range" python3 - "$out" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
sections = data["workspace_state"]["lessons_md"]["matching_sections"]
assert len(sections) == 1
assert "In range" in sections[0]["header"]
assert "Out of range" not in sections[0]["content"]
PY

assert_cmd "prefers journal over same-day log" python3 - "$out" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
day = data["days"][0]
assert day["date"] == "2026-06-05"
assert day["source"] == "journal"
assert "Journal wins" in day["content"]
assert "fallback log" not in day["content"]
PY

assert_cmd "truncates long logs but keeps fallback signals" python3 - "$out" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
day = data["days"][1]
assert day["date"] == "2026-06-06"
assert day["source"] == "log"
assert day["truncated"] is True
assert day["path"] == "workspace/logs/2026-06-06.md"
assert "decision: keep the exact source path" in day["content"]
assert "https://github.com/acme/widgets/pull/42" in day["content"]
PY

day_out="$fixture/day.json"
python3 "$SCRIPT" 2026-06-05 2026-06-05 --root "$fixture" --scope day > "$day_out"

assert_cmd "day scope skips broad workspace context" python3 - "$day_out" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["scope"] == "day"
assert data["workspace_state"]["context_md"]["skipped"] is True
assert data["workspace_state"]["domain_map_md"]["skipped"] is True
assert data["workspace_state"]["context_md"]["exists"] is True
assert data["workspace_state"]["domain_map_md"]["exists"] is True
assert data["workspace_state"]["todo_md"]["exists"] is True
assert data["workspace_state"]["lessons_md"]["matching_sections"]
PY

total=$((pass + fail))
printf '\n%d/%d assertions passed\n' "$pass" "$total"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
