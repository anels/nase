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
    assert_contains "tech-debt-audit references ${agent}" "$TECH_DEBT" "${agent}"
  fi
}

TECH_DEBT=".claude/commands/nase/tech-debt-audit.md"

assert_contains "tech-debt-audit declares fan-out sub-pattern" "$TECH_DEBT" "sub-patterns: [fan-out]"
assert_contains "tech-debt-audit dispatches agents in one turn" "$TECH_DEBT" "Dispatch all selected audit agents in one message"
assert_contains "tech-debt-audit keeps main-thread verification" "$TECH_DEBT" "The main thread owns verification, scoring, and KB writes"

for agent in \
  nase-tech-debt-architecture \
  nase-tech-debt-ci-test \
  nase-tech-debt-maintainability \
  nase-tech-debt-modernization \
  nase-tech-debt-security
do
  assert_agent_contract "$agent"
done

if [[ "$failures" -eq 0 ]]; then
  printf '\ntech-debt subagent tests passed.\n'
  exit 0
fi

printf '\n%d tech-debt subagent assertion(s) failed.\n' "$failures" >&2
exit "$failures"
