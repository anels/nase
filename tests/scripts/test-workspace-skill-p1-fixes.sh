#!/usr/bin/env bash
# Regression tests for P1 reliability fixes in ignored workspace skills.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

failures=0

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; failures=$((failures + 1)); }

assert_contains() {
  local name="$1" file="$2" text="$3"
  if grep -Fq -- "$text" "$file"; then pass "$name"; else fail "$name"; fi
}

assert_not_contains() {
  local name="$1" file="$2" text="$3"
  if grep -Fq -- "$text" "$file"; then fail "$name"; else pass "$name"; fi
}

ADO=workspace/skills/ado-pipeline-secret-audit.md
ULTRA=workspace/skills/ultrareview-ci.md
SONAR=workspace/skills/satisfy-sonar-new-coverage.md
SYNC=workspace/skills/sync-skill-docs.md

assert_contains "ADO validates numeric definition IDs" "$ADO" 'case "$definition_id" in'
assert_contains "ADO rejects invalid definition IDs" "$ADO" "*[!0-9]*"
assert_contains "ADO uses a private temporary directory" "$ADO" 'mktemp -d'
assert_not_contains "ADO has no interpolated temp directory template" "$ADO" 'ado-secret-audit-{definition_id}'

assert_contains "ultrareview initializes target" "$ULTRA" 'TARGET=""'
assert_contains "ultrareview removes timeout before target resolution" "$ULTRA" 'TARGET_ARGS='

assert_contains "Sonar starts with diagnostics" "$SONAR" 'diagnose before changing code or coverage configuration'
assert_contains "Sonar requires a concrete exclusion rationale" "$SONAR" 'Do not add an exclusion solely to clear the gate.'
assert_not_contains "Sonar no longer prescribes exclusions by default" "$SONAR" 'needs coverage exclusion, not a test'

assert_contains "sync docs checks unstaged changes without HEAD" "$SYNC" 'git diff --name-only --'
assert_contains "sync docs checks staged changes" "$SYNC" 'git diff --cached --name-only --'
assert_contains "sync docs includes untracked command skills" "$SYNC" 'git ls-files --others --exclude-standard --'
assert_contains "sync docs checks local workspace-skill manifest" "$SYNC" 'workspace-skill-integrity.py'
assert_not_contains "sync docs does not depend on empty HEAD diff" "$SYNC" 'git diff HEAD --name-only'

assert_contains "deploy shows the exact trigger manifest after second confirmation" \
  workspace/skills/deploy-alpha.md 'jq . "$TRIGGER_MANIFEST"'

for agent in \
  nase-context-kb-researcher \
  nase-repo-state-scanner \
  nase-workspace-state-scanner \
  nase-pr-metadata-reader \
  nase-reviewer-owner-scanner
do
  path=".claude/agents/${agent}.md"
  assert_contains "${agent} has minimal read tools" "$path" 'tools: Read, Grep, Glob'
  assert_contains "${agent} uses plan permissions" "$path" 'permissionMode: plan'
  assert_not_contains "${agent} does not grant Bash" "$path" 'Bash'
done

if [[ "$failures" -eq 0 ]]; then
  printf '\nworkspace skill P1 regression tests passed.\n'
  exit 0
fi

printf '\n%s workspace skill P1 regression assertion(s) failed.\n' "$failures" >&2
exit "$failures"
