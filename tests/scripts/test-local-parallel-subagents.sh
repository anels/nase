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
    assert_contains "${agent} is read-only" "$path" "tools: Read, Grep, Glob, Bash"
    assert_contains "${agent} runs in background" "$path" "background: true"
  fi
}

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

assert_contains "fsd searches KB mentions for touched paths" ".claude/commands/nase/fsd.md" "mentions:<path>"
assert_contains "discuss-pr searches KB mentions for core changed files" ".claude/commands/nase/discuss-pr.md" "mentions:<path>"
assert_contains "address-comments searches KB mentions for review-thread files" ".claude/commands/nase/address-comments.md" "mentions:<path>"

if [[ "$failures" -eq 0 ]]; then
  printf '\nlocal parallel subagent tests passed.\n'
  exit 0
fi

printf '\n%d local parallel subagent assertion(s) failed.\n' "$failures" >&2
exit "$failures"
