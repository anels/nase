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

test_missing_jq() {
  local desc="missing jq fails closed"
  local cmd="g""it sta""tus"
  local json tmp rc out

  json=$(printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)")
  tmp=$(mktemp -d)
  out=$(PATH="$tmp" /bin/bash "$HOOK" <<< "$json" 2>&1)
  rc=$?
  rm -rf "$tmp"

  if [[ "$rc" == "2" && "$out" == *"jq is required"* ]]; then
    printf 'PASS  [block] %-30s rc=%s\n' "$desc" "$rc"
    pass=$((pass+1))
  else
    printf 'FAIL  [block] %-30s rc=%s\n      out: %s\n' "$desc" "$rc" "$out"
    fail=$((fail+1))
  fi
}

test_invalid_json() {
  local desc="invalid JSON fails closed"
  local rc out

  out=$(printf '{' | bash "$HOOK" 2>&1)
  rc=$?

  if [[ "$rc" == "2" && "$out" == *"could not parse"* ]]; then
    printf 'PASS  [block] %-30s rc=%s\n' "$desc" "$rc"
    pass=$((pass+1))
  else
    printf 'FAIL  [block] %-30s rc=%s\n      out: %s\n' "$desc" "$rc" "$out"
    fail=$((fail+1))
  fi
}

