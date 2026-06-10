#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

failures=0

pass() {
  printf 'PASS  %s\n' "$1"
}

fail() {
  printf 'FAIL  %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_cmd() {
  local name="$1"
  shift
  if "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
}

workflow=".github/workflows/validate.yml"

unpinned_remote_uses=$(awk '
  /uses:[[:space:]]*/ {
    line = $0
    sub(/#.*/, "", line)
    sub(/.*uses:[[:space:]]*/, "", line)
    gsub(/["'\''"]/, "", line)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
    if (line ~ /^\.\/|^docker:\/\//) {
      next
    }
    if (line !~ /@[0-9a-f]{40}$/) {
      print line
    }
  }
' "$workflow")

if [ -z "$unpinned_remote_uses" ]; then
  pass "remote GitHub Actions are pinned to full SHAs"
else
  fail "remote GitHub Actions are pinned to full SHAs"
  printf '%s\n' "$unpinned_remote_uses" >&2
fi

assert_cmd "CI installs actionlint" grep -q 'github.com/rhysd/actionlint/cmd/actionlint@' "$workflow"
assert_cmd "local gate runs actionlint" grep -q 'GitHub Actions lint' tests/check-all.sh

if [[ "$failures" -eq 0 ]]; then
  printf '\ngithub-actions-hardening tests passed.\n'
  exit 0
fi

printf '\n%d github-actions-hardening assertion(s) failed.\n' "$failures" >&2
exit 1
