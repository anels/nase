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

assert_contains() {
  local name="$1"
  local file="$2"
  local pattern="$3"
  if grep -Fq -- "$pattern" "$file"; then
    pass "$name"
  else
    fail "$name"
  fi
}

assert_contains "fsd has post-edit tool gate" \
  ".claude/commands/nase/fsd.md" \
  "Phase 5.25: Optional Post-Edit CLI Gates"

assert_contains "address-comments has post-edit tool gate" \
  ".claude/commands/nase/address-comments.md" \
  "Phase 7.25: Optional Post-Edit CLI Gates"

assert_contains "onboard probes baseline tools" \
  ".claude/commands/nase/onboard.md" \
  "tool-availability.py --group baseline --group repo --group ci --format json"

assert_contains "onboard keeps machine availability out of KB" \
  ".claude/commands/nase/onboard.md" \
  "never write this machine-local availability into the repo KB"

assert_contains "tech-debt-audit has scanner seed pass" \
  ".claude/commands/nase/tech-debt-audit.md" \
  "Optional scanner seed pass"

assert_contains "tech-debt-audit mentions semgrep" \
  ".claude/commands/nase/tech-debt-audit.md" \
  "semgrep"

assert_contains "tech-debt-audit mentions trivy" \
  ".claude/commands/nase/tech-debt-audit.md" \
  "trivy"

assert_contains "tech-debt-audit mentions actionlint" \
  ".claude/commands/nase/tech-debt-audit.md" \
  "actionlint"

assert_contains "fsd probes security tools" \
  ".claude/commands/nase/fsd.md" \
  "--group security"

assert_contains "address-comments probes security tools" \
  ".claude/commands/nase/address-comments.md" \
  "--group security"

assert_contains "fsd probes ci tools" \
  ".claude/commands/nase/fsd.md" \
  "--group ci"

assert_contains "address-comments probes ci tools" \
  ".claude/commands/nase/address-comments.md" \
  "--group ci"

assert_contains "discuss-pr uses syntax-aware diff" \
  ".claude/commands/nase/discuss-pr.md" \
  "difft --display json"

assert_contains "discuss-pr probes ci tools" \
  ".claude/commands/nase/discuss-pr.md" \
  "--group ci"

assert_contains "onboard probes repo tools" \
  ".claude/commands/nase/onboard.md" \
  "--group repo --group ci --format json"

assert_contains "tech-debt-audit probes ci tools" \
  ".claude/commands/nase/tech-debt-audit.md" \
  "--group ci"

assert_contains "stats probes usage tools" \
  ".claude/commands/nase/stats.md" \
  "--group usage --format json"

assert_contains "recap probes usage tools" \
  ".claude/commands/nase/recap.md" \
  "--group usage --format json"

assert_contains "skill-audit has semgrep supplement" \
  ".claude/commands/nase/skill-audit.md" \
  "Optional Semgrep supplement"

assert_contains "stats probes data tools" \
  ".claude/commands/nase/stats.md" \
  "tool-availability.py --group data --group usage --format json"

assert_contains "recap probes data tools" \
  ".claude/commands/nase/recap.md" \
  "tool-availability.py --group data --group usage --format json"

assert_contains "cli-tooling documents integration contracts" \
  ".claude/docs/cli-tooling.md" \
  "## Integration Contracts"

assert_contains "cli-tooling documents markitdown" \
  ".claude/docs/cli-tooling.md" \
  '| `docs` | `lychee`, `markitdown`, `pandoc`, `pdftotext`, `qpdf`, `magick` |'

assert_contains "cli-tooling documents converter safety" \
  ".claude/docs/cli-tooling.md" \
  'Document converters (`markitdown`, `pandoc`, `pdftotext`) produce untrusted'

if [[ "$failures" -eq 0 ]]; then
  printf '\ncli-tooling integration tests passed.\n'
  exit 0
fi

printf '\n%d cli-tooling integration assertion(s) failed.\n' "$failures" >&2
exit 1
