#!/usr/bin/env bash
# Track /nase:* slash command invocations from UserPromptSubmit/UserPromptExpansion.
# Some slash commands do not pass through PostToolUse:Skill, so this keeps
# workspace/stats/skill-usage.jsonl closer to real usage.
# Sourced before `set -e`: on bash 3.2 a syntax error in a sourced file would otherwise
# end the shell with status 2 instead of reaching the `||` fallback below.
HOOK_DIR=${BASH_SOURCE[0]%/*}
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.
# shellcheck source=../lib/hook-common.sh
{ [ -r "$HOOK_DIR/../lib/hook-common.sh" ] && . "$HOOK_DIR/../lib/hook-common.sh"; } 2>/dev/null \
  || { echo "[track-skill-prompt] hook-common.sh unavailable - skipping" >&2; exit 0; }

set -euo pipefail

nase_require jq || exit 0

NASE_ROOT=$(nase_root) || exit 0
STATS_DIR="$NASE_ROOT/workspace/stats"
JSONL="$STATS_DIR/skill-usage.jsonl"
LOGGER="$HOOK_DIR/../scripts/kb-usage-log.py"

INPUT=$(cat)
HOOK_EVENT="${HOOK_EVENT_NAME:-$(printf '%s' "$INPUT" | jq -r '.hook_event_name // .hookEventName // empty' 2>/dev/null || echo "")}"

if [ "$HOOK_EVENT" = "UserPromptExpansion" ]; then
  SOURCE="prompt-expansion"
  EVENT_TYPE="activated"
  PROMPT=$(printf '%s' "$INPUT" | jq -r '
    .command_name // .command // .slash_command // .prompt // .expanded_prompt // empty
  ' 2>/dev/null || echo "")
  SKILL=$(printf '%s' "${PROMPT%%$'\n'*}" | sed -nE 's/^[[:space:]]*\/?(nase:[a-zA-Z0-9_:-]+)([[:space:]].*)?$/\/\1/p')
else
  SOURCE="prompt"
  EVENT_TYPE="requested"
  PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || echo "")
  SKILL=$(printf '%s' "${PROMPT%%$'\n'*}" | sed -nE 's/^[[:space:]]*(\/nase:[a-zA-Z0-9_:-]+)([[:space:]].*)?$/\1/p')
fi
[ -z "$PROMPT" ] && exit 0
[ -z "$SKILL" ] && exit 0

SKILL_NAME="${SKILL#/nase:}"
TS=$(nase_now_utc)
SESSION_ID=$(nase_session_id "$INPUT")

if nase_require python3; then
  ACTIVATE_ARGS=(activate --root "$NASE_ROOT" --skill "$SKILL_NAME" --source "$SOURCE")
  [ -n "$SESSION_ID" ] && ACTIVATE_ARGS+=(--session "$SESSION_ID")
  python3 "$LOGGER" "${ACTIVATE_ARGS[@]}" >/dev/null 2>&1 || true
fi

LINE=$(jq -cn --arg s "$SKILL_NAME" --arg t "$TS" --arg source "$SOURCE" --arg event "$EVENT_TYPE" --arg session "$SESSION_ID" \
  '{skill:$s,ts:$t,source:$source,event_type:$event} + (if $session == "" then {} else {session_id:$session} end)')
nase_append_jsonl "$JSONL" "$LINE"
