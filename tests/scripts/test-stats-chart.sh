#!/usr/bin/env bash
# Regression tests for .claude/scripts/stats-chart.py
#
# /nase:stats prints this straight into chat, so a wrong chart reads as a fact about
# the user's activity rather than a rendering bug. Two properties carry that weight.
# Bucket granularity follows the documented 14-day rule, and a malformed daily.csv
# row is skipped rather than crashing or counting as zero activity on a busy day.
#
# Run from repo root:  bash tests/scripts/test-stats-chart.sh

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

SCRIPT="$ROOT/.claude/scripts/stats-chart.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s%s\n' "$1" "${2:+: $2}" >&2; fail=$((fail + 1)); }

CSV="$TMP/daily.csv"

# Seven consecutive days, so a <= 14 day range must bucket per day.
: > "$CSV"
for i in 0 1 2 3 4 5 6; do
  day=$(python3 -c "import datetime,sys; print((datetime.date(2026,3,2)+datetime.timedelta(days=int(sys.argv[1]))).isoformat())" "$i")
  printf '%s,%s,0,0\n' "$day" "$((i + 1))" >> "$CSV"
done

out=$(python3 "$SCRIPT" --daily-csv "$CSV" --start 2026-03-02 --end 2026-03-08 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then ok "a one-week range renders"; else bad "a one-week range renders" "rc=$rc: $out"; fi

# 2026-03-02 is a Monday, so a per-day chart must carry weekday labels.
if printf '%s' "$out" | grep -q "Mon" && printf '%s' "$out" | grep -q "Sun"; then
  ok "a range of 14 days or fewer buckets per day with weekday labels"
else
  bad "a range of 14 days or fewer buckets per day with weekday labels" "$out"
fi

if printf '%s' "$out" | grep -qE 'W[0-9]+'; then
  bad "a short range is never labelled by ISO week"
else
  ok "a short range is never labelled by ISO week"
fi

# A range over 14 days must switch to per-week buckets.
: > "$CSV"
for i in $(seq 0 29); do
  day=$(python3 -c "import datetime,sys; print((datetime.date(2026,3,2)+datetime.timedelta(days=int(sys.argv[1]))).isoformat())" "$i")
  printf '%s,1,0,0\n' "$day" >> "$CSV"
done

out=$(python3 "$SCRIPT" --daily-csv "$CSV" --start 2026-03-02 --end 2026-03-31 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then ok "a 30-day range renders"; else bad "a 30-day range renders" "rc=$rc: $out"; fi

if printf '%s' "$out" | grep -qE 'W[0-9]+'; then
  ok "a range over 14 days buckets per ISO week"
else
  bad "a range over 14 days buckets per ISO week" "$out"
fi

# --- malformed input is skipped, never crashes and never miscounts ---------

printf '2026-03-02,3,0,0\nnot,a,valid,row\n2026-03-03\n\n2026-03-04,notanumber,0,0\n2026-03-05,4,0,0\n' > "$TMP/messy.csv"
out=$(python3 "$SCRIPT" --daily-csv "$TMP/messy.csv" --start 2026-03-02 --end 2026-03-05 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "malformed rows are skipped rather than crashing"
else
  bad "malformed rows are skipped rather than crashing" "rc=$rc: $out"
fi

# The two well-formed rows must still be represented, or a parse failure has
# quietly become a report of no activity.
if printf '%s' "$out" | grep -q "█"; then
  ok "well-formed rows survive alongside malformed ones"
else
  bad "well-formed rows survive alongside malformed ones" "$out"
fi

# --- an all-zero period renders rather than dividing by zero ---------------

printf '2026-03-02,0,0,0\n2026-03-03,0,0,0\n' > "$TMP/zero.csv"
out=$(python3 "$SCRIPT" --daily-csv "$TMP/zero.csv" --start 2026-03-02 --end 2026-03-03 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "an all-zero period renders without dividing by zero"
else
  bad "an all-zero period renders without dividing by zero" "rc=$rc: $out"
fi

# --- a missing input file fails loudly, not with a blank chart -------------

if python3 "$SCRIPT" --daily-csv "$TMP/does-not-exist.csv" \
  --start 2026-03-02 --end 2026-03-03 >/dev/null 2>&1; then
  bad "a missing daily.csv exits non-zero instead of printing an empty chart"
else
  ok "a missing daily.csv exits non-zero instead of printing an empty chart"
fi

printf '\n--- %s pass, %s fail ---\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
