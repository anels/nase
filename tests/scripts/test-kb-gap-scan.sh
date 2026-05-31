#!/usr/bin/env bash
# test-kb-gap-scan.sh — regression tests for .claude/scripts/kb-gap-scan.sh
#
# Run from repo root: bash tests/scripts/test-kb-gap-scan.sh
# Exit 0 = all pass; non-zero = first failed assertion's status.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

SCRIPT=".claude/scripts/kb-gap-scan.sh"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/logs" "$FIXTURE/tasks"

# In-range hit on uncertainty + sme_teach
cat > "$FIXTURE/logs/2026-05-01.md" <<'EOF'
# Work Log — 2026-05-01

- 10:00 | debug: 不确定 EF Core 的 OrderBy 是否必须先于 Skip
- 11:30 | learn: Rajesh 告诉我 OrderBy must precede Skip in EF queries
- 13:00 | trivial: nothing to flag here
EOF

# In-range hit on lookup + first_time + post_error
cat > "$FIXTURE/logs/2026-05-02.md" <<'EOF'
# Work Log — 2026-05-02

- 09:00 | first time touching the React 18 concurrent mode
- 10:00 | looked up the docs for createRoot signature
- 14:00 | turns out the issue was StrictMode double-invoking effects (root cause: dev-only behavior)
EOF

# Out-of-range — must be excluded
cat > "$FIXTURE/logs/2026-04-01.md" <<'EOF'
# Work Log — 2026-04-01

- 不确定 this should not appear in the output (out of range)
EOF

# Repo-filter probe — only this file mentions "Insights-Monitoring"
cat > "$FIXTURE/logs/2026-05-03.md" <<'EOF'
# Work Log — 2026-05-03

- 10:00 | Insights-Monitoring: 不清楚 sampling override on TelemetryClient
EOF

cat > "$FIXTURE/tasks/lessons.md" <<'EOF'
# Lessons Learned

## code -- 2026-05-01 -- in-range literal lesson
**When:** Insights-Monitoring deploy
**Do:** not sure whether the owner field is populated before alert render.

## code -- 2026-04-01 -- old literal lesson
**When:** Insights-Monitoring deploy
**Do:** not sure this old lesson should not appear for a May-only scan.
EOF

pass=0
fail=0

assert_contains() {
  local desc="$1" actual="$2" needle="$3"
  if printf '%s' "$actual" | grep -qF "$needle"; then
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n  expected to contain: %s\n  actual: %s\n' "$desc" "$needle" "$actual" >&2
  fi
}

assert_not_contains() {
  local desc="$1" actual="$2" needle="$3"
  if printf '%s' "$actual" | grep -qF "$needle"; then
    fail=$((fail + 1))
    printf 'FAIL  %s\n  expected NOT to contain: %s\n  actual: %s\n' "$desc" "$needle" "$actual" >&2
  else
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$desc"
  fi
}

assert_exit() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    pass=$((pass + 1))
    printf 'PASS  %s (exit=%s)\n' "$desc" "$actual"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s (expected exit=%s, got %s)\n' "$desc" "$expected" "$actual" >&2
  fi
}

# ── Test 1: in-range hits across multiple marker types ───────────────────────
out=$(bash "$SCRIPT" --logs-dir "$FIXTURE/logs" --no-lessons \
  --since 2026-05-01 --until 2026-05-02 2>&1)
rc=$?
assert_exit "T1: exit 0 when hits found" 0 "$rc"
assert_contains "T1: uncertainty hit on day 1"  "$out" $'uncertainty\t'"$FIXTURE/logs/2026-05-01.md"
assert_contains "T1: sme_teach hit on day 1"    "$out" $'sme_teach\t'"$FIXTURE/logs/2026-05-01.md"
assert_contains "T1: lookup hit on day 2"       "$out" $'lookup\t'"$FIXTURE/logs/2026-05-02.md"
assert_contains "T1: first_time hit on day 2"   "$out" $'first_time\t'"$FIXTURE/logs/2026-05-02.md"
assert_contains "T1: post_error hit on day 2"   "$out" $'post_error\t'"$FIXTURE/logs/2026-05-02.md"
assert_not_contains "T1: out-of-range file excluded" "$out" "2026-04-01.md"

# ── Test 2: empty range produces exit 2 ──────────────────────────────────────
out=$(bash "$SCRIPT" --logs-dir "$FIXTURE/logs" --no-lessons \
  --since 2026-06-01 --until 2026-06-30 2>&1)
rc=$?
assert_exit "T2: exit 2 when no logs in range" 2 "$rc"

# ── Test 3: --repo filter restricts to matching files ────────────────────────
out=$(bash "$SCRIPT" --logs-dir "$FIXTURE/logs" --no-lessons \
  --since 2026-05-01 --until 2026-05-03 --repo "Insights-Monitoring" 2>&1)
rc=$?
assert_exit "T3: exit 0 with repo filter match" 0 "$rc"
assert_contains "T3: matching file kept"           "$out" "2026-05-03.md"
assert_not_contains "T3: non-matching day-1 file dropped" "$out" "2026-05-01.md"
assert_not_contains "T3: non-matching day-2 file dropped" "$out" "2026-05-02.md"

# ── Test 4: bad arg → exit 1 ─────────────────────────────────────────────────
out=$(bash "$SCRIPT" --bogus-flag 2>&1)
rc=$?
assert_exit "T4: unknown arg exits 1" 1 "$rc"

# ── Test 5: non-existent logs dir → exit 2 ───────────────────────────────────
out=$(bash "$SCRIPT" --logs-dir "$FIXTURE/does-not-exist" --no-lessons 2>&1)
rc=$?
assert_exit "T5: missing logs dir exits 2" 2 "$rc"

# ── Test 6: lessons are filtered by section date, not file presence ──────────
out=$(bash "$SCRIPT" --logs-dir "$FIXTURE/logs" --lessons "$FIXTURE/tasks/lessons.md" \
  --since 2026-05-01 --until 2026-05-01 2>&1)
rc=$?
assert_exit "T6: lessons scan exits 0" 0 "$rc"
assert_contains "T6: in-range lesson kept" "$out" "owner field is populated"
assert_not_contains "T6: old lesson excluded" "$out" "old lesson should not appear"

# ── Test 7: --repo is applied per lesson section, not whole file ─────────────
out=$(bash "$SCRIPT" --logs-dir "$FIXTURE/logs" --lessons "$FIXTURE/tasks/lessons.md" \
  --since 2026-05-01 --until 2026-05-01 --repo "Insights-Monitoring" 2>&1)
rc=$?
assert_exit "T7: repo-filtered lessons scan exits 0" 0 "$rc"
assert_contains "T7: matching lesson section kept" "$out" "owner field is populated"
assert_not_contains "T7: old repo mention does not keep old lesson" "$out" "old lesson should not appear"

# ── Test 8: value-taking flags fail cleanly when missing values ──────────────
out=$(bash "$SCRIPT" --logs-dir "$FIXTURE/logs" --since 2>&1)
rc=$?
assert_exit "T8: missing --since value exits 1" 1 "$rc"
assert_contains "T8: missing --since value warns" "$out" "requires a value"

# ── summary ──────────────────────────────────────────────────────────────────
total=$((pass + fail))
printf '\n%d/%d assertions passed\n' "$pass" "$total"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
