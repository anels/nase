#!/usr/bin/env bash
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

SCRIPT="$ROOT/.claude/scripts/style-delta-pending.sh"
failures=0
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/tests/lib/platform.sh"

# assert_exit(<name>, <expected rc>, <cmd>...): the shared helper only asserts success.
assert_exit() {
  local name="$1" want="$2" rc=0
  shift 2
  "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then pass "$name"; else fail "$name (exit $rc, want $want)"; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/logs/archive" "$TMP/empty"

cat > "$TMP/logs/2026-10-27.md" <<'EOF'
- 16:21 | wrap-up: journal written; style skipped
- 19:58 | style-delta: [STYLE-DELTA] surface=slack | before="a" -> after="b" | rule=r | confidence=low
- 20:01 | style-delta: [STYLE-DELTA-APPLIED] surface=slack | before="c" -> after="d" | rule=r | confidence=low
- 20:02 | style-delta: [STYLE-DELTA-DISCARDED] surface=slack | before="e" -> after="f" | rule=r | confidence=low
EOF
cat > "$TMP/logs/2026-06-14.md" <<'EOF'
- [STYLE-DELTA] legacy line without a time prefix
EOF
cat > "$TMP/logs/2026-09-01.md" <<'EOF'
- 23:15 | wrap-up: scanned for `[STYLE-DELTA]` lines and found none, style-delta=skipped-no-deltas
EOF
cat > "$TMP/logs/2026-09-13.md" <<'EOF'
- 00:20 (09-14 local) | style-delta: [STYLE-DELTA] surface=slack | before="g" -> after="h" | rule=r | confidence=low
EOF
cat > "$TMP/logs/archive/2026-06-17-full.md" <<'EOF'
- 22:22 | style-delta: [STYLE-DELTA] surface=slack | archived, out of scope
EOF

out="$TMP/out.txt"
bash "$SCRIPT" --logs-dir "$TMP/logs" > "$out"

assert_contains "finds a pending delta in an earlier day's log" "$out" "2026-10-27.md:2:"
assert_contains "finds a legacy line without a time prefix" "$out" "2026-06-14.md:1:"
assert_contains "finds a delta carrying a midnight date note" "$out" "2026-09-13.md:1:"

count=$(grep -c . "$out" || true)
if [ "$count" -eq 3 ]; then
  pass "ignores APPLIED, DISCARDED, prose mentions, and archive"
else
  fail "ignores APPLIED, DISCARDED, prose mentions, and archive (got $count line(s))"
fi

order=$(sed -E 's#^.*/logs/(.*)\.md:[0-9]+:.*#\1#' "$out" | tr '\n' ' ')
if [ "$order" = "2026-06-14 2026-09-13 2026-10-27 " ]; then
  pass "lists the oldest log first"
else
  fail "lists the oldest log first (got: $order)"
fi

assert_exit "explicit missing --logs-dir exits 1" 1 bash "$SCRIPT" --logs-dir "$TMP/not-a-dir"
missing=$(bash "$SCRIPT" --logs-dir "$TMP/not-a-dir" 2>&1 >/dev/null || true)
case "$missing" in
  *"no such directory"*) pass "explicit missing --logs-dir names the path on stderr" ;;
  *) fail "explicit missing --logs-dir names the path on stderr (got: $missing)" ;;
esac

rc=0
default_out=$(cd "$TMP/empty" && bash "$SCRIPT") || rc=$?
if [ "$rc" -eq 0 ]; then pass "missing default logs dir exits 0"; else fail "missing default logs dir exits 0 (exit $rc)"; fi
if [ -z "$default_out" ]; then pass "missing default logs dir prints nothing"; else fail "missing default logs dir prints nothing (got: $default_out)"; fi

assert_exit "an existing empty logs dir exits 0" 0 bash "$SCRIPT" --logs-dir "$TMP/empty"
empty_dir_out=$(bash "$SCRIPT" --logs-dir "$TMP/empty")
if [ -z "$empty_dir_out" ]; then pass "an existing empty logs dir prints nothing"; else fail "an existing empty logs dir prints nothing (got: $empty_dir_out)"; fi

assert_exit "unknown flag exits 1" 1 bash "$SCRIPT" --bogus
assert_exit "--logs-dir without a value exits 1" 1 bash "$SCRIPT" --logs-dir

# A read error must not read as "no deltas". root can read a mode-000 file, so skip there.
mkdir -p "$TMP/locked"
printf -- '- 10:00 | style-delta: [STYLE-DELTA] unreadable\n' > "$TMP/locked/2026-01-01.md"
chmod 000 "$TMP/locked/2026-01-01.md"
if [ "$(id -u)" -eq 0 ]; then
  printf 'SKIP  %s\n' "an unreadable log exits non-zero"
elif ! plat_perms_enforced; then
  # chmod 000 leaves the file readable on NTFS under Git Bash, so there is no unreadable log to test.
  plat_count_skip
  printf 'SKIP  %s\n' "an unreadable log exits non-zero"
else
  assert_exit "an unreadable log exits non-zero" 2 bash "$SCRIPT" --logs-dir "$TMP/locked"
  unreadable=$(bash "$SCRIPT" --logs-dir "$TMP/locked" 2>&1 >/dev/null || true)
  case "$unreadable" in
    *"cannot read"*) pass "an unreadable log names the file on stderr" ;;
    *) fail "an unreadable log names the file on stderr (got: $unreadable)" ;;
  esac
fi
chmod 644 "$TMP/locked/2026-01-01.md"

assert_contains "wrap-up Step 9 calls the script" .claude/commands/nase/wrap-up.md "style-delta-pending.sh"
assert_contains "the shared doc calls the script" .claude/docs/style-delta-capture.md "style-delta-pending.sh"

plat_skip_summary
[ "$failures" -eq 0 ] || exit 1
