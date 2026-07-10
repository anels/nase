#!/usr/bin/env bash
# Track /nase:* slash command invocations from UserPromptSubmit/UserPromptExpansion.
# Some slash commands do not pass through PostToolUse:Skill, so this keeps
# workspace/stats/skill-usage.jsonl closer to real usage.
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

NASE_ROOT="${NASE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[ -z "$NASE_ROOT" ] && exit 0
STATS_DIR="$NASE_ROOT/workspace/stats"
JSONL="$STATS_DIR/skill-usage.jsonl"
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOGGER="$HOOK_DIR/../scripts/kb-usage-log.py"

INPUT=$(cat)
HOOK_EVENT="${HOOK_EVENT_NAME:-$(printf '%s' "$INPUT" | jq -r '.hook_event_name // .hookEventName // empty' 2>/dev/null || echo "")}"

if [ "$HOOK_EVENT" = "UserPromptExpansion" ]; then
  SOURCE="prompt-expansion"
  EVENT_TYPE="activated"
  PROMPT=$(printf '%s' "$INPUT" | jq -r '
    .command_name // .command // .slash_command // .prompt // .expanded_prompt // empty
  ' 2>/dev/null || echo "")
  SKILL=$(printf '%s' "$PROMPT" | sed -nE 's/^[[:space:]]*\/?(nase:[a-zA-Z0-9_:-]+)([[:space:]].*)?$/\/\1/p' | head -1)
else
  SOURCE="prompt"
  EVENT_TYPE="requested"
  PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || echo "")
  SKILL=$(printf '%s' "$PROMPT" | sed -nE 's/^[[:space:]]*(\/nase:[a-zA-Z0-9_:-]+)([[:space:]].*)?$/\1/p' | head -1)
fi
[ -z "$PROMPT" ] && exit 0
[ -z "$SKILL" ] && exit 0

SKILL_NAME="${SKILL#/nase:}"
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // .sessionId // empty' 2>/dev/null || true)
[ -n "$SESSION_ID" ] || SESSION_ID="${CLAUDE_SESSION_ID:-${CLAUDE_SESSIONID:-}}"

mkdir -p "$STATS_DIR"

if command -v python3 >/dev/null 2>&1; then
  ACTIVATE_ARGS=(activate --root "$NASE_ROOT" --skill "$SKILL_NAME" --source "$SOURCE")
  [ -n "$SESSION_ID" ] && ACTIVATE_ARGS+=(--session "$SESSION_ID")
  python3 "$LOGGER" "${ACTIVATE_ARGS[@]}" >/dev/null 2>&1 || true
fi

jq -cn --arg s "$SKILL_NAME" --arg t "$TS" --arg source "$SOURCE" --arg event "$EVENT_TYPE" --arg session "$SESSION_ID" \
  '{skill:$s,ts:$t,source:$source,event_type:$event} + (if $session == "" then {} else {session_id:$session} end)' >> "$JSONL"
