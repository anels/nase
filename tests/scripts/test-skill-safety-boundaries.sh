#!/usr/bin/env bash
# Regression tests for high-risk workspace skill boundaries.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"
fail=0

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
      printf 'FAIL  %s (tracked file missing: %s)\n' "$name" "$file" >&2
      fail=$((fail + 1))
      ;;
  esac
  return 1
}

check_contains() {
  local name="$1" file="$2" pattern="$3"
  if ! check_file_available "$name" "$file"; then
    return
  fi
  if rg -q --fixed-strings "$pattern" "$file"; then
    printf 'PASS  %s\n' "$name"
  else
    printf 'FAIL  %s\n' "$name" >&2
    fail=$((fail + 1))
  fi
}

check_absent() {
  local name="$1" file="$2" pattern="$3"
  local rc
  if ! check_file_available "$name" "$file"; then
    return
  fi
  if rg -q --fixed-strings "$pattern" "$file"; then
    printf 'FAIL  %s\n' "$name" >&2
    fail=$((fail + 1))
  else
    rc=$?
    if [[ "$rc" -eq 1 ]]; then
      printf 'PASS  %s\n' "$name"
    else
      printf 'FAIL  %s (search exited %s)\n' "$name" "$rc" >&2
      fail=$((fail + 1))
    fi
  fi
}

deploy="workspace/skills/deploy-alpha.md"
check_contains "deploy is user-invoked only" "$deploy" "disable-model-invocation: true"
check_contains "deploy payload pins immutable version" "$deploy" '"version": "<SHA>"'
check_contains "deploy uses external action helper" "$deploy" "external-write-action.py"
check_contains "deploy previews before the real trigger" "$deploy" 'previewRun:true'
check_contains "deploy reads back the created run version" "$deploy" 'resources.repositories.self.version'
check_contains "deploy stops on a pinned-version mismatch" "$deploy" 'does not match approved SHA'
check_contains "deploy cancellation has its own action token" "$deploy" 'CANCEL_MANIFEST'
check_absent "deploy does not default CI skips to true" "$deploy" 'CI skips** (all `true`)'

for mutation_skill in \
  .claude/commands/nase/address-comments.md \
  .claude/commands/nase/prep-merge.md \
  .claude/docs/github-queries.md
do
  check_contains "${mutation_skill} uses payload-bound GitHub actions" "$mutation_skill" "external-write-action.py"
done
check_contains "FSD uses delivery gate guard" .claude/commands/nase/fsd.md "fsd-delivery-gates.md"
check_contains "FSD delivery gates use payload-bound GitHub actions" .claude/docs/fsd-delivery-gates.md "external-write-action.py"
check_contains "FSD delivery gates clean private PR body files" .claude/docs/fsd-delivery-gates.md "trap 'rm -f \"\$PR_BODY_FILE\"' EXIT"
check_contains "address-comments cleans private PR body files" .claude/commands/nase/address-comments.md "trap 'rm -f \"\$PR_BODY_FILE\"' EXIT"
check_contains "prep-merge cleans private PR body files" .claude/commands/nase/prep-merge.md "trap 'rm -f \"\$PR_BODY_FILE\"' EXIT"

discuss=".claude/commands/nase/discuss-pr.md"
check_contains "discuss PR declares read-only draft flow" "$discuss" "This command is read-only."
check_absent "discuss PR does not offer post flow" "$discuss" "Draft + post"
check_absent "discuss PR has no reaction mutation" "$discuss" "pulls/comments/{comment_id}/reactions"

sre="workspace/skills/docs/sre-alert-flow.md"
check_absent "SRE flow does not start web apps" "$sre" "az webapp start"
check_absent "SRE flow does not swap slots" "$sre" "az webapp deployment slot swap"

repro="workspace/skills/agentic-repro-bug.md"
check_contains "browser repro requires a non-production test workspace" "$repro" "non-production test workspace"

printf '\n--- safety boundary failures: %d ---\n' "$fail"
[ "$fail" -eq 0 ]