# Should block — destructive operations
test_case "reset hard"           "g""it res""et --hard HEAD~1"                  block
test_case "quoted executable reset" 'g""it res""et --hard'                      block
test_case "ansi-quoted executable reset" "g$'i't res""et --hard"                block
test_case "locale-quoted executable reset" 'g$""it res""et --hard'              block
test_case "reset hard with -C"   "g""it -C /tmp/repo res""et --hard"            block
test_case "reset hard after opts" "g""it res""et -q --recurse-submodules --hard" block
test_case "reset quoted hard"    "g""it res""et \"--hard\""                     block
test_case "leading whitespace reset" "   g""it res""et --hard"                  block
test_case "newline reset hard"   "g""it status"$'\n'"g""it res""et --hard"      block
test_case "or-chained reset"     "g""it status || g""it res""et --hard"          block
test_case "pipe-chained reset"   "g""it status | g""it res""et --hard"           block
test_case "env chained reset"    "g""it status && /usr/bin/en""v g""it res""et --hard" block
test_case "clean -fd"            "g""it cl""ean -fd"                            block
test_case "branch -D"            "g""it br""anch -D feat/foo"                   block
test_case "branch delete force"  "g""it br""anch --delete --force feat/foo"     block
test_case "checkout dot"         "g""it ch""eckout ."                           block
test_case "checkout top pathspec" "g""it ch""eckout :/"                         block
test_case "restore dot"          "g""it res""tore ."                            block
test_case "restore top pathspec" "g""it res""tore :/"                           block
test_case "restore magic top pathspec" "g""it res""tore ':(top)'"               block
test_case "config global"        "g""it co""nfig --global user.email x@y"       block
test_case "no-verify push"       "g""it pu""sh --no-verify origin feat/x"       block
test_case "no-verify push after ref" "g""it pu""sh origin feat/x --no-verify"   block
test_case "no-verify commit after msg" "g""it co""mmit -m fix --no-verify"      block
test_case "no-gpg commit after msg" "g""it co""mmit -m fix --no-gpg-sign"       block
test_case "push origin main"     "g""it pu""sh origin main"                     block
test_case "push arbitrary remote main" "g""it pu""sh backup main"               block
test_case "push origin plus main" "g""it pu""sh origin +main"                   block
test_case "push -C main"         "g""it -C /tmp/repo pu""sh origin main"         block
test_case "push refs main"       "g""it pu""sh origin refs/heads/main"           block
test_case "push refspec to main" "g""it pu""sh origin refs/heads/feature:refs/heads/main" block
test_case "push plus refspec to main" "g""it pu""sh origin +feature:main"        block
test_case "push HEAD plus main"  "g""it pu""sh origin HEAD:+main"                block
test_case "push origin master"   "g""it pu""sh origin master"                   block
test_case "push HEAD:main"       "g""it pu""sh origin HEAD:main"                block
test_case "push HEAD:release"    "g""it pu""sh origin HEAD:release/sprint-29"   block
test_case "push HEAD:refs release" "g""it pu""sh origin HEAD:refs/heads/release/sprint-29" block
test_case "push origin release"  "g""it pu""sh origin release/sprint-29"        block
test_case "push arbitrary remote release" "g""it pu""sh backup release/sprint-29" block
test_case "push refspec to release" "g""it pu""sh origin feature:release/sprint-29" block
test_case "force push main"      "g""it pu""sh --force origin main"             block
test_case "tag force"            "g""it ta""g -f v1.2.3 HEAD"                  block
test_case "tag force after args"  "g""it ta""g -a v1.2.3 -m msg -f"             block
test_case "tag --force"          "g""it ta""g --force v1.2.3"                  block
test_case "tag delete"           "g""it ta""g -d v1.2.3"                       block
test_case "tag --delete"         "g""it ta""g --delete v1.2.3"                 block
test_case "reflog expire"        "g""it re""flog expire --expire=now --all"    block
test_case "remote branch del"    "g""it pu""sh origin :feat/old"               block
test_case "remote branch del arbitrary remote" "g""it pu""sh backup :feat/old" block
test_case "push --delete"        "g""it pu""sh --delete origin feat/old"       block
test_case "push -d"              "g""it pu""sh -d origin feat/old"             block
test_case "push --mirror"        "g""it pu""sh --mirror origin"                block
test_case "push --prune"         "g""it pu""sh --prune origin"                 block
test_case "push --all"           "g""it pu""sh --all origin"                   block
test_case "command git reset"    "co""mmand g""it res""et --hard"              block
test_case "command -p git push"  "co""mmand -p g""it pu""sh origin main"       block
test_case "command -- git reset" "co""mmand -- g""it res""et --hard"           block
test_case "env git reset"        "en""v g""it res""et --hard"                  block
test_case "env -- git reset"     "en""v -- g""it res""et --hard"               block
test_case "env var git reset"    "en""v GIT_DIR=.git g""it res""et --hard"     block
test_case "absolute git reset"   "/usr/bin/g""it res""et --hard"               block
test_case "homebrew git push"    "/opt/homebrew/bin/g""it pu""sh origin main"  block
test_case "absolute env git reset" "/usr/bin/en""v g""it res""et --hard"        block
test_case "command absolute env git" "co""mmand /usr/bin/en""v g""it res""et --hard" block
test_case "assignment git reset" "GIT_DIR=.git g""it res""et --hard"            block
test_case "env command git reset" "en""v FOO=bar co""mmand g""it res""et --hard" block
test_case "env assignment git reset" "/usr/bin/en""v GIT_DIR=.git g""it res""et --hard" block
test_case "env unset git reset"  "en""v -u FOO g""it res""et --hard"           block
test_case "env chdir git reset"  "en""v -C /tmp g""it res""et --hard"          block
test_case "env split-string git reset" "en""v -S 'g""it res""et --hard'"       block
test_case "env split-string equals git reset" "en""v --split-string='g""it res""et --hard'" block
test_case "global opts reset"    "g""it -C /tmp/repo -c advice.detachedHead=false res""et --hard" block
test_case "paginate global opt reset" "g""it --paginate res""et --hard"       block
test_case "short paginate global opt reset" "g""it -p res""et --hard"          block
test_case "optional locks global opt reset" "g""it --no-optional-locks res""et --hard" block
test_case "config-env global opt reset" "g""it --config-env=foo=BAR res""et --hard" block
test_case "config-env alias hidden reset" "ALIAS='res""et --hard' g""it --config-env=alias.wipe=ALIAS wipe" block
test_case "config-env alias arg hidden reset" "ALIAS='res""et --hard' g""it --config-env alias.wipe=ALIAS wipe" block
test_case "alias config reset"   "g""it -c alias.wipe='!g""it res""et --hard' wipe" block
test_case "alias config reset uppercase key" "g""it -c Alias.wipe='!g""it res""et --hard' wipe" block
test_case "alias config push main" "g""it -c alias.pm='!g""it pu""sh origin main' pm" block
test_case "non-shell alias reset" "g""it -c alias.wipe='res""et --hard' wipe" block
test_case "non-shell alias push main" "g""it -c alias.pm='pu""sh origin main' pm" block
test_case "config alias reset"   "g""it co""nfig alias.wipe 'res""et --hard'" block
test_case "config add alias reset" "g""it co""nfig --add alias.wipe 'res""et --hard'" block
test_case "bash -c reset"        "b""ash -c 'g""it res""et --hard'"            block
test_case "bash -lc reset"       "b""ash -lc 'g""it res""et --hard'"           block
test_case "bash rcfile -c reset" "b""ash --rcfile /tmp/bashrc -c 'g""it res""et --hard'" block
test_case "bash option value -c reset" "b""ash -O extglob -c 'g""it res""et --hard'" block
test_case "sh -c reset"          "s""h -c 'g""it res""et --hard'"              block
test_case "env bash -c reset"    "e""nv b""ash -c 'g""it res""et --hard'"      block
test_case "eval reset"           "e""val 'g""it res""et --hard'"               block
test_case "exec reset"           "e""xec g""it res""et --hard"                 block
test_case "exec -- reset"        "e""xec -- g""it res""et --hard"              block
test_case "exec argv0 reset"     "e""xec -a git-alias g""it res""et --hard"    block
test_case "time reset"           "t""ime g""it res""et --hard"                 block
test_case "time -p reset"        "t""ime -p g""it res""et --hard"              block
test_case "sudo reset"           "su""do g""it res""et --hard"                 block
test_case "sudo -- reset"        "su""do -- g""it res""et --hard"              block
test_case "sudo user reset"      "su""do -u root g""it res""et --hard"         block
test_case "sudo attached user reset" "su""do -uroot g""it res""et --hard"      block
test_case "sudo grouped user reset" "su""do -Eu root g""it res""et --hard"     block
test_case "sudo env reset"       "su""do GIT_DIR=.git g""it res""et --hard"    block
test_case "doas reset"           "do""as g""it res""et --hard"                 block
test_case "nohup reset"          "no""hup g""it res""et --hard"                block
test_case "nice reset"           "ni""ce g""it res""et --hard"                 block
test_case "nice value reset"     "ni""ce -n 10 g""it res""et --hard"           block
test_case "arch reset"           "ar""ch -x86_64 g""it res""et --hard"         block
test_case "xcrun reset"          "xc""run g""it res""et --hard"                block
test_case "xcrun sdk reset"      "xc""run --sdk macosx g""it res""et --hard"   block
test_case "xcrun short sdk reset" "xc""run -sdk macosx g""it res""et --hard"   block
test_case "sudo bash reset"      "su""do b""ash -c 'g""it res""et --hard'"     block

