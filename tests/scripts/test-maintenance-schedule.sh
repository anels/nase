#!/usr/bin/env bash
# Regression tests for .claude/scripts/maintenance-schedule.py
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/maintenance-schedule.py"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# shellcheck source=/dev/null
. "$ROOT/tests/lib/assert.sh"
failures=0

todo="$tmp/workspace/tasks/todo.md"
mkdir -p "$tmp/workspace/tasks"

# Lines: weekly with the sign and the long dash, a bare `--` line with no sign, a line
# with no cadence, a paused line, a ticked line, a line with a future due date, and a
# bullet in a different section that must never be read as a schedule.
cat > "$todo" <<'MD'
# Tasks

## Independent

- [ ] 📅 2020-01-01 — `/nase:kb-review` — not a schedule line, wrong section

## Scheduled Maintenance

- [ ] 📅 2026-09-03 — `/nase:kb-review` — Weekly KB hygiene (every 7d) (last run 2026-08-27)
- [ ] 2026-08-31 -- `/nase:workspace:optimize-skills-from-lessons` -- Apply lessons (every 14d)
- [ ] 📅 2026-09-01 — `/nase:onboard` — Batch refresh
- [ ] ⏸️ 2026-09-02 — `/nase:recap` — Paused (every 7d)
- [x] 2026-09-02 — `/nase:stats` — Ticked (every 7d)
- [ ] 📅 2026-11-01 — `/nase:effort-rollup` — Monthly (every 30d)
- [ ] ⏸️ Deferred - compact `insights-monitoring.md`

## Archived

- [ ] 📅 2020-01-01 — `/nase:doctor` — after the section (every 7d)
MD

has_line() { grep -qxF -- "$1" <<< "$out"; }
lacks() { ! grep -qF -- "$1" <<< "$out"; }
file_has() { grep -qxF -- "$1" "$todo"; }

out=$(python3 "$SCRIPT" list --root "$tmp" --date 2026-10-23)
assert_cmd "counts only live schedule lines" has_line "scheduled=4 due=3"
assert_cmd "an overdue line reports its age" has_line "due kb-review 2026-09-03 (overdue-50d)"
assert_cmd "a bare -- line is read" has_line "due workspace:optimize-skills-from-lessons 2026-08-31 (overdue-53d)"
assert_cmd "a line with no cadence is still listed" has_line "due onboard 2026-09-01 (overdue-52d)"
assert_cmd "a future line is not due" lacks "effort-rollup"
assert_cmd "a paused line is skipped" lacks "recap"
assert_cmd "a ticked line is skipped" lacks "stats"
assert_cmd "other sections are skipped" lacks "doctor"

out=$(python3 "$SCRIPT" list --root "$tmp" --date 2026-11-01)
assert_cmd "a line due on the day is due-today" has_line "due effort-rollup 2026-11-01 (due-today)"

# done moves the date by the cadence from the run day and swaps the last-run marker.
out=$(python3 "$SCRIPT" "done" kb-review --root "$tmp" --date 2026-10-23)
assert_cmd "done reports the next due day" has_line "kb-review: next due 2026-10-30"
# shellcheck disable=SC2016 # the backticks are literal characters in the todo line
assert_cmd "done rewrites the line in place" file_has '- [ ] 📅 2026-10-30 — `/nase:kb-review` — Weekly KB hygiene (every 7d) (last run 2026-10-23)'

# The /nase: prefix is accepted, a workspace skill keeps its `--` separator, and a rerun
# on the same day changes nothing.
out=$(python3 "$SCRIPT" "done" /nase:workspace:optimize-skills-from-lessons --root "$tmp" --date 2026-10-23)
assert_cmd "a prefixed name is accepted" has_line "workspace:optimize-skills-from-lessons: next due 2026-11-06"
# shellcheck disable=SC2016 # the backticks are literal characters in the todo line
assert_cmd "the separator and missing sign are kept" file_has '- [ ] 2026-11-06 -- `/nase:workspace:optimize-skills-from-lessons` -- Apply lessons (every 14d) (last run 2026-10-23)'
before=$(cksum < "$todo")
python3 "$SCRIPT" "done" kb-review --root "$tmp" --date 2026-10-23 >/dev/null
assert_cmd "a same-day rerun is idempotent" test "$before" = "$(cksum < "$todo")"

# No cadence: refuse, change nothing, exit 3.
before=$(cksum < "$todo")
err=$(python3 "$SCRIPT" "done" onboard --root "$tmp" --date 2026-10-23 2>&1 >/dev/null)
rc=$?
assert_cmd "a line with no cadence exits 3" test "$rc" -eq 3
assert_cmd "the refusal names the missing cadence" grep -qF "no (every Nd) cadence" <<< "$err"
assert_cmd "the refused line is untouched" test "$before" = "$(cksum < "$todo")"

# Skills with no line, paused lines, and lines outside the section are not touched.
before=$(cksum < "$todo")
out=$(python3 "$SCRIPT" "done" doctor --root "$tmp" --date 2026-10-23); rc=$?
assert_cmd "a skill with no line exits 0" test "$rc" -eq 0
assert_cmd "a skill with no line says so" has_line "doctor: no schedule line, nothing to update"
python3 "$SCRIPT" "done" recap --root "$tmp" --date 2026-10-23 >/dev/null
python3 "$SCRIPT" "done" stats --root "$tmp" --date 2026-10-23 >/dev/null
assert_cmd "paused, ticked, and other-section lines are untouched" test "$before" = "$(cksum < "$todo")"

# A missing file reads as nothing scheduled, for both commands.
out=$(python3 "$SCRIPT" list --root "$tmp/nowhere" --date 2026-10-23)
assert_cmd "list on a missing file is empty" has_line "scheduled=0 due=0"
python3 "$SCRIPT" "done" kb-review --root "$tmp/nowhere" --date 2026-10-23 >/dev/null
assert_cmd "done on a missing file exits 0 and creates nothing" test "$?" -eq 0 -a ! -e "$tmp/nowhere"

# A bad date is a usage error.
python3 "$SCRIPT" list --root "$tmp" --date not-a-date >/dev/null 2>&1
assert_cmd "invalid --date exits non-zero" test "$?" -ne 0

# The edit keeps the file's mode and trailing newline.
assert_cmd "the file still ends with a newline" test -z "$(tail -c1 "$todo")"

[ "$failures" -eq 0 ] && printf '\nmaintenance-schedule tests passed.\n'
