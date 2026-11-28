#!/usr/bin/env bash
# Regression tests for .claude/scripts/nase_config.py, the one reader of
# workspace/config.md. The matrix pins each parse rule once, so the six callers
# cannot drift apart again.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/nase_config.py"
# shellcheck source=/dev/null
. "$ROOT/tests/lib/assert.sh"

failures=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/nase-config-test-XXXXXXXX")
trap 'rm -rf "$TMP"' EXIT

# --- parse matrix (pure, no files) ---------------------------------------
matrix_out=$(NASE_SCRIPT_DIR="$ROOT/.claude/scripts" python3 - <<'PY'
import os
import sys
import time

sys.path.insert(0, os.environ["NASE_SCRIPT_DIR"])
import nase_config as nc

BOM = "\ufeff"
CASES = [
    # name, text, key, section, status, value-or-reason
    ("simple top-level key", "a: 1\n", "a", None, "found", "1"),
    ("identical duplicate is still found", "a: 1\na: 1\n", "a", None, "found", "1"),
    ("conflicting duplicate is ambiguous", "a: 1\na: 2\n", "a", None, "ambiguous", "conflicting-values"),
    ("duplicates differing only in case conflict", "a: Auto\na: auto\n", "a", None, "ambiguous", "conflicting-values"),
    ("double quotes stripped", 'a: "x y"\n', "a", None, "found", "x y"),
    ("single quotes stripped", "a: 'x'\n", "a", None, "found", "x"),
    ("mismatched quotes kept", "a: \"x'\n", "a", None, "found", "\"x'"),
    ("quotes stripped before comparing", 'a: "x"\na: x\n', "a", None, "found", "x"),
    ("quoted empty value is empty", 'a: ""\n', "a", None, "absent", "empty-value"),
    ("empty value", "a:\n", "a", None, "absent", "empty-value"),
    ("empty value never reads the next line", "github_org:\ngh_account: x\n", "github_org", None, "absent", "empty-value"),
    ("next key after an empty value still found", "github_org:\ngh_account: x\n", "gh_account", None, "found", "x"),
    ("empty duplicate ignored beside a value", "a:\na: 1\n", "a", None, "found", "1"),
    ("BOM before first key", BOM + "a: 1\n", "a", None, "found", "1"),
    ("BOM before first heading", BOM + "## Autonomy\nlevel: auto\n", "level", "Autonomy", "found", "auto"),
    ("CRLF line endings", "a: 1\r\nb: 2\r\n", "b", None, "found", "2"),
    ("lone CR inside a value kept", "a: x\ry\n", "a", None, "found", "x\ry"),
    ("U+2028 inside a value kept", "a: x\u2028y\n", "a", None, "found", "x\u2028y"),
    ("hash line is plain text, not a heading", "## S\n# note\na: 1\n", "a", "S", "found", "1"),
    ("triple hash does not end a section", "## S\n### sub\na: 1\n", "a", "S", "found", "1"),
    ("bare double hash is not a heading", "##\n## \na: 1\n", "a", None, "found", "1"),
    ("no space after double hash is not a heading", "##x\na: 1\n", "a", None, "found", "1"),
    ("HTML comment hides a key", "<!--\na: 1\n-->\n", "a", None, "absent", "no-key"),
    ("HTML comment inside a value is removed", "a: 1 <!-- x -->\n", "a", None, "found", "1"),
    ("fenced code hides a key", "```\na: 1\n```\n", "a", None, "absent", "no-key"),
    ("closed comment and fence still found", "<!-- c -->\n```\nx: 1\n```\na: 2\n", "a", None, "found", "2"),
    ("unclosed comment is ambiguous for every key", "a: 1\n<!-- open\nb: 2\n", "a", None, "ambiguous", "unterminated-block"),
    ("unclosed fence is ambiguous for every key", "a: 1\n```\nb: 2\n", "a", None, "ambiguous", "unterminated-block"),
    ("tilde line does not close a backtick fence", "```\n~~~\na: 1\n", "a", None, "ambiguous", "unterminated-block"),
    ("unclosed comment inside a fence", "```\n<!--\n```\na: 1\n", "a", None, "ambiguous", "unterminated-block"),
    ("top-level key requested in a section is misplaced", "a: 1\n## S\nb: 2\n", "a", "S", "absent", "misplaced"),
    ("section key requested at top level is misplaced", "## S\na: 1\n", "a", None, "absent", "misplaced"),
    ("misplaced even when the section is missing", "a: 1\n", "a", "S", "absent", "misplaced"),
    ("empty entry here and value elsewhere is misplaced", "a: 1\n## S\na:\n", "a", "S", "absent", "misplaced"),
    ("missing section", "a: 1\n## T\nb: 2\n", "zzz", "S", "absent", "no-section"),
    ("duplicate heading is ambiguous", "## S\na: 1\n## S\nb: 2\n", "a", "S", "ambiguous", "duplicate-section"),
    ("section keys do not leak between sections", "## S\na: 1\n## T\na: 2\n", "a", "T", "found", "2"),
    ("absent key", "a: 1\n", "b", None, "absent", "no-key"),
    ("indented key never matches", "  a: 1\n", "a", None, "absent", "no-key"),
    ("dash bullet key", "- a: 1\n", "a", None, "found", "1"),
    ("star bullet key", "* a: 1\n", "a", None, "found", "1"),
    ("key containing a space", "AI engineer: Velyx\n", "AI engineer", None, "found", "Velyx"),
    ("space before the colon", "a : 1\n", "a", None, "found", "1"),
    ("key match is case-sensitive", "A: 1\n", "a", None, "absent", "no-key"),
    ("URL value keeps colon and hash", "baseUrl: https://x.example/a#b\n", "baseUrl", None, "found", "https://x.example/a#b"),
    ("trailing hash text stays in the value", "level: auto # x\n", "level", None, "found", "auto # x"),
    ("line without a colon is not an entry", "just text\n", "just text", None, "absent", "no-key"),
    ("empty file", "", "a", None, "absent", "no-key"),
]

failures = 0
for name, text, key, section, status, expect in CASES:
    got = nc.parse(text).get(key, section)
    want_value = expect if status == "found" else ""
    want_reason = "" if status == "found" else expect
    if (got.status, got.value, got.reason) == (status, want_value, want_reason):
        print(f"PASS  matrix: {name}")
    else:
        failures += 1
        print(f"FAIL  matrix: {name} (got {got}, want {status} {expect!r})")

long_line = "a" + " " * 100000
start = time.monotonic()
got = nc.parse(long_line + "\n").get("a")
elapsed = time.monotonic() - start
if got.status == "absent" and elapsed < 2:
    print("PASS  matrix: 100000-character line parses in linear time")
else:
    failures += 1
    print(f"FAIL  matrix: 100000-character line (got {got}, {elapsed:.2f}s)")

start = time.monotonic()
got = nc.parse("a" + ":" * 100000 + "\n").get("a")
if got.status == "found" and time.monotonic() - start < 2:
    print("PASS  matrix: 100000-colon line parses in linear time")
else:
    failures += 1
    print(f"FAIL  matrix: 100000-colon line (got {got})")

sys.exit(1 if failures else 0)
PY
)
matrix_rc=$?
while IFS= read -r line; do
  case "$line" in
    "PASS  "*) pass "${line#PASS  }" ;;
    "FAIL  "*) fail "${line#FAIL  }" ;;
  esac