# Should allow — legitimate operations
test_case "tag create"           "g""it ta""g v1.2.3"                          allow
test_case "tag annotated"        "g""it ta""g -a v1.2.3 -m 'msg'"              allow
test_case "tag list"             "g""it ta""g -l"                              allow
test_case "reflog show"          "g""it re""flog show"                         allow
test_case "push feature"         "g""it pu""sh -u origin feat/user-avatar"      allow
test_case "force-lease feature"  "g""it pu""sh --force-with-lease origin feat/x" allow
test_case "fetch"                "g""it -C /tmp/repo fe""tch origin"            allow
test_case "log"                  "g""it l""og --oneline -5"                     allow
test_case "status"               "g""it sta""tus --short"                       allow
test_case "checkout branch"      "g""it ch""eckout feat/foo"                    allow
test_case "branch delete merged" "g""it br""anch --delete feat/done"            allow
test_case "reset soft"           "g""it res""et HEAD~1"                         allow
test_case "reset path named hard" "g""it res""et -- --hard"                     allow
test_case "rebase main"          "g""it re""base main"                          allow
test_case "config-env safe status" "FOO=bar g""it --config-env=foo=FOO sta""tus" allow
test_case "config safe alias"     "g""it co""nfig alias.st 'sta""tus --short'"  allow
test_case "empty"                ""                                             allow

