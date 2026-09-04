#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/skill-usage-report.py"
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

mkdir -p "$TMPROOT/.claude/commands/nase" "$TMPROOT/workspace/skills" "$TMPROOT/workspace/stats"
printf '%04000d\n' 0 > "$TMPROOT/.claude/commands/nase/design.md"
printf 'small\n' > "$TMPROOT/.claude/commands/nase/today.md"
printf 'report\n' > "$TMPROOT/.claude/commands/nase/skill-usage.md"
printf 'test\n' > "$TMPROOT/workspace/skills/test.md"
printf 'unused\n' > "$TMPROOT/workspace/skills/unused.md"

cat > "$TMPROOT/workspace/stats/skill-usage.jsonl" <<'JSONL'
{"skill":"design","ts":"2026-07-16T10:00:00Z","event_type":"requested","session_id":"a"}
{"skill":"design","ts":"2026-07-16T10:00:01Z","event_type":"activated","session_id":"a"}
{"skill":"design","ts":"2026-07-16T10:01:00Z","event_type":"tool_succeeded","session_id":"a"}
{"skill":"design","ts":"2026-07-17T10:00:01Z","event_type":"activated","session_id":"b"}
{"skill":"design","ts":"2026-07-18T10:00:01Z","event_type":"activated","session_id":"future"}
{"skill":"skill-usage","ts":"2026-07-16T09:00:00Z","event_type":"tool_succeeded","session_id":"c"}
{"skill":"skill-usage","ts":"2026-07-16T09:00:30Z","event_type":"tool_succeeded","session_id":"c"}
{"skill":"skill-usage","ts":"2026-07-16T09:05:00Z","event_type":"tool_succeeded","session_id":"c"}
{"skill":"test","ts":"2026-07-16T11:00:00Z","event_type":"activated","session_id":"d"}
{"skill":"test","ts":"2026-07-16T11:00:12Z","event_type":"activated","session_id":"d"}
{"skill":"today","ts":"2026-07-10T10:00:00Z","source":"prompt","session_id":"legacy"}
{"skill":"today","ts":"2026-07-10T10:00:10Z","source":"prompt-expansion","session_id":"legacy"}
{"skill":"today","ts":"2026-07-10T10:00:20Z","source":"tool","session_id":"legacy"}
{"skill":"workspace:test","ts":"2026-07-01T10:00:00Z","source":"tool","session_id":"legacy-2"}
not-json
JSONL

TZ=UTC python3 "$SCRIPT" --root "$TMPROOT" --date 2026-07-17 --output "$TMPROOT/report.md" > "$TMPROOT/result.json"

# Select design by name rather than by rank: its total is the property under
# test, and another fixture skill outranking it is not a failure.
jq -e '.ok and .malformed == 1 and ([.top[] | select(.skill == "design")] == [{"skill":"design","total":2}])' "$TMPROOT/result.json" >/dev/null
grep -q '| design | 2 |' "$TMPROOT/report.md"
grep -q '| today | 1 |' "$TMPROOT/report.md"
# skill-usage has only tool outcomes and no `activated`, which is what a
# model-invoked or nested skill emits. All three count: PostToolUse fires once
# per Skill call, and a tool outcome is only ever the duplicate of a preceding
# prompt event, never of another tool outcome - so the 30s gap must not collapse.
grep -q '| skill-usage | 3 | 3 | 3 | 2026-07-16 | 100% |' "$TMPROOT/report.md"
if grep -q '^- skill-usage - ' "$TMPROOT/report.md"; then
  printf 'FAIL: skill-usage used on 2026-07-16 listed as a deprecation candidate\n' >&2
  exit 1
fi
# Two typed /nase:test runs 12s apart in one session are two uses. An earlier
# revision deduped every event against a shared same-session window, which
# silently collapsed repeat typed invocations like these while collapsing none
# of the tool outcomes it was written for.
grep -q '| test | 2 | 2 | 2 | 2026-07-16 | n/a |' "$TMPROOT/report.md"
grep -q '| workspace:test | 1 |' "$TMPROOT/report.md"
grep -q 'Total skills on disk: 5 (native: 3, workspace: 2)' "$TMPROOT/report.md"
grep -q '^## Context Hotspots$' "$TMPROOT/report.md"
grep -q '| design | 2 | 4001 |' "$TMPROOT/report.md"
grep -q 'workspace:unused - unused' "$TMPROOT/report.md"

printf 'skill-usage-report regression tests passed.\n'
