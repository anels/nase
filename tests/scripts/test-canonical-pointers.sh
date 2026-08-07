#!/usr/bin/env bash
# Regression tests for tests/check-canonical-pointers.sh.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

GATE=".claude/scripts/check-canonical-pointers.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; failures=$((failures + 1)); }

# Build a fixture repo whose source doc declares the canonical block.
fixture() {
  # fixture <dir> <skill-body>
  local dir="$1" body="$2"
  mkdir -p "$dir/.claude/docs" "$dir/.claude/commands/nase"
  cat > "$dir/.claude/docs/language-config.md" <<'DOC'
# Language Config

## Canonical pointer

<canonical-block name="language-preflight">

Follow `.claude/docs/language-config.md` → Minimum Step 0 block.

</canonical-block>
DOC
  printf -- '---\nname: nase:demo\n---\n\n%s\n' "$body" > "$dir/.claude/commands/nase/demo.md"
}

# 1. The real corpus passes.
if bash tests/check-canonical-pointers.sh >/dev/null 2>&1; then
  pass "real corpus uses the canonical pointer"
else
  fail "real corpus uses the canonical pointer"
fi

# 2. Canonical wording passes, and a leading Step 0 label is allowed.
ok="$TMP/ok"
fixture "$ok" '**Step 0 — Language preflight:** follow `.claude/docs/language-config.md` → Minimum Step 0 block. Severity labels stay English.'
if python3 "$GATE" --root "$ok" >/dev/null 2>&1; then
  pass "labelled canonical pointer passes"
else
  fail "labelled canonical pointer passes"
fi

# 3. A reworded pointer fails with an actionable DRIFT line.
drift="$TMP/drift"
fixture "$drift" 'Run `.claude/docs/language-config.md` first for language behavior.'
out=$(python3 "$GATE" --root "$drift" 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 1 ]] && grep -q "DRIFT" <<<"$out" && grep -q "Minimum Step 0 block" <<<"$out"; then
  pass "reworded pointer fails with the canonical spelling"
else
  printf '%s\n' "$out" >&2
  fail "reworded pointer fails with the canonical spelling [rc=$rc]"
fi

# 4. An inline restatement fails even when the canonical pointer is present.
inline="$TMP/inline"
fixture "$inline" 'Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Read `workspace/config.md` → `## Language` for the `conversation:` value.'
out=$(python3 "$GATE" --root "$inline" 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 1 ]] && grep -q "INLINE" <<<"$out"; then
  pass "inline restatement fails"
else
  printf '%s\n' "$out" >&2
  fail "inline restatement fails [rc=$rc]"
fi

# 5. A source doc without the canonical block fails loudly.
noblock="$TMP/noblock"
fixture "$noblock" 'Follow `.claude/docs/language-config.md` → Minimum Step 0 block.'
printf '# Language Config\n\nNo canonical block here.\n' > "$noblock/.claude/docs/language-config.md"
out=$(python3 "$GATE" --root "$noblock" 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 1 ]] && grep -q "NO_CANONICAL_BLOCK" <<<"$out"; then
  pass "missing canonical block fails"
else
  printf '%s\n' "$out" >&2
  fail "missing canonical block fails [rc=$rc]"
fi

if [[ "$failures" -eq 0 ]]; then
  printf '\nAll canonical-pointer tests passed.\n'
  exit 0
fi
printf '\n%d test(s) failed.\n' "$failures" >&2
exit 1
