#!/usr/bin/env bash
set -uo pipefail

# UserPromptSubmit hook — detect user-style-edit signal on prior draft and
# inject a reminder to log a [STYLE-DELTA] per .claude/docs/style-delta-capture.md.
#
# Two tiers, so code edits and internal KB writes stay quiet:
#   - an explicit artifact phrase ("Slack draft", "PR description", "PR:" prefix)
#     fires with any wording cue;
#   - a bare "the PR" / "the DM" fires only with a tone or tightening cue,
#     because it could just as well be the PR itself;
#   - a bare "the message" fires only with a tone cue, and a bare artifact used as a
#     code noun ("the PR build", "the message queue") never fires;
#   - a bare "message", "pr", "dm" or "draft" never counts on its own.
#
# Output contract: emit a UserPromptSubmit JSON with additionalContext on
# match; emit nothing otherwise. Always exit 0 — never block user input.

INPUT=$(cat)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || true)
[ -z "$PROMPT" ] && exit 0

NB='[^[:alnum:]_]'

# Wording cues: phrases about how text reads.
TONE="too (AI|formal|wordy|verbose|long|stiff|robotic|casual|harsh|blunt|salesy)|(less|more) (formal|casual|concise|direct|friendly|polite)|sounds? (like )?(AI|robotic|stiff|corporate|me)|wordy|(don'?t|do not|never|stop) say(ing)?|instead of saying|太 ?AI|AI 味|不要说|啰嗦|太正式|太生硬|口语"
STYLE="$TONE|rephrase|reword|不要这样|别这样|精简|重写|下次|改成|换成|去掉"
# Generic edit verbs: count only next to an explicit draft artifact.
BRIEF="next time|from now on|drop the|remove the|rewrite (as|it)|change (to )?[\"']"
# Tightening words: enough for a bare "the PR" / "the DM".
TIGHT="shorter|shorten|trim|terser|concise|精简|简短|缩短"

# An explicit artifact phrase, "my/that draft", or a "PR:" style shorthand prefix.
SURFACE_EXPLICIT="(slack|dm|pr|pull request|review|inline|jira|confluence|github)[ -]+(message|draft|description|body|title|comment|reply|post|summary|announcement|text)|(my|that|this) draft|草稿|(pr|slack|dm) ?(描述|消息|回复|评论)|^(pr|dm|slack|inline comment|review comment|external doc|announcement)[:：]"
# A bare determiner + artifact: ambiguous, so it needs a TONE or TIGHT cue.
SURFACE_BARE="(the|this|that|my) (prs?|dms?|pull request|slack message)($NB|\$)|(这|那)(条|个)消息|(这|那)(条|个)?(回复|评论|草稿)"
SURFACE_BARE_A="(a|an) (prs?|dms?|slack message)($NB|\$)"
# A bare "the message" is more ambiguous still (log, error, commit messages), so it needs a TONE cue.
SURFACE_BARE_MSG="(the|this|that|my) message($NB|\$)"
# A bare artifact word used as a code noun ("the PR build", "the message queue") is not a draft.
CODE_NOUN="(prs?|dms?|message|pull request|slack message) (build|builds|check|checks|pipeline|workflow|script|template|handler|parser|loader|branch|bot|ci|tests?|queue|formatter|validator|sender|service|module|function|logs?)($NB|\$)|(消息|回复|评论|草稿)(队列|解析|处理|格式化|模块|服务|函数|日志|校验)"

shopt -s nocasematch
fire=0
if   [[ "$PROMPT" =~ $SURFACE_EXPLICIT ]] && { [[ "$PROMPT" =~ $STYLE ]] || [[ "$PROMPT" =~ $BRIEF ]] || [[ "$PROMPT" =~ $TIGHT ]]; }; then fire=1
elif [[ "$PROMPT" =~ $CODE_NOUN ]]; then :
elif [[ "$PROMPT" =~ $SURFACE_BARE ]]     && { [[ "$PROMPT" =~ $TONE ]] || [[ "$PROMPT" =~ $TIGHT ]]; }; then fire=1
elif [[ "$PROMPT" =~ $SURFACE_BARE_A ]]   && [[ "$PROMPT" =~ $TONE ]]; then fire=1
elif [[ "$PROMPT" =~ $SURFACE_BARE_MSG ]] && [[ "$PROMPT" =~ $TONE ]]; then fire=1
fi

if [ "$fire" = 1 ]; then
  TODAY=$(date +%Y-%m-%d)
  jq -cn --arg date "$TODAY" '{
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: ("[style-edit-detect] Possible draft style correction. Apply this only if the user is correcting a draft you wrote; otherwise ignore it. If so, address it, then append pending [STYLE-DELTA] to workspace/logs/" + $date + ".md per .claude/docs/style-delta-capture.md. Do not edit workspace/communication-style.md directly.")
    }
  }'
fi
exit 0
