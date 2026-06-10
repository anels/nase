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
run_gate() { "$@" || failed=$((failed+1)); }
SHELLCHECK_BIN=$(command -v shellcheck 2>/dev/null || true)
SHELLCHECK_SKIP='SKIP: shellcheck is not installed locally; GitHub Actions still runs this gate.'
ACTIONLINT_BIN=$(command -v actionlint 2>/dev/null || true)
ACTIONLINT_SKIP='SKIP: actionlint is not installed locally; GitHub Actions still runs this gate.'

section "bash syntax (hooks)"
for f in .claude/hooks/*.sh; do
  run_gate bash -n "$f"
done

section "shellcheck (hooks)"
if [ -n "$SHELLCHECK_BIN" ]; then
  run_gate "$SHELLCHECK_BIN" -S warning .claude/hooks/*.sh
else
  printf '%s\n' "$SHELLCHECK_SKIP"
fi

section "JSON (settings.json)"
run_gate python3 -m json.tool .claude/settings.json >/dev/null

section "GitHub Actions lint"
if [ -n "$ACTIONLINT_BIN" ]; then
  workflow_files=()
  for f in .github/workflows/*.yml .github/workflows/*.yaml; do
    [ -f "$f" ] && workflow_files+=("$f")
  done
  if [ "${#workflow_files[@]}" -gt 0 ]; then
    run_gate "$ACTIONLINT_BIN" "${workflow_files[@]}"
  fi
else
  printf '%s\n' "$ACTIONLINT_SKIP"
fi

section "hook wiring"
OPT_IN_REGEX='^(edit-typecheck)$'
missing_hook=0
for f in .claude/hooks/*.sh; do
  name=$(basename "$f" .sh)
  [[ "$name" =~ $OPT_IN_REGEX ]] && continue
  if ! grep -q "${name}.sh" .claude/settings.json; then
    printf 'FAIL: %s.sh not wired in settings.json\n' "$name"
    missing_hook=1
  fi
done
[[ "$missing_hook" -eq 0 ]] || failed=$((failed+1))

section "command inventory"
missing_cmd=0
while IFS= read -r cmd; do
  file=".claude/commands/nase/${cmd}.md"
  if [ ! -f "$file" ]; then
    printf 'FAIL: README references /nase:%s but %s does not exist\n' "$cmd" "$file"
    missing_cmd=1
  fi
done < <(grep -oE '/nase:[a-z-]+' README.md | sed 's|/nase:||' | sort -u)
[[ "$missing_cmd" -eq 0 ]] || failed=$((failed+1))

section "skill bash syntax + shellcheck"
skill_fail=0
for f in .claude/commands/nase/*.md; do
  blocks=$(awk '/```bash/{p=1;next} /```/{p=0} p' "$f")
  [ -z "$blocks" ] && continue
  if ! err=$(printf '%s\n' "$blocks" | bash -n 2>&1); then
    printf 'FAIL: invalid bash syntax in %s: %s\n' "$f" "$err"
    skill_fail=1
  fi
  if [ -n "$SHELLCHECK_BIN" ]; then
    if ! sc=$(printf '%s\n' "$blocks" | "$SHELLCHECK_BIN" --shell=bash -S error - 2>&1); then
      printf 'FAIL: shellcheck errors in %s:\n%s\n' "$f" "$sc"
      skill_fail=1
    fi
  fi
done
if [ -z "$SHELLCHECK_BIN" ]; then
  printf '%s\n' "$SHELLCHECK_SKIP"
fi
[[ "$skill_fail" -eq 0 ]] || failed=$((failed+1))

section "shared-doc bash syntax"
doc_bash_fail=0
for f in .claude/docs/*.md; do
  blocks=$(awk '/```bash/{p=1;next} /```/{p=0} p' "$f")
  [ -z "$blocks" ] && continue
  if ! err=$(printf '%s\n' "$blocks" | bash -n 2>&1); then
    printf 'FAIL: invalid bash syntax in %s: %s\n' "$f" "$err"
    doc_bash_fail=1
  fi
done
[[ "$doc_bash_fail" -eq 0 ]] || failed=$((failed+1))

section "hook regression tests"
for test_file in \
  tests/hooks/test-block-dangerous-git.sh \
  tests/hooks/test-external-write-guards.sh \
  tests/hooks/test-style-edit-detect.sh \
  tests/hooks/test-session-start.sh \
  tests/hooks/test-stop-backup-safety.sh \
  tests/hooks/test-post-edit-shellcheck.sh \
  tests/hooks/test-pre-edit-write-fact-force.sh
do
  run_gate bash "$test_file"
done

section "workspace validation"
run_gate bash .claude/scripts/validate-workspace.sh

section "local sensitive artifact scan"
run_gate bash tests/check-local-sensitive-artifacts.sh

section "script regression tests"
for test_file in \
  tests/scripts/test-date-resolve.sh \
  tests/scripts/test-kb-gap-scan.sh \
  tests/scripts/test-help-summary.sh \
  tests/scripts/test-kb-hygiene-scan.sh \
  tests/scripts/test-kb-search.sh \
  tests/scripts/test-today-stats.sh \
  tests/scripts/test-tool-availability.sh \
  tests/scripts/test-local-parallel-subagents.sh \
  tests/scripts/test-tech-debt-subagents.sh \
  tests/scripts/test-cli-tooling-integration.sh \
  tests/scripts/test-github-actions-hardening.sh \
  tests/scripts/test-extensions-check.sh \
  tests/scripts/test-pr-github-helper.sh \
  tests/scripts/test-pr-review-eval.sh \
  tests/scripts/test-voice-profile-routing.sh \
  tests/scripts/test-local-sensitive-artifacts.sh \
  tests/scripts/test-shared-workflow-extraction.sh \
  tests/scripts/test-workspace-data-scan.sh \
  tests/scripts/test-workspace-write-guard.sh
do
  run_gate bash "$test_file"
done

section "shared-doc reference integrity"
run_gate bash tests/check-shared-doc-refs.sh

section "skill doctrine"
run_gate bash tests/check-skill-doctrine.sh

section "markdown internal-link check"
if command -v lychee >/dev/null 2>&1; then
  lychee --offline --no-progress --include-fragments \
    --exclude-path workspace \
    --exclude-path .omc \
    --exclude-path node_modules \
    './**/*.md' \
    '.claude/**/*.md' || failed=$((failed+1))
else
  printf 'SKIP: lychee not installed locally; GitHub Actions still runs this gate.\n'
fi

if [[ "$failed" -eq 0 ]]; then
  printf '\nAll gates passed.\n'
  exit 0
fi

printf '\n%d gate(s) failed.\n' "$failed" >&2
exit "$failed"
