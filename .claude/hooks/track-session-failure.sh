#!/usr/bin/env bash
set -euo pipefail

# StopFailure hook — append a compact API/session failure summary.

command -v jq >/dev/null 2>&1 || exit 0

NASE_ROOT="${NASE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[ -z "$NASE_ROOT" ] && exit 0

STATS_DIR="$NASE_ROOT/workspace/stats"
JSONL="$STATS_DIR/session-failures.jsonl"
mkdir -p "$STATS_DIR"

INPUT=$(cat)
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EVENT="${HOOK_EVENT_NAME:-StopFailure}"

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRELUDE=$(cat "$HOOK_DIR/../lib/redact.jq")
printf '%s' "$INPUT" | jq -c --arg ts "$TS" --arg event "$EVENT" \
  "$PRELUDE"'{
    ts: $ts,
    event: $event,
    session: (.session_id // env.CLAUDE_SESSION_ID // ""),
    error: clip((.error | scrub); 500),
    error_details: clip((.error_details | scrub); 500),
    last_assistant_chars: ((.last_assistant_message // "") | tostring | length)
  }' >> "$JSONL" 2>/dev/null || true