done <<<"$matrix_out"
if [ "$matrix_rc" != "0" ] && ! grep -q '^FAIL' <<<"$matrix_out"; then
  fail "matrix: python crashed (exit $matrix_rc)"
fi
matrix_count=$(grep -c '^PASS  matrix:' <<<"$matrix_out")
if [ "$matrix_count" -ge 25 ]; then pass "matrix has at least 25 passing cases ($matrix_count)"; else fail "matrix has at least 25 passing cases (got $matrix_count)"; fi

# --- CLI: exit codes, streams, and file reads ----------------------------
cli() {
  python3 "$SCRIPT" get --root "$TMP" "$@"
}

write_config() {
  mkdir -p "$TMP/workspace"
  printf '%b' "$1" > "$TMP/workspace/config.md"
}

expect_cli() {
  local name="$1" want_rc="$2" want_err="$3"
  shift 3
  local err rc
  err=$(cli "$@" 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" = "$want_rc" ] && [ "$err" = "$want_err" ]; then
    pass "$name"
  else
    fail "$name (exit $rc, stderr '$err', want exit $want_rc, stderr '$want_err')"
  fi
}

rm -rf "$TMP/workspace"
expect_cli "cli: missing file is unavailable" 5 "unavailable: no-file" a

write_config 'github_org:\ngh_account: x\n'
expect_cli "cli: empty github_org followed by gh_account is absent" 3 "absent: empty-value" github_org
out=$(cli gh_account)
rc=$?
if [ "$rc" = "0" ] && [ "$out" = "x" ]; then pass "cli: next key still found after an empty value"; else fail "cli: next key still found (exit $rc, out '$out')"; fi

write_config 'a: 1\n## S\nb: 2\n'
expect_cli "cli: misplaced exits 6" 6 "absent: misplaced" --section S a
expect_cli "cli: absent exits 3" 3 "absent: no-key" zzz
expect_cli "cli: no-section exits 3" 3 "absent: no-section" --section Nope zzz

write_config 'a: 1\na: 2\n'
expect_cli "cli: conflicting values exit 4" 4 "ambiguous: conflicting-values" a

write_config 'a: 1\n<!-- open\n'
expect_cli "cli: unterminated block exits 4" 4 "ambiguous: unterminated-block" a

printf 'a: \377\n' > "$TMP/workspace/config.md"
expect_cli "cli: invalid UTF-8 is unavailable" 5 "unavailable: undecodable" a

rm -f "$TMP/workspace/config.md"
mkdir "$TMP/workspace/config.md"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) dir_read_error=PermissionError ;;
  *) dir_read_error=IsADirectoryError ;;
