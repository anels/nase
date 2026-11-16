#!/usr/bin/env bash
# Regression tests for .claude/scripts/daily-log-append.py.
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/daily-log-append.py"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

# shellcheck source=/dev/null
. "$ROOT/tests/lib/assert.sh"
failures=0

today=$(PYTHONPATH="$ROOT/.claude/scripts" python3 -c 'from nase_time import local_today; print(local_today().isoformat())')
log="$FIXTURE/workspace/logs/$today.md"

python3 "$SCRIPT" review "first entry" --root "$FIXTURE" --time 09:05 >/dev/null
assert_cmd "new log starts with the Work Log header" grep -qx "# Work Log — $today" "$log"
assert_cmd "new log has a Sessions section" grep -qx "## Sessions" "$log"
assert_cmd "entry uses the canonical shape" grep -qx -- "- 09:05 | review: first entry" "$log"

printf '\n## Commits\n- abc123 something\n' >> "$log"
python3 "$SCRIPT" fsd "second entry" --root "$FIXTURE" --time 09:10 >/dev/null
second_line=$(grep -n -- "- 09:10 | fsd: second entry" "$log" | cut -d: -f1)
commits_line=$(grep -n "^## Commits" "$log" | cut -d: -f1)
assert_cmd "entry lands inside Sessions, before a later section" test -n "$second_line" -a "${second_line:-0}" -lt "${commits_line:-0}"
assert_cmd "later section is preserved" grep -qx -- "- abc123 something" "$log"

printf -- '- 08:00 legacy line\n' > "$log"
python3 "$SCRIPT" today "third entry" --root "$FIXTURE" --time 10:00 >/dev/null
assert_cmd "existing log content is kept verbatim" grep -qx -- "- 08:00 legacy line" "$log"
assert_cmd "missing Sessions section is appended" grep -qx "## Sessions" "$log"

python3 "$SCRIPT" today $'two\nlines' --root "$FIXTURE" >/dev/null 2>&1
assert_cmd "multi-line summary is rejected" test "$?" = 2
python3 "$SCRIPT" "Bad Tag" "x" --root "$FIXTURE" >/dev/null 2>&1
assert_cmd "invalid tag is rejected" test "$?" = 2

python3 "$SCRIPT" today $'a\x0bb' --root "$FIXTURE" >/dev/null 2>&1
assert_cmd "vertical-tab summary is rejected" test "$?" = 2
python3 "$SCRIPT" today $'a\tb' --root "$FIXTURE" --time 09:30 >/dev/null 2>&1
assert_cmd "a tab in the summary is accepted" test "$?" = 0
python3 "$SCRIPT" today $'a\xc2\x85b' --root "$FIXTURE" >/dev/null 2>&1
assert_cmd "NEL summary is rejected" test "$?" = 2
python3 "$SCRIPT" today $'a\xe2\x80\xa8b' --root "$FIXTURE" >/dev/null 2>&1
assert_cmd "line-separator summary is rejected" test "$?" = 2

printf '# Work Log\r\n\r\n## Sessions\r\n\r\n- 08:00 crlf legacy\r\n' > "$log"
python3 "$SCRIPT" today "crlf entry" --root "$FIXTURE" --time 11:00 >/dev/null
assert_cmd "CRLF log stays CRLF after an append" cmp -s "$log" <(printf '# Work Log\r\n\r\n## Sessions\r\n\r\n- 08:00 crlf legacy\r\n- 11:00 | today: crlf entry\r\n')
assert_cmd "CRLF log has no bare LF" test "$(grep -c $'\r$' "$log")" = "$(wc -l < "$log" | tr -d ' ')"

printf '# Work Log\n\n## Sessions\n\n- 08:00 form\x0cfeed legacy\n- 08:01 next\n' > "$log"
python3 "$SCRIPT" today "ff entry" --root "$FIXTURE" --time 11:05 >/dev/null
assert_cmd "legacy form-feed line is preserved byte for byte" cmp -s "$log" <(printf '# Work Log\n\n## Sessions\n\n- 08:00 form\x0cfeed legacy\n- 08:01 next\n- 11:05 | today: ff entry\n')

rm -f "$log"
for i in $(seq 1 30); do
  python3 "$SCRIPT" today "parallel $i" --root "$FIXTURE" --time 12:00 >/dev/null &
done
wait
landed=$(grep -c -- "| today: parallel " "$log")
assert_cmd "30 parallel appends all land (got $landed)" test "$landed" = 30
assert_cmd "no temporary files remain" test -z "$(find "$FIXTURE/workspace/logs" -name '.*.??????' -not -name '.daily-log.lock')"

[ "$failures" -eq 0 ] && printf '\ndaily-log-append tests passed.\n'
