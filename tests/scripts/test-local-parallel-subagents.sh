#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

failures=0
source "$ROOT/tests/lib/assert.sh"

assert_file() {
  local name="$1"
  local file="$2"
  if [[ -f "$file" ]]; then
    pass "$name"
  else
    fail "$name"
  fi
}

assert_agent_contract() {
  local agent="$1"
  local path=".claude/agents/${agent}.md"

  assert_file "${agent} exists" "$path"
  if [[ -f "$path" ]]; then
    assert_contains "${agent} has matching name" "$path" "name: ${agent}"
    assert_contains "${agent} has minimal read-only tools" "$path" "tools: Read, Grep, Glob"
    assert_contains "${agent} uses plan permissions" "$path" "permissionMode: plan"
    assert_contains "${agent} runs in background" "$path" "background: true"
    assert_contains "${agent} references output contract" "$path" ".claude/docs/subagent-output-contract.md"
    assert_contains "${agent} returns Verdict" "$path" "Verdict:"
    assert_contains "${agent} returns Facts" "$path" "Facts:"
    assert_contains "${agent} returns Risks" "$path" "Risks:"
    assert_contains "${agent} returns Recommended action" "$path" "Recommended action:"
    assert_contains "${agent} returns Files checked" "$path" "Files checked:"
    assert_contains "${agent} returns Blocked" "$path" "Blocked:"
  fi
}

assert_file "subagent output contract doc exists" ".claude/docs/subagent-output-contract.md"

for agent in \
  nase-context-kb-researcher \
  nase-repo-state-scanner \
  nase-workspace-state-scanner \
  nase-pr-metadata-reader \
  nase-reviewer-owner-scanner
do
  assert_agent_contract "$agent"
done

assert_contains "KB researcher includes lessons source" ".claude/agents/nase-context-kb-researcher.md" "workspace/tasks/lessons.md"

assert_contains "design uses KB researcher" ".claude/commands/nase/design.md" "nase-context-kb-researcher"
assert_contains "design uses repo scanner" ".claude/commands/nase/design.md" "nase-repo-state-scanner"
assert_contains "design uses workspace scanner" ".claude/commands/nase/design.md" "nase-workspace-state-scanner"
assert_contains "design main thread owns writes" ".claude/commands/nase/design.md" "main thread owns design synthesis and workspace writes"

assert_contains "request-review uses PR metadata reader" ".claude/commands/nase/request-review.md" "nase-pr-metadata-reader"
assert_contains "request-review uses owner scanner" ".claude/commands/nase/request-review.md" "nase-reviewer-owner-scanner"
assert_contains "request-review main thread owns Slack" ".claude/commands/nase/request-review.md" "main thread owns Slack lookup, recipient confirmation, and draft staging"

assert_contains "today uses workspace scanner" ".claude/commands/nase/today.md" "nase-workspace-state-scanner"
assert_contains "today uses PR metadata reader" ".claude/commands/nase/today.md" "nase-pr-metadata-reader"
assert_contains "today keeps MCP in main thread" ".claude/commands/nase/today.md" "Slack/Jira MCP queries stay in the main thread"

assert_contains "recap uses workspace scanner" ".claude/commands/nase/recap.md" "nase-workspace-state-scanner"
assert_contains "recap main thread owns writes" ".claude/commands/nase/recap.md" "main thread owns recap synthesis and file writes"

assert_contains "kb-review uses KB researcher" ".claude/commands/nase/kb-review.md" "nase-context-kb-researcher"
assert_contains "kb-review main thread owns KB edits" ".claude/commands/nase/kb-review.md" "main thread owns KB edits and report writes"
assert_contains "kb-review scans the complete ignored workspace without showing values" ".claude/commands/nase/kb-review.md" "check-local-sensitive-artifacts.sh --workspace"
assert_contains "kb-review audits authoritative state sources" ".claude/commands/nase/kb-review.md" "Status Vocabulary"
assert_contains "kb-review verifies documented commands in fixtures" ".claude/commands/nase/kb-review.md" "fixture or dry-run"
assert_contains "kb-review requires replayable non-mutation proof" ".claude/commands/nase/kb-review.md" "machine-readable before and after SHA-256 manifests"
assert_contains "kb-review tests collision-safe backup writers" ".claude/commands/nase/kb-review.md" "archive names must be collision-safe"
assert_contains "kb-review executes exact code proposals" ".claude/commands/nase/kb-review.md" "not repair-ready until that test executes successfully"
assert_contains "kb-review reruns full preflight for exact proposals" ".claude/commands/nase/kb-review.md" "every deterministic preflight command"
assert_contains "kb-review separates local repairs from destructive and external actions" ".claude/commands/nase/kb-review.md" "External, credential, deletion, and rotation actions"
assert_contains "effort lifecycle points to stable kb-review section" ".claude/docs/effort-lifecycle.md" 'Deep review -> Authoritative state'
assert_contains "kb relationship graph points to stable kb-review section" ".claude/docs/kb-relationship-graph.md" 'Deep review -> Content and relationships'
assert_contains "kb staleness points to stable kb-review section" ".claude/docs/kb-staleness.md" 'Deep review -> Content and relationships'
assert_contains "kb write routing points to stable kb-review section" ".claude/docs/kb-write-routing.md" 'Deep review -> Content and relationships'
assert_contains "lesson promotion points to stable kb-review section" ".claude/docs/lessons-format.md" 'Deep review -> Content and relationships'
assert_cmd "effort lifecycle has no removed kb-review step" bash -c '! grep -Fq "$2" "$1"' _ ".claude/docs/effort-lifecycle.md" '/nase:kb-review` Step'
assert_cmd "kb relationship graph has no removed kb-review step" bash -c '! grep -Fq "$2" "$1"' _ ".claude/docs/kb-relationship-graph.md" '/nase:kb-review` Step'
assert_cmd "kb staleness has no removed kb-review steps" bash -c '! grep -Fq "$2" "$1"' _ ".claude/docs/kb-staleness.md" '/nase:kb-review` (Steps'
assert_cmd "kb write routing has no removed kb-review step" bash -c '! grep -Fq "$2" "$1"' _ ".claude/docs/kb-write-routing.md" '/nase:kb-review` Step'
assert_cmd "lesson format has no removed kb-review step" bash -c '! grep -Fq "$2" "$1"' _ ".claude/docs/lessons-format.md" '/nase:kb-review` Step'

assert_contains "fsd searches KB mentions for touched paths" ".claude/commands/nase/fsd.md" "mentions:<path>"
assert_contains "discuss-pr searches KB mentions for core changed files" ".claude/commands/nase/discuss-pr.md" "mentions:<path>"
assert_contains "address-comments searches KB mentions for review-thread files" ".claude/commands/nase/address-comments.md" "mentions:<path>"

if [[ "$failures" -eq 0 ]]; then
  printf '\nlocal parallel subagent tests passed.\n'
  exit 0
fi

printf '\n%d local parallel subagent assertion(s) failed.\n' "$failures" >&2
exit "$failures"
