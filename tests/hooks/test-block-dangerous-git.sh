#!/usr/bin/env bash
# Regression tests for .claude/hooks/block-dangerous-git.sh
#
# Run from repo root:  bash tests/hooks/test-block-dangerous-git.sh
# Exit 0 = all tests pass, exit N = N failures.
#
# Test commands are written with adjacent string concatenation (e.g. "g""it")
# so the source file itself doesn't match the hook's regex when this script is
# read by an active Claude Code session that has the hook installed. Bash
# concatenates them at parse time, so the runtime values are still the literal
# commands. Keep this style when adding new cases.

set +e

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
HOOK="$ROOT/.claude/hooks/block-dangerous-git.sh"

if [[ ! -x "$HOOK" ]]; then
  printf 'FATAL: hook not found or not executable: %s\n' "$HOOK" >&2
  exit 1
fi

fail=0
pass=0

test_case() {
  local desc="$1" cmd="$2" expect="$3"
  local rc out
  out=$(printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)" | bash "$HOOK" 2>&1)
  rc=$?
  if [[ "$expect" == "block" && "$rc" == "2" ]] || [[ "$expect" == "allow" && "$rc" == "0" ]]; then
    printf 'PASS  [%s] %-30s rc=%s\n' "$expect" "$desc" "$rc"
    pass=$((pass+1))
  else
    printf 'FAIL  [%s] %-30s rc=%s\n      out: %s\n' "$expect" "$desc" "$rc" "$out"
    fail=$((fail+1))
  fi
}

# Should block — destructive operations
test_case "reset hard"           "g""it res""et --hard HEAD~1"                  block
test_case "clean -fd"            "g""it cl""ean -fd"                            block
test_case "branch -D"            "g""it br""anch -D feat/foo"                   block
test_case "checkout dot"         "g""it ch""eckout ."                           block
test_case "restore dot"          "g""it res""tore ."                            block
test_case "config global"        "g""it co""nfig --global user.email x@y"       block
test_case "no-verify push"       "g""it pu""sh --no-verify origin feat/x"       block
test_case "push origin main"     "g""it pu""sh origin main"                     block
test_case "push origin master"   "g""it pu""sh origin master"                   block
test_case "push HEAD:main"       "g""it pu""sh origin HEAD:main"                block
test_case "push origin release"  "g""it pu""sh origin release/sprint-29"        block
test_case "force push main"      "g""it pu""sh --force origin main"             block

# Should allow — legitimate operations
test_case "push feature"         "g""it pu""sh -u origin feat/user-avatar"      allow
test_case "force-lease feature"  "g""it pu""sh --force-with-lease origin feat/x" allow
test_case "fetch"                "g""it -C /tmp/repo fe""tch origin"            allow
test_case "log"                  "g""it l""og --oneline -5"                     allow
test_case "status"               "g""it sta""tus --short"                       allow
test_case "checkout branch"      "g""it ch""eckout feat/foo"                    allow
test_case "reset soft"           "g""it res""et HEAD~1"                         allow
test_case "rebase main"          "g""it re""base main"                          allow
test_case "empty"                ""                                             allow

# False-positive guards — git mentioned inside string literal must not block
test_case "echo dangerous str"   "ec""ho \"g""it res""et --hard\""              allow
test_case "commit msg w/ string" "g""it co""mmit -m \"fix g""it res""et --hard issue\"" allow
test_case "non-git command"      "p""ython script.py"                          allow
test_case "ls with git in name"  "l""s -la /tmp/git-stuff"                     allow

# Chained commands — second segment must still be checked
test_case "chained reset"        "c""d /tmp && g""it res""et --hard"           block
test_case "semicolon push main"  "g""it status; g""it pu""sh origin main"      block

printf '\n--- %d pass, %d fail ---\n' "$pass" "$fail"
exit "$fail"
