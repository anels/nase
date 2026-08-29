#!/usr/bin/env bash
# PreToolUse guard: run .claude/scripts/prose-lint.py over a Slack draft body
# before it reaches the draft tool.
#
# Blocks only on gate findings and on a marker count above the threshold. A gate
# is a mechanical defect with a concrete failure - an embed link that renders
# wrong, a bare URL that swallows the next line. Register markers are counted,
# never individually decisive.
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
BODY=$(printf '%s' "$INPUT" | jq -r '
  .tool_input // {} |
  (.text // .message // .markdown_text // empty) |
  select(type == "string")
' 2>/dev/null) || exit 0
[ -z "$BODY" ] && exit 0

TMP=$(mktemp) || exit 0
trap 'rm -f "$TMP"' EXIT
printf '%s' "$BODY" >"$TMP"

REPORT=$(python3 "$LINT" --surface slack-channel --file "$TMP" 2>/dev/null)
RC=$?

[ "$RC" -eq 0 ] && exit 0
[ "$RC" -ne 1 ] && exit 0

{
  echo "BLOCKED by prose-lint-guard: the draft body fails the plain-writing gate."
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