esac
expect_cli "cli: unreadable file names the exception" 5 "unavailable: unreadable:$dir_read_error" a
rmdir "$TMP/workspace/config.md"

write_config 'a: x\\ty\n'
out=$(cli a)
if [ "$out" = 'x\ty' ]; then pass "cli: backslash escapes stay literal"; else fail "cli: backslash escapes stay literal (got '$out')"; fi

write_config 'a: caf\303\251\r\n'
cli a > "$TMP/out.bin"
bytes=$(od -An -tx1 "$TMP/out.bin" | tr -s ' \n' ' ' | sed 's/^ //; s/ $//')
if [ "$bytes" = "63 61 66 c3 a9 0a" ]; then
  pass "cli: value is UTF-8 bytes plus one LF, no CR"
else
  fail "cli: value is UTF-8 bytes plus one LF, no CR (got $bytes)"
fi

python3 "$SCRIPT" >/dev/null 2>&1
rc=$?
if [ "$rc" = "2" ]; then pass "cli: no subcommand is a usage error"; else fail "cli: no subcommand is a usage error (exit $rc)"; fi
python3 "$SCRIPT" get --root "$TMP" >/dev/null 2>&1
rc=$?
if [ "$rc" = "2" ]; then pass "cli: missing key is a usage error"; else fail "cli: missing key is a usage error (exit $rc)"; fi

# --- no caller keeps a private parser -------------------------------------
private_parser_hits() {
  grep -cF -- "$2" "$1" || true
}

printf 'x = re.search(rf"(?m)^{re.escape(key)}:", text)\n' > "$TMP/probe.py"
if [ "$(private_parser_hits "$TMP/probe.py" 're.search(rf"(?m)^{re.escape(key)}')" = "1" ]; then
  pass "guard: a private parser in a file is counted"
else
  fail "guard: a private parser in a file is counted"
fi

# Each pair is a caller file and a fixed string that only its old parser held.
while IFS='|' read -r file needle; do
  hits=$(private_parser_hits "$ROOT/$file" "$needle")
  if [ "$hits" = "0" ]; then
    pass "guard: $file holds no private config parser"
  else
    fail "guard: $file still holds a private config parser ($hits hit(s) for '$needle')"
  fi
done <<'PAIRS'
.claude/scripts/external_write/account.py|re.search(rf"(?m)^{re.escape(key)}
.claude/scripts/autonomy-policy.py|LEVEL_RE
.claude/scripts/effort-rollup-evidence.py|def config_values
.claude/scripts/confluence-publish.py|baseUrl:\s*
.claude/hooks/session-start.sh|in_language
.claude/hooks/stop-backup.sh|s/^backup_
PAIRS

# --- the real workspace file ----------------------------------------------
if [ -f "$ROOT/workspace/config.md" ]; then
  python3 "$SCRIPT" get --root "$ROOT" --section Autonomy level >/dev/null 2>&1
  rc=$?
  if [ "$rc" = "0" ] || [ "$rc" = "3" ]; then pass "real config: Autonomy level reads without ambiguity"; else fail "real config: Autonomy level (exit $rc)"; fi
fi

if [ "$failures" -gt 0 ]; then
  printf '\n%d check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nAll nase-config checks passed.\n'
