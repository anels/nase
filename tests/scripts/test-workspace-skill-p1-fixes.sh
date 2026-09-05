#!/usr/bin/env bash
# Regression tests for P1 reliability fixes in ignored workspace skills.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

failures=0

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; failures=$((failures + 1)); }

check_file_available() {
  local name="$1" file="$2"

  if [[ -f "$file" ]]; then
    return 0
  fi

  case "$file" in
    workspace/skills/*)
      printf 'SKIP  %s (local workspace skill missing: %s)\n' "$name" "$file"
      ;;
    *)
      fail "$name (tracked file missing: $file)"
      ;;
  esac
  return 1
}

assert_contains() {
  local name="$1" file="$2" text="$3"
  if ! check_file_available "$name" "$file"; then
    return
  fi
  if grep -Fq -- "$text" "$file"; then pass "$name"; else fail "$name"; fi
}

assert_not_contains() {
  local name="$1" file="$2" text="$3"
  local rc
  if ! check_file_available "$name" "$file"; then
    return
  fi
  if grep -Fq -- "$text" "$file"; then
    fail "$name"
  else
    rc=$?
    if [[ "$rc" -eq 1 ]]; then pass "$name"; else fail "$name (search exited $rc)"; fi
  fi
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

IMPROVE_COMMIT=.claude/commands/nase/improve-commit-message.md
COMMIT_CONTEXT=.claude/scripts/git-commit-context.py
KB_USAGE=.claude/commands/nase/kb-usage.md

assert_contains "pushed amend requires immediate approval even with auto-accept" \
  "$IMPROVE_COMMIT" 'When `is_pushed: true`, `--auto-accept` does not authorize the amend.'
assert_contains "pushed amend cannot inherit caller authorization" \
  "$IMPROVE_COMMIT" 'Approval cannot be inherited from a caller flag or earlier workflow confirmation.'
assert_contains "pushed amend approval names the full SHA" \
  "$IMPROVE_COMMIT" 'HEAD ({full_sha}) from exactly:'
assert_contains "pushed amend approval binds the full message" \
  "$IMPROVE_COMMIT" '{proposed full message}'
assert_contains "improve commit reads publish state from the shared helper" \
  "$IMPROVE_COMMIT" 'git-commit-context.py'
assert_contains "pushed amend refreshes all configured remote heads" \
  "$COMMIT_CONTEXT" 'f"+refs/heads/*:refs/remotes/{remote}/*"'
assert_contains "pushed amend fails closed on remote refresh errors" \
  "$COMMIT_CONTEXT" 'state = "unknown"'
assert_contains "unknown publish state counts as published" \
  "$COMMIT_CONTEXT" 'state in ("pushed", "unknown")'
assert_contains "auto-accept only skips approval for confirmed local commits off a protected branch" \
  "$IMPROVE_COMMIT" 'When `push_state: not-pushed` and `is_protected: false` and `--auto-accept` is present'
assert_contains "a protected branch withholds auto-accept whatever the push state says" \
  "$IMPROVE_COMMIT" 'When `is_protected: true`, `--auto-accept` does not authorize the amend either'
assert_contains "pushed amend warnings preserve unknown state" \
  "$IMPROVE_COMMIT" 'HEAD was {history_status} before amend'
assert_not_contains "pushed amend does not claim committer timestamp preservation" \
  "$IMPROVE_COMMIT" 'preserves original author and timestamp automatically'
assert_contains "improve commit frontmatter exposes only supported flags" \
  "$IMPROVE_COMMIT" 'argument-hint: "[--auto-accept] [--repo <abs-path>]"'
assert_not_contains "auto-accept does not amend pushed history immediately" \
  "$IMPROVE_COMMIT" 'amend still proceeds in `--auto-accept` mode'
assert_contains "architecture documents exact pushed-amend approval" \
  docs/architecture.md 'cannot inherit approval from `--auto-accept`'

SKILL_AUDIT=.claude/commands/nase/skill-audit.md
assert_contains "skill audit treats scanner clean as non-proof" \
  "$SKILL_AUDIT" 'a clean scanner result does not prove absence'
assert_contains "skill audit checks semantic variants in every file" \
  "$SKILL_AUDIT" 'Check equivalent quoted, split-line, absolute-path, and indirect forms'
assert_contains "skill audit evaluates privilege hygiene for every file" \
  "$SKILL_AUDIT" 'Evaluate Category 7 for every file'
assert_contains "skill audit can confirm deterministic scanner gaps" \
  "$SKILL_AUDIT" 'manual semantic check'
assert_not_contains "skill audit does not skip clean-file semantic review" \
  "$SKILL_AUDIT" 'Do not rescan clean files in prose'
assert_not_contains "skill audit has no scanner-only verdict contradiction" \
  "$SKILL_AUDIT" 'invent those findings when the scanner emitted no lead'

assert_contains "KB usage frontmatter documents every supported flag" \
  "$KB_USAGE" 'argument-hint: "[--window N|all] [--top N] [--verbose]"'
assert_contains "KB usage delegates validation to the Python helper" \
  "$KB_USAGE" 'Let `kb-usage-report.py` parse and validate those arguments.'
assert_not_contains "KB usage does not reparse raw arguments in shell" \
  "$KB_USAGE" 'set -- $ARGUMENTS'

APP_INSIGHTS=workspace/skills/appinsights-deep-triage.md
assert_contains "App Insights zero-signal branch has one owner" \
  "$APP_INSIGHTS" '## Missing telemetry branch'
assert_contains "App Insights emits only non-secret routing status" \
  "$APP_INSIGHTS" 'emit only `match`, `mismatch`, or `missing`'
assert_contains "App Insights component lookup projects non-secret fields" \
  "$APP_INSIGHTS" "--query '{id:id,name:name,ingestionMode:ingestionMode,workspaceResourceId:workspaceResourceId,provisioningState:provisioningState}' -o json"
# Herestring, not a pipe: `grep -vq` exits on the first non-matching line, and
# under `pipefail` rg's next write would then report 141 rather than a verdict.
# The `-n` guard matters: a herestring of the empty string is still one empty
# line, which `grep -v` would match.
component_show_lines=$(rg -n 'component show' "$APP_INSIGHTS" || true)
if [ -n "$component_show_lines" ] && grep -vq -- '--query' <<<"$component_show_lines"; then
  fail "App Insights has no unprojected component lookup"
else
  pass "App Insights has no unprojected component lookup"
fi
assert_contains "App Insights distinguishes shared and separate configuration" \
  "$APP_INSIGHTS" 'separately constructed configuration'
assert_contains "App Insights redeploy uses deploy-alpha exact payload gate" \
  "$APP_INSIGHTS" 'exact immutable SHA and exact previewed payload'
assert_not_contains "App Insights does not list application settings" \
  "$APP_INSIGHTS" 'az webapp config appsettings list'
assert_not_contains "App Insights does not query publishing credentials" \
  "$APP_INSIGHTS" 'list-publishing-credentials'

if [[ -d workspace/skills ]]; then
  if [[ ! -e workspace/skills/appinsights-zero-signal-triage.md ]]; then
    pass "duplicate App Insights skill is removed"
  else
    fail "duplicate App Insights skill is removed"
  fi
  if [[ ! -e workspace/skills/security-pr-review.md ]]; then
    pass "duplicate security review skill is removed"
  else
    fail "duplicate security review skill is removed"
  fi
fi

for repo_skill in \
  workspace/skills/doc-pr-head-ground-scan.md \
  workspace/skills/satisfy-sonar-new-coverage.md \
  workspace/skills/confluence-doc-internalize.md \
  workspace/skills/repo-docs-with-ascii.md \
  workspace/skills/optimize-skills-from-lessons.md
do
  assert_contains "$(basename "$repo_skill") uses repo task flow" \
    "$repo_skill" '.claude/docs/repo-task-flow.md'
  assert_contains "$(basename "$repo_skill") blocks protected branches" \
    "$repo_skill" 'release/*'
  assert_contains "$(basename "$repo_skill") gates external writes" \
    "$repo_skill" '.claude/docs/external-mutation-policy.md'
done

assert_not_contains "Confluence internalize does not misuse workspace guard for repo paths" \
  workspace/skills/confluence-doc-internalize.md 'workspace-write-guard.md` before writing generated docs to a repo path'
assert_not_contains "repo docs does not misuse workspace guard for repo paths" \
  workspace/skills/repo-docs-with-ascii.md 'workspace-write-guard.md` before writing generated docs to a repo path'

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
