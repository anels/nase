#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

PYTHON_BIN=$(command -v python3)
STYLE_DOC=".claude/docs/slack-draft-style.md"

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; failures=$((failures + 1)); }
assert_cmd() {
  local name="$1"; shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

# The shared doc is the single home for the mechanics. A consuming command that spells the rule
# out locally instead drifts the moment the tool behaves differently, which is how the literal-'•'
# template survived in two places while the URL/newline rule lived in only one.
assert_cmd "slack-draft-style documents Formatting Mechanics" \
  grep -q '^## Formatting Mechanics' "$STYLE_DOC"
assert_cmd "slack-draft-style names the '- item' list syntax" \
  grep -q '`- item`' "$STYLE_DOC"
assert_cmd "slack-draft-style warns that a blank line after bullets is dropped" \
  grep -Eqi 'blank line (immediately )?after a bullet block' "$STYLE_DOC"
assert_cmd "slack-draft-style keeps the bare-URL rule against \`[label](url)\`" \
  grep -q 'Keep bare URLs' "$STYLE_DOC"

# Both checks below are scoped to Slack-drafting surfaces - files that actually call
# `slack_send_message_draft`. The rules describe what Slack's renderer does to draft text, so
# applying them to ordinary documentation prose would flag every reference list in the repo.
assert_cmd "Slack drafting surfaces avoid the literal bullet character" "$PYTHON_BIN" - <<'PY'
import pathlib, sys

# A literal bullet is the defect itself: plain text to Slack, so it renders with no indent
# however the rest of the message is shaped.
offenders = []
for root in (pathlib.Path(".claude/commands"), pathlib.Path(".claude/docs"), pathlib.Path("workspace/skills")):
    if not root.exists():
        continue
    for path in sorted(root.rglob("*.md")):
        text = path.read_text(encoding="utf-8")
        if "slack_send_message_draft" not in text:
            continue
        for lineno, line in enumerate(text.splitlines(), 1):
            stripped = line.lstrip()
            # Only flag a line that *starts* a bullet with the literal character. Prose that
            # merely quotes '•' while explaining the rule is the whole point of these docs.
            if stripped.startswith("• ") or stripped.startswith("•\t"):
                offenders.append(f"{path}:{lineno}: {line.strip()}")

if offenders:
    print("literal-bullet template lines (use '- ' instead):", file=sys.stderr)
    for item in offenders:
        print(f"  {item}", file=sys.stderr)
    sys.exit(1)
PY

assert_cmd "Slack draft templates never put a bare URL above a bullet" "$PYTHON_BIN" - <<'PY'
import pathlib, re, sys

# The auto-linker consumes the URL, the newline and the following bullet marker into one span, so
# Slack renders the raw <https://...> instead of a link. Prose after the URL bounds the span.
# Only fenced blocks are checked: those are the literal message bodies handed to the draft tool.
BULLET = re.compile(r"^\s*(?:[-*•]\s|\d+\.\s)")
TRAILING_URL = re.compile(r"https?://\S+$")

offenders = []
for root in (pathlib.Path(".claude/commands"), pathlib.Path(".claude/docs"), pathlib.Path("workspace/skills")):
    if not root.exists():
        continue
    for path in sorted(root.rglob("*.md")):
        text = path.read_text(encoding="utf-8")
        if "slack_send_message_draft" not in text:
            continue
        lines = text.splitlines()
        in_fence = False
        for idx, line in enumerate(lines):
            if line.lstrip().startswith("```"):
                in_fence = not in_fence
                continue
            if not in_fence or idx + 1 >= len(lines):
                continue
            stripped = line.rstrip()
            if not TRAILING_URL.search(stripped):
                continue
            # A markdown link or an angle-bracketed URL is already a bounded span.
            if stripped.endswith(")") or stripped.endswith(">"):
                continue
            if BULLET.match(lines[idx + 1]):
                offenders.append(f"{path}:{idx + 1}: {stripped}")

if offenders:
    print("bare URL at end of a template line with a bullet on the next line:", file=sys.stderr)
    for item in offenders:
        print(f"  {item}", file=sys.stderr)
    print("Put prose after the URL on the same line.", file=sys.stderr)
    sys.exit(1)
PY

# Consuming surfaces must point at the shared doc rather than restating a partial version.
for consumer in ".claude/commands/nase/request-review.md" "workspace/skills/handle-support-question.md"; do
  if [[ -f "$consumer" ]]; then
    assert_cmd "$consumer references slack-draft-style Formatting Mechanics" \
      grep -q 'slack-draft-style.md → Formatting Mechanics' "$consumer"
  fi
done

if [[ "$failures" -eq 0 ]]; then
  printf '\nslack-draft-templates tests passed.\n'
  exit 0
fi

printf '\n%d slack-draft-template check(s) failed.\n' "$failures" >&2
exit 1
