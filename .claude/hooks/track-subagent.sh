#!/usr/bin/env bash
# Sourced before `set -e`: on bash 3.2 a syntax error in a sourced file would otherwise
# end the shell with status 2 instead of reaching the `||` fallback below.
HOOK_DIR=${BASH_SOURCE[0]%/*}
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.
# shellcheck source=../lib/hook-common.sh
{ [ -r "$HOOK_DIR/../lib/hook-common.sh" ] && . "$HOOK_DIR/../lib/hook-common.sh"; } 2>/dev/null \
  || { echo "[track-subagent] hook-common.sh unavailable - skipping" >&2; exit 0; }

set -euo pipefail

# SubagentStop hook — append a compact subagent completion summary.

nase_require jq || exit 0

NASE_ROOT=$(nase_root) || exit 0

JSONL="$NASE_ROOT/workspace/stats/subagent-usage.jsonl"

INPUT=$(cat)
TS=$(nase_now_utc)
SESSION_FALLBACK=$(nase_session_id)
EVENT="${HOOK_EVENT_NAME:-SubagentStop}"

LINE=$(printf '%s' "$INPUT" | jq -c --arg ts "$TS" --arg event "$EVENT" --arg sid "$SESSION_FALLBACK" '
  (.last_assistant_message // "") as $msg
  | {
      ts: $ts,
      event: $event,
      session: ((.session_id // "") | if . == "" then $sid else . end),
      agent: (.agent_type // .agentType // .subagent_type // .type // ""),
      transcript: (.agent_transcript_path // .transcript_path // ""),
      duration_ms: (.duration_ms // null),
      message_chars: ($msg | tostring | length)
    }
' 2>/dev/null) || exit 0
nase_append_jsonl "$JSONL" "$LINE" || true
