#!/usr/bin/env bash
set -uo pipefail

# UserPromptSubmit hook — detect user-style-edit signal on prior draft and
# inject a reminder to log a [STYLE-DELTA] per CLAUDE.md §Style Learning Loop.
#
# Fires only when the user prompt carries BOTH an edit-signal keyword AND a
# draft-context cue (Slack / PR / external doc). Reduces false positives on
# code edits and internal KB writes.
#
# Output contract: emit a UserPromptSubmit JSON with additionalContext on
# match; emit nothing otherwise. Always exit 0 — never block user input.

INPUT=$(cat)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || true)
[ -z "$PROMPT" ] && exit 0

EDIT_REGEX="(don'?t say|do not say|next time|from now on|instead of saying|drop the|remove the|rewrite (as|it)|rephrase|change \"|change '|change to '|change to \"|too AI|too formal|too verbose|sounds AI|more concise|shorter|terser|下次|改成|换成|去掉|不要说|太 ?AI|AI 味|精简|重写|不要这样|别这样)"

CTX_REGEX="(slack|(^|[^[:alnum:]_])dm([^[:alnum:]_]|$)|draft|草稿|消息|(^|[^[:alnum:]_])pr([^[:alnum:]_]|$)|pr description|pr body|pull request|inline comment|review comment|external doc|announcement|公告|message i drafted|the message)"

shopt -s nocasematch
if [[ "$PROMPT" =~ $EDIT_REGEX ]] && [[ "$PROMPT" =~ $CTX_REGEX ]]; then
  TODAY=$(date +%Y-%m-%d)
  jq -cn --arg date "$TODAY" '{
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: ("[style-edit-detect] Draft style correction. Address it, then append pending [STYLE-DELTA] to workspace/logs/" + $date + ".md per .claude/docs/style-delta-capture.md. Do not edit workspace/communication-style.md directly.")
    }
  }'
fi
exit 0
