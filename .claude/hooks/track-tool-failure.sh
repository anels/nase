#!/usr/bin/env bash
set -euo pipefail

# PostToolUseFailure hook — append a bounded failure summary.

command -v jq >/dev/null 2>&1 || exit 0

NASE_ROOT="${NASE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[ -z "$NASE_ROOT" ] && exit 0

STATS_DIR="$NASE_ROOT/workspace/stats"
JSONL="$STATS_DIR/tool-failures.jsonl"
mkdir -p "$STATS_DIR"

INPUT=$(cat)
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EVENT="${HOOK_EVENT_NAME:-PostToolUseFailure}"

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRELUDE=$(cat "$HOOK_DIR/../lib/redact.jq")
printf '%s' "$INPUT" | jq -c --arg ts "$TS" --arg event "$EVENT" \
  "$PRELUDE"'{
    ts: $ts,
    event: $event,
    session: (.session_id // env.CLAUDE_SESSION_ID // ""),
    tool: (.tool_name // .toolName // .tool // .matcher // ""),
    status: "failure",
    duration_ms: (.duration_ms // null),
    error: clip(((.error // .tool_error // .tool_response.error // .message) | scrub); 500)
  }' >> "$JSONL" 2>/dev/null || true
