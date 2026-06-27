#!/usr/bin/env bash
set -euo pipefail

# SubagentStop hook — append a compact subagent completion summary.

command -v jq >/dev/null 2>&1 || exit 0

NASE_ROOT="${NASE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[ -z "$NASE_ROOT" ] && exit 0

STATS_DIR="$NASE_ROOT/workspace/stats"
JSONL="$STATS_DIR/subagent-usage.jsonl"
mkdir -p "$STATS_DIR"

INPUT=$(cat)
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EVENT="${HOOK_EVENT_NAME:-SubagentStop}"

printf '%s' "$INPUT" | jq -c --arg ts "$TS" --arg event "$EVENT" '
  (.last_assistant_message // "") as $msg
  | {
      ts: $ts,
      event: $event,
      session: (.session_id // env.CLAUDE_SESSION_ID // ""),
      agent: (.agent_type // .agentType // .subagent_type // .type // ""),
      transcript: (.agent_transcript_path // .transcript_path // ""),
      duration_ms: (.duration_ms // null),
      message_chars: ($msg | tostring | length)
    }
' >> "$JSONL" 2>/dev/null || true
