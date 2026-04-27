#!/usr/bin/env bash
# Run all local validation gates that mirror CI (`.github/workflows/validate.yml`).
#
# Run from repo root:  bash tests/check-all.sh
# Exit 0 = all gates pass, exit N = N failed gates.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

failed=0
section() { printf '\n=== %s ===\n' "$1"; }

section "bash syntax (hooks)"
for f in .claude/hooks/*.sh; do
  bash -n "$f" || failed=$((failed+1))
done

section "shellcheck (hooks)"
shellcheck -S warning .claude/hooks/*.sh || failed=$((failed+1))

section "JSON (settings.json)"
python3 -m json.tool .claude/settings.json >/dev/null || failed=$((failed+1))

section "hook regression tests"
bash tests/hooks/test-block-dangerous-git.sh || failed=$((failed+1))

section "shared-doc reference integrity"
bash tests/check-shared-doc-refs.sh || failed=$((failed+1))

if [[ "$failed" -eq 0 ]]; then
  printf '\nAll gates passed.\n'
  exit 0
fi

printf '\n%d gate(s) failed.\n' "$failed" >&2
exit "$failed"
