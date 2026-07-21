#!/usr/bin/env bash
# Regression tests for tests/check-skill-overlap.sh.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

GUARD="tests/check-skill-overlap.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; failures=$((failures + 1)); }

mkskill() {
  # mkskill <path> <description>
  mkdir -p "$(dirname "$1")"
  printf -- '---\nname: %s\ndescription: %s\n---\n\nbody\n' "$(basename "$1" .md)" "$2" > "$1"
}

# 1. Full-corpus audit passes on the real skill set (no clones today).
if bash "$GUARD" >/dev/null 2>&1; then
  pass "audit passes on real corpus"
else
  fail "audit passes on real corpus"
fi

# 2. A near-duplicate description produces an advisory warning.
#    Clone the discuss-pr trigger surface almost verbatim.
clone="$TMP/discuss-pr-2.md"
mkskill "$clone" "Deeply review a PR and draft evidence-backed inline findings. Use for analyze PR, review PR, self-review, or a PR URL; use address-comments for existing feedback."
out=$(bash "$GUARD" "$clone" 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "WARNING" <<<"$out"; then
  pass "near-duplicate description warns"
else
  printf '%s\n' "$out" >&2
  fail "near-duplicate description warns [rc=$rc]"
fi

# 3. Reordering the same trigger surface still produces a warning.
reordered="$TMP/discuss-pr-reordered.md"
mkskill "$reordered" "Inspect pull requests for correctness and prepare inline comments. Use for self-review, a PR URL, analyze PR, or review PR; choose address-comments when feedback already exists."
out=$(bash "$GUARD" "$reordered" 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "WARNING" <<<"$out"; then
  pass "reordered trigger clone warns"
else
  printf '%s\n' "$out" >&2
  fail "reordered trigger clone warns [rc=$rc]"
fi

# 4. A block-scalar description is parsed and produces a warning.
block_clone="$TMP/discuss-pr-block.md"
printf -- '%s\n' \
  '---' \
  'name: discuss-pr-block' \
  'description: >' \
  '  Deeply review a PR and draft evidence-backed inline findings.' \
  '  Use for analyze PR, review PR, self-review, or a PR URL;' \
  '  use address-comments for existing feedback.' \
  '---' \
  '' \
  'body' > "$block_clone"
out=$(bash "$GUARD" "$block_clone" 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "WARNING" <<<"$out"; then
  pass "block-scalar trigger clone warns"
else
  printf '%s\n' "$out" >&2
  fail "block-scalar trigger clone warns [rc=$rc]"
fi

# 5. A genuinely distinct new skill PASSes (exit 0) against the corpus.
distinct="$TMP/render-latex-diagrams.md"
mkskill "$distinct" "Render LaTeX math expressions into standalone SVG diagrams. Use for typeset equation, math to image, or export formula graphic."
out=$(bash "$GUARD" "$distinct" 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "PASSED" <<<"$out" && ! grep -q "WARNING" <<<"$out"; then
  pass "distinct new skill passes (exit 0)"
else
  printf '%s\n' "$out" >&2
  fail "distinct new skill passes (exit 0) [rc=$rc]"
fi

# 6. A file without description frontmatter is skipped, not crashed.
nodesc="$TMP/no-desc.md"
printf -- '---\nname: no-desc\n---\nbody\n' > "$nodesc"
out=$(bash "$GUARD" "$nodesc" 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "no description" <<<"$out"; then
  pass "file without description is skipped"
else
  printf '%s\n' "$out" >&2
  fail "file without description is skipped [rc=$rc]"
fi

if [[ "$failures" -eq 0 ]]; then
  printf '\nskill-overlap tests passed.\n'
  exit 0
fi
printf '\n%d skill-overlap assertion(s) failed.\n' "$failures" >&2
exit 1
