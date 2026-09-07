#!/usr/bin/env bash
# PreToolUse guard: run .claude/scripts/prose-lint.py over a Slack draft body
# before it reaches the draft tool.
#
# Blocks only on gate findings and on a marker count above the threshold. A gate
# is a mechanical defect with a concrete failure - an embed link that renders
# wrong, a bare URL that swallows the next line. Register markers are counted,
# never individually decisive.
#
# The surface comes from `channel_id`, because prose-lint.py scores a DM and a channel
# separately and the payload already says which this is.
#
# Fails open on infrastructure problems (missing jq, python, or script): a broken
# guard must not silence a draft the user asked for.
#
# Escape hatch: NASE_PROSE_LINT=0.
set -uo pipefail

[ "${NASE_PROSE_LINT:-1}" = "0" ] && exit 0

ROOT="${NASE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
LINT="$ROOT/.claude/scripts/prose-lint.py"

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
[ -r "$LINT" ] || exit 0

INPUT=$(cat)
# `message` is the field the Slack draft tool documents and requires; `text` and
# `markdown_text` stay in the chain because the hook matcher accepts any provider
# whose tool name ends in slack_send_message_draft, not one named server.
BODY=$(printf '%s' "$INPUT" | jq -r '
  .tool_input // {} |
  (.message // .text // .markdown_text // empty) |
  select(type == "string")
' 2>/dev/null) || exit 0

if [ -z "$BODY" ]; then
  # Falling through is right when there is nothing to review, and falling through
  # *silently* is wrong when the payload carries fields but none of them is a body: that
  # is a renamed field, and every draft after it would ship unlinted. The exit stays 0,
  # because a quality check must never be the reason a draft cannot be written; the
  # notice only puts the reason in the transcript instead of leaving no trace.
  UNKNOWN_SHAPE=$(printf '%s' "$INPUT" | jq -r '
    (.tool_input // {}) as $in |
    if ($in | type) == "object" and ($in | length) > 0
       and ([$in | has("message"), has("text"), has("markdown_text")] | any | not)
    then ($in | keys | join(", ")) else empty end
  ' 2>/dev/null) || UNKNOWN_SHAPE=""
  if [ -n "$UNKNOWN_SHAPE" ]; then
    # The `[prose-lint-guard]` prefix is what makes an exit-0 line reach the user; see
    # CLAUDE.md. Without it this notice is written and never read, which is the same as
    # not writing it.
    printf '[prose-lint-guard] no draft body to review; fields present: %s\n' \
      "$UNKNOWN_SHAPE" >&2
    printf '[prose-lint-guard] the draft was not linted. Update the body field list in %s\n' \
      ".claude/hooks/prose-lint-guard.sh" >&2
  fi
  exit 0
fi

# `U`/`W` are user IDs, which the draft tool accepts directly as a DM target; `D` is an
# opened DM conversation. `G` covers both legacy private channels and group DMs, so it
# stays on the channel rules, which are the more public reading.
CHANNEL=$(printf '%s' "$INPUT" | jq -r '
  .tool_input.channel_id // empty | select(type == "string")
' 2>/dev/null) || CHANNEL=""
case "$CHANNEL" in
  [DdUuWw]*) SURFACE="slack-dm" ;;
  *) SURFACE="slack-channel" ;;
esac

TMP=$(mktemp) || exit 0
trap 'rm -f "$TMP"' EXIT
printf '%s' "$BODY" >"$TMP"

REPORT=$(python3 "$LINT" --surface "$SURFACE" --file "$TMP" 2>/dev/null)
RC=$?

[ "$RC" -eq 0 ] && exit 0
[ "$RC" -ne 1 ] && exit 0

{
  echo "BLOCKED by prose-lint-guard: the draft body fails the plain-writing gate."
  echo "Surface: $SURFACE (from channel_id ${CHANNEL:-<absent>})."
  echo ""
  echo "$REPORT"
  echo ""
  echo "Fix the gate findings, then redraft. Markers above the threshold mean the"
  echo "shape needs a rewrite, not a word swap - see .claude/docs/plain-writing-guard.md"
  echo "Parts 1 and 2 before editing vocabulary."
  echo ""
  echo "This counts patterns. It is not evidence of authorship."
  echo "Set NASE_PROSE_LINT=0 only when the flagged text is a quote from someone else."
} >&2
exit 2
