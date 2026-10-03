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

[ "$failures" -eq 0 ] && printf '\ndaily-log-append tests passed.\n'
