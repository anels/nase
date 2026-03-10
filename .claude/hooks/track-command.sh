#!/usr/bin/env bash
set -euo pipefail

# UserPromptSubmit hook — track /nase:* command invocations to JSONL
# Fires whenever the user submits a message containing a /nase:* command.
# Replaces PostToolUse:Skill tracking, which missed auto-injected slash commands.
# Input: JSON on stdin with user_prompt field.

WORKSPACE=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
STATS_DIR="$WORKSPACE/work/stats"
JSONL="$STATS_DIR/skill-usage.jsonl"

INPUT=$(cat)
USER_PROMPT=$(echo "$INPUT" | jq -r '.user_prompt // empty' 2>/dev/null) || exit 0

# Extract first /nase:<skill-name> from the prompt
SKILL=$(echo "$USER_PROMPT" | grep -oE '/nase:[a-z][a-z0-9_-]*' | head -1 | sed 's|/nase:||') || true
[ -z "$SKILL" ] && exit 0

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$STATS_DIR"

# Dedup: skip if same skill + same second already recorded
if [ -f "$JSONL" ]; then
  LAST=$(tail -1 "$JSONL" 2>/dev/null || true)
  LAST_SKILL=$(echo "$LAST" | jq -r '.skill // empty' 2>/dev/null || true)
  LAST_TS=$(echo "$LAST" | jq -r '.ts // empty' 2>/dev/null || true)
  if [ "$LAST_SKILL" = "$SKILL" ] && [ "$LAST_TS" = "$TS" ]; then
    exit 0
  fi
fi

echo "{\"skill\":\"$SKILL\",\"ts\":\"$TS\"}" >> "$JSONL"
