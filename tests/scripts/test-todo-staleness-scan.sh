#!/usr/bin/env bash
# Regression tests for .claude/scripts/todo-staleness-scan.py
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/todo-staleness-scan.py"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# shellcheck source=/dev/null
. "$ROOT/tests/lib/assert.sh"
failures=0

mkdir -p "$tmp/workspace/tasks"

# Items: 1 no marker, 2 stale, 3 fresh, 4 parked and not due, 5 parked and past its recheck
# date, 6 parked with no recheck and old, 7 ticked, 8 multi-line whose later marker wins,
# 9 and 10 either side of the 3-day default, 11 parked with no recheck and recent, 12 parked
# with no recheck at exactly 14 days, written with the bare pause sign (no variation selector),
# 13 parked with a passed recheck date and a fresh verified marker, which the scan ignores.
# Sections around Independent, and a heading that only starts like it, must never be counted.
{
  cat <<'MD'
# Tasks

## Effort-backed

- [ ] **Not counted** (verified 2020-01-01)

## Independent (no effort doc)

- [ ] **No marker** - nothing says when this was checked
- [ ] **Stale** - checked a while ago (verified 2026-10-01)
- [ ] **Fresh** - checked yesterday (verified 2026-10-09)
- [ ] ⏸️ **Parked quiet** - waiting (verified 2026-10-01) (recheck 2026-10-24)
- [ ] ⏸️ **Parked due** - waiting (verified 2026-10-01) (recheck 2026-10-10)
- [ ] ⏸️ **Parked old** - no recheck date (verified 2026-09-20)
- [x] **Ticked** - done
- [ ] **Multi-line** first line (verified 2026-10-08)
  continues here and a later (verified 2026-10-10) marker wins
- [ ] **Edge fresh** - three days old (verified 2026-10-07)
- [ ] **Edge due** - four days old (verified 2026-10-06)
- [ ] ⏸️ **Parked recent** - no recheck date (verified 2026-10-05)
MD
  printf -- '- [ ] \xe2\x8f\xb8 **Parked limit** - bare pause sign (verified 2026-09-26)\n'
  cat <<'MD'
- [ ] ⏸️ **Parked stamped** - recheck passed (verified 2026-10-10) (recheck 2026-10-01)

# Appendix

- [ ] **After H1**

## Independent-ish

- [ ] **Wrong section**

## Scheduled Maintenance

- [ ] **Not counted either**
MD
} > "$tmp/workspace/tasks/todo.md"

has_line() { grep -qxF -- "$1" <<< "$out"; }
lacks() { ! grep -qF -- "$1" <<< "$out"; }

out=$(python3 "$SCRIPT" --root "$tmp" --date 2026-10-10)
assert_cmd "counts per state" has_line "independent=13 due=6 fresh=3 parked=3 checked=1"
assert_cmd "item without a marker is due" has_line "due 1 No marker (no-verified-marker)"
assert_cmd "item past the max age is due" has_line "due 2 Stale (age-9d)"
assert_cmd "parked item on its recheck date is due" has_line "due 5 Parked due (recheck-due)"
assert_cmd "a fresh verified marker does not reset a passed recheck date" has_line "due 13 Parked stamped (recheck-due)"
assert_cmd "parked item with no recheck date ages out" has_line "due 6 Parked old (parked-age-20d)"
assert_cmd "an item exactly at the max age is not due" lacks "Edge fresh"
assert_cmd "an item one day past the max age is due" has_line "due 10 Edge due (age-4d)"
assert_cmd "fresh item is not listed" lacks "Fresh"
assert_cmd "recent parked item with no recheck date is not listed" lacks "Parked recent"
assert_cmd "parked item exactly at 14 days is not listed" lacks "Parked limit"
assert_cmd "parked item before its recheck date is not listed" lacks "Parked quiet"
assert_cmd "ticked item is not listed" lacks "Ticked"
assert_cmd "other sections are not counted" lacks "Not counted"
assert_cmd "a heading level 1 ends the section" lacks "After H1"
assert_cmd "a heading that only starts like the section is not counted" lacks "Wrong section"