# False-positive guards — git mentioned inside string literal must not block
test_case "echo dangerous str"   "ec""ho \"g""it res""et --hard\""              allow
test_case "commit msg w/ string" "g""it co""mmit -m \"fix g""it res""et --hard issue\"" allow
test_case "non-git command"      "p""ython script.py"                          allow
test_case "ls with git in name"  "l""s -la /tmp/git-stuff"                     allow
test_case "command echo dangerous" "co""mmand ec""ho \"g""it res""et --hard\""  allow
test_case "env echo dangerous"   "en""v ec""ho g""it res""et --hard"           allow
test_case "env unset echo dangerous" "en""v -u FOO ec""ho g""it res""et --hard" allow
test_case "sudo echo dangerous"  "su""do ec""ho g""it res""et --hard"          allow
test_case "nohup echo dangerous" "no""hup ec""ho g""it res""et --hard"         allow
test_case "nice echo dangerous"  "ni""ce ec""ho g""it res""et --hard"          allow
test_case "absolute git-like path" "/tmp/g""it-stuff res""et --hard"           allow
test_case "echo absolute git"    "ec""ho \"/usr/bin/g""it res""et --hard\""     allow
test_case "absolute env-like path" "/tmp/en""v-stuff g""it res""et --hard"      allow
test_case "commit msg no-verify" "g""it co""mmit -m \"--no-verify\""            allow
test_case "tag msg force string" "g""it ta""g -a v1.2.3 -m \"-f\""              allow
test_case "quoted or-chain"      "ec""ho \"g""it status || g""it res""et --hard\"" allow
test_case "quoted semicolon"     "p""rintf 'g""it res""et --hard; g""it cl""ean -fd'" allow

# Chained commands — second segment must still be checked
test_case "chained reset"        "c""d /tmp && g""it res""et --hard"           block
test_case "semicolon push main"  "g""it status; g""it pu""sh origin main"      block
test_case "subshell reset"       "(g""it res""et --hard)"                     block
test_case "brace group reset"    "{ g""it res""et --hard; }"                  block
test_case "if reset"             "if g""it res""et --hard; then ec""ho ok; fi" block
test_case "negated if reset"     "if ! g""it res""et --hard; then ec""ho ok; fi" block
test_case "command substitution reset" "ec""ho \$(g""it res""et --hard)"      block
test_case "quoted command substitution reset" "ec""ho \"\$(g""it res""et --hard)\"" block
test_case "backtick reset"       "ec""ho \`g""it res""et --hard\`"             block
test_case "process substitution reset" "c""at <(g""it res""et --hard)"        block
test_case "output process substitution reset" "ec""ho ok > >(g""it res""et --hard)" block
test_case "nested process substitution reset" "c""at <(ec""ho <(g""it res""et --hard))" block
test_case "single ampersand reset" "ec""ho ok & g""it res""et --hard"          block
test_case "quoted subshell text"  "ec""ho \"(g""it res""et --hard)\""          allow
test_case "quoted process substitution text" "ec""ho \"<(g""it res""et --hard)\"" allow
test_case "single-quoted command substitution text" "ec""ho '\$(g""it res""et --hard)'" allow
test_case "escaped backtick text" 'ec''ho \`g''it res''et --hard\`'             allow
test_case "bash script named -c"  "b""ash -- -c 'g""it res""et --hard'"         allow

test_missing_jq
test_invalid_json

printf '\n--- %d pass, %d fail ---\n' "$pass" "$fail"
exit "$fail"