# --max-age moves the line between fresh and due: the item checked 1 day ago is fresh at 3
# and due at 0. The multi-line item reads its later marker (age 0), so it stays fresh at 1.
out=$(python3 "$SCRIPT" --root "$tmp" --date 2026-10-10 --max-age 0)
assert_cmd "--max-age 0 makes a 1-day-old item due" has_line "due 3 Fresh (age-1d)"
out=$(python3 "$SCRIPT" --root "$tmp" --date 2026-10-10 --max-age 1)
assert_cmd "--max-age 1 counts" has_line "independent=13 due=7 fresh=2 parked=3 checked=1"
assert_cmd "the latest verified marker wins" lacks "Multi-line"

# A bare heading, a level 3 sub-heading inside the section, an uppercase X, a tab-indented
# continuation, and a parked item one day past the 14-day limit.
mkdir -p "$tmp/second/workspace/tasks"
{
  cat <<'MD'
## Independent

### Sub group

- [X] **Upper ticked**
- [ ] ⏸️ **Parked fifteen** - no recheck date (verified 2026-09-25)
- [ ] **Tabbed** first line (verified 2026-10-01)
MD
  printf '\tcontinues after a tab with a later (verified 2026-10-10) marker\n'
  cat <<'MD'
- [ ] **Typo date** - (verified 2026-13-45)
- [ ] ⏸️ **Two rechecks** - (recheck 2026-10-01) (recheck 2026-10-24)
- [ ] **Unindented** - (verified 2026-10-01)
a prose line, not indented, with a (verified 2026-10-10) marker that belongs to nothing
- [ ] no bold title on this item, so the title falls back to the first eighty characters of the body, which is long
- [ ] ⏸️ **Parked bare** - nothing
- [ ] **Stray recheck** - (verified 2026-10-09) (recheck 2026-10-01)
- [ ] **Order** - (verified 2026-10-10) then an older (verified 2026-10-01)
- [ ] **Two** spans **here** - nothing
MD
} > "$tmp/second/workspace/tasks/todo.md"
out=$(python3 "$SCRIPT" --root "$tmp/second" --date 2026-10-10)
assert_cmd "bare heading, sub-heading, X, tab continuation, and the rest" has_line "independent=11 due=6 fresh=3 parked=1 checked=1"
assert_cmd "parked item at 15 days is due" has_line "due 2 Parked fifteen (parked-age-15d)"
assert_cmd "an invalid date reads as no marker" has_line "due 4 Typo date (no-verified-marker)"
assert_cmd "the latest recheck mark wins" lacks "Two rechecks"
assert_cmd "an unindented line does not extend the item above it" has_line "due 6 Unindented (age-9d)"
assert_cmd "a parked item with no markers is due" has_line "due 8 Parked bare (no-verified-marker)"
assert_cmd "a recheck mark on an open item is ignored" lacks "Stray recheck"
assert_cmd "the newest verified marker wins wherever it sits" lacks "Order"
assert_cmd "the title is the first bold span" has_line "due 11 Two (no-verified-marker)"
assert_cmd "an item with no bold title uses its first 80 characters" has_line "due 7 no bold title on this item, so the title falls back to the first eighty characte (no-verified-marker)"

# With no --date the scan uses the local day, as /nase:today runs it. A far-future stamp
# clamps to age 0, so the item is fresh on any real day.
mkdir -p "$tmp/third/workspace/tasks"
printf '## Independent\n\n- [ ] **Future** - (verified 9999-12-30)\n' > "$tmp/third/workspace/tasks/todo.md"
out=$(python3 "$SCRIPT" --root "$tmp/third")
assert_cmd "the default date is the local day" has_line "independent=1 due=0 fresh=1 parked=0 checked=0"

# A missing file or section degrades to zero items and exit 0.
out=$(python3 "$SCRIPT" --root "$tmp/nowhere" --date 2026-10-10)
assert_cmd "missing file reads as zero items" has_line "independent=0 due=0 fresh=0 parked=0 checked=0"

# A bad date is a usage error, not a silent default.
python3 "$SCRIPT" --root "$tmp" --date not-a-date >/dev/null 2>&1
assert_cmd "invalid --date exits non-zero" test "$?" -ne 0

[ "$failures" -eq 0 ] && printf '\ntodo-staleness-scan tests passed.\n'
