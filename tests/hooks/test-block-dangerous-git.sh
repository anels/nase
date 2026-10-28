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

test_case_in_dir() {
  local desc="$1" cmd="$2" expect="$3" workdir="$4"
  local rc out
  out=$(printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)" | (cd "$workdir" && bash "$HOOK") 2>&1)
  rc=$?
  if [[ "$expect" == "block" && "$rc" == "2" ]] || [[ "$expect" == "allow" && "$rc" == "0" ]]; then
    printf 'PASS  [%s] %-30s rc=%s\n' "$expect" "$desc" "$rc"
    pass=$((pass+1))
  else
    printf 'FAIL  [%s] %-30s rc=%s\n      out: %s\n' "$expect" "$desc" "$rc" "$out"
    fail=$((fail+1))
  fi
}

make_git_repo_on_branch() {
  local branch="$1" dir
  dir=$(mktemp -d)
  git init -q "$dir"
  git -C "$dir" checkout -q -b "$branch"
  printf '%s\n' "$dir"
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

# Fault injection: insert a failing command into a copy of each guard, after its
# input is read and before any verdict. Claude Code blocks only on exit 2, so an unexpected non-zero exit
# (set -e, set -u, a failed subprocess) must map to 2 and not leak out as 1.
test_unexpected_error_fails_closed() {
  local guard="$1" inject="$2" desc="unexpected error fails closed: $1"
  local dir rc out input='{"tool_name":"mcp__x__noop","tool_input":{"command":"ls"}}'

  dir=$(mktemp -d)
  mkdir -p "$dir/.claude/hooks" "$dir/.claude/scripts"
  sed "$inject" "$ROOT/.claude/hooks/$guard" > "$dir/.claude/hooks/$guard"
  mkdir -p "$dir/.claude/lib"
  cp "$ROOT"/.claude/lib/hook-common.sh "$dir/.claude/lib/"
  if cmp -s "$ROOT/.claude/hooks/$guard" "$dir/.claude/hooks/$guard"; then
    printf 'FAIL  [block] %-30s fault injection did not apply\n' "$desc"
    fail=$((fail+1))
    rm -rf "$dir"
    return
  fi
  cp "$ROOT"/.claude/scripts/external-write-action.py "$ROOT"/.claude/scripts/shell_scan.py "$dir/.claude/scripts/" 2>/dev/null || true
  out=$(printf '%s' "$input" | NASE_ROOT="$dir" bash "$dir/.claude/hooks/$guard" 2>&1)
  rc=$?
  rm -rf "$dir"

  if [[ "$rc" == "2" ]]; then
    printf 'PASS  [block] %-30s rc=%s\n' "$desc" "$rc"
    pass=$((pass+1))
  else
    printf 'FAIL  [block] %-30s rc=%s\n      out: %s\n' "$desc" "$rc" "$out"
    fail=$((fail+1))
  fi
}

MAIN_REPO=$(make_git_repo_on_branch main)
RELEASE_REPO=$(make_git_repo_on_branch release/sprint-29)
FEATURE_REPO=$(make_git_repo_on_branch feat/user-avatar)
trap 'rm -rf "$MAIN_REPO" "$RELEASE_REPO" "$FEATURE_REPO"' EXIT

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
# `--staged` alone rewrites index entries from HEAD and touches no file, so a
# whole-tree pathspec cannot discard work. Adding --worktree does touch files.
test_case "restore staged dot"   "g""it res""tore --staged ."                   allow
test_case "restore dot slash"    "g""it res""tore ./"                           block
test_case "restore star glob"    "g""it res""tore '*'"                          block
test_case "restore parent dir"   "g""it res""tore .."                           block
test_case "checkout dash dot slash" "g""it checkout -- ./"                      block
test_case "push heads/main"      "g""it push origin heads/main"                 block
test_case "push HEAD to heads/main" "g""it push origin HEAD:heads/main"         block
test_case "push to heads/release" "g""it push origin feature:heads/release/1.0" block
test_case "rebase --exec push main" "g""it rebase --exec 'git push origin main' HEAD~1" block
test_case "rebase -x push main"  "g""it rebase -x 'git push origin main' HEAD~1" block
test_case "rebase --exec benign" "g""it rebase --exec 'make test' HEAD~1"       allow
test_case "submodule foreach push main" "g""it submodule foreach 'git push origin main'" block
test_case "submodule foreach benign" "g""it submodule foreach 'git status'"     allow
test_case "submodule foreach unquoted push" "g""it submodule foreach git push origin main" block
test_case "submodule foreach recursive reset" "g""it submodule foreach --recursive git reset --hard" block
test_case "submodule foreach after -C" "g""it -C sub submodule foreach git reset --hard" block
test_case "submodule foreach unquoted benign" "g""it submodule foreach git status" allow
test_case "bisect run git reset" "g""it bisect run git reset --hard"             block
test_case "bisect run sh -c push" "g""it bisect run sh -c 'git push origin main'" block
test_case "bisect run benign"    "g""it bisect run make test"                   allow
test_case "branch -df cluster"   "g""it branch -df foo"                         block
test_case "branch -fd cluster"   "g""it branch -fd foo"                         block
test_case "branch -d -f split"   "g""it branch -d -f foo"                       block
test_case "branch -d alone"      "g""it branch -d foo"                          allow
test_case "dynamic subcommand substitution" "g""it \$(echo push) origin main"    block
test_case "dynamic subcommand variable" 'SUB=$(echo push); g''it $SUB origin main' block
test_case "dynamic subcommand quoted arg" 'g''it "$1" origin main'               block
test_case "dynamic reset flag"   'read F; g''it reset --$F'                     block
test_case "dynamic clean flag"   'read F; g''it clean -$F'                      block
test_case "dynamic commit message ok" 'g''it commit -m "$msg"'                  allow
test_case "dynamic checkout branch ok" 'g''it checkout "$branch"'               allow
test_case "dynamic log count ok" 'g''it log -$N'                                allow
test_case "config remote push refspec" "g""it config remote.origin.push HEAD:main" block
test_case "-c remote push refspec" "g""it -c remote.origin.push=feature:main push origin feature" block
test_case "config global pager value -l" "g""it config --global core.pager -l"   block
test_case "config global pager value --list" "g""it config --global core.pager --list" block
test_case "config global -l"     "g""it config --global -l"                     allow
test_case "restore staged pathspec" "g""it res""tore --staged -- src/a.ts"      allow
test_case "restore staged and worktree" "g""it res""tore --staged --worktree ." block
test_case "restore worktree dot" "g""it res""tore --worktree ."                 block
# checkout has no index-only mode, so it is never exempt.
test_case "checkout staged dot"  "g""it ch""eckout --staged ."                  block
test_case "config global"        "g""it co""nfig --global user.email x@y"       block
test_case "config hooksPath"     "g""it co""nfig core.hooksPath /dev/null"      block
test_case "config local hooksPath" "g""it co""nfig --local core.hooksPath /dev/null" block
test_case "config hooksPath equals" "g""it co""nfig core.hooksPath=/dev/null"   block
test_case "config commit gpg false" "g""it co""nfig commit.gpgsign false"       block
test_case "config tag gpg false" "g""it co""nfig tag.gpgsign false"             block
test_case "config bool commit gpg false" "g""it co""nfig --bool commit.gpgsign false" block
# An explicit read action on --global or --system reads; it does not modify.
test_case "config global get"     "g""it co""nfig --global --get core.hooksPath" allow
test_case "config global list"    "g""it co""nfig --global --list"               allow
test_case "config global list short" "g""it co""nfig --global -l"                allow
test_case "config system get-regexp" "g""it co""nfig --system --get-regexp core" allow
# Writes to global or system config still block, including the removals.
test_case "config global unset"   "g""it co""nfig --global --unset user.email"   block
test_case "config global add"     "g""it co""nfig --global --add safe.directory /" block
test_case "config global bare key" "g""it co""nfig --global some.key"            block
# A read flag does not launder a dangerous key elsewhere in the same invocation.
test_case "config global get plus hooksPath write" \
  "g""it co""nfig --global --get x && g""it co""nfig core.hooksPath /dev/null"  block
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
test_case_in_dir "default push from main" "g""it pu""sh" block "$MAIN_REPO"
test_case_in_dir "remote-only push from main" "g""it pu""sh origin" block "$MAIN_REPO"
test_case_in_dir "HEAD push from main" "g""it pu""sh origin HEAD" block "$MAIN_REPO"
test_case_in_dir "force default push from main" "g""it pu""sh --force" block "$MAIN_REPO"
test_case_in_dir "force-lease default push from main" "g""it pu""sh --force-with-lease" block "$MAIN_REPO"
test_case_in_dir "default push from release" "g""it pu""sh" block "$RELEASE_REPO"
test_case_in_dir "HEAD push from release" "g""it pu""sh origin HEAD" block "$RELEASE_REPO"
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
test_case "config-env include path hidden" "CFG=/tmp/gitconfig g""it --config-env include.path=CFG sta""tus" block
test_case "config-env hooksPath hidden" "HOOKS=/dev/null g""it --config-env=core.hooksPath=HOOKS co""mmit -m fix" block
test_case "config-env commit gpg hidden" "SIGN=false g""it --config-env commit.gpgsign=SIGN co""mmit -m fix" block
test_case "git env config hooksPath hidden" "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/tmp g""it co""mmit -m fix" block
test_case "env wrapper git config hooksPath hidden" "en""v GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/tmp g""it co""mmit -m fix" block
test_case "git env config alias hidden" "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.wipe GIT_CONFIG_VALUE_0='!g""it res""et --hard' g""it wipe" block
test_case "git env config include path hidden" "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=include.path GIT_CONFIG_VALUE_0=/tmp/gitconfig g""it sta""tus" block
test_case "git config parameters include path hidden" "GIT_CONFIG_PARAMETERS='include.path=/tmp/gitconfig' g""it sta""tus" block
test_case "git config parameters hooksPath hidden" "GIT_CONFIG_PARAMETERS='core.hooksPath=/tmp' g""it co""mmit -m fix" block
test_case "git config global override" "GIT_CONFIG_GLOBAL=/tmp/gitconfig g""it sta""tus" block
test_case "alias config reset"   "g""it -c alias.wipe='!g""it res""et --hard' wipe" block
test_case "alias config reset uppercase key" "g""it -c Alias.wipe='!g""it res""et --hard' wipe" block
test_case "include path config hidden" "g""it -c include.path=/tmp/gitconfig sta""tus" block
test_case "includeIf path config hidden" "g""it -c includeIf.gitdir:/tmp/.path=/tmp/gitconfig sta""tus" block
test_case "global opt hooksPath" "g""it -c core.hooksPath=/dev/null co""mmit -m fix" block
test_case "global opt commit gpg false" "g""it -c commit.gpgsign=false co""mmit -m fix" block
test_case "global opt tag gpg false" "g""it -c tag.gpgsign=false ta""g v1.2.3" block
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
test_case_in_dir "default push from feature" "g""it pu""sh" allow "$FEATURE_REPO"
test_case_in_dir "remote-only push from feature" "g""it pu""sh origin" allow "$FEATURE_REPO"
test_case_in_dir "HEAD push from feature" "g""it pu""sh origin HEAD" allow "$FEATURE_REPO"
test_case_in_dir "force-lease default push from feature" "g""it pu""sh --force-with-lease" allow "$FEATURE_REPO"
test_case "fetch"                "g""it -C /tmp/repo fe""tch origin"            allow
test_case "log"                  "g""it l""og --oneline -5"                     allow
test_case "status"               "g""it sta""tus --short"                       allow
test_case "checkout branch"      "g""it ch""eckout feat/foo"                    allow
test_case "branch delete merged" "g""it br""anch --delete feat/done"            allow
test_case "reset soft"           "g""it res""et HEAD~1"                         allow
test_case "reset path named hard" "g""it res""et -- --hard"                     allow
test_case "rebase main"          "g""it re""base main"                          allow
test_case "config-env safe status" "FOO=bar g""it --config-env=foo=FOO sta""tus" allow
test_case "git env config safe status" "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=advice.detachedHead GIT_CONFIG_VALUE_0=false g""it sta""tus" allow
test_case "config safe alias"     "g""it co""nfig alias.st 'sta""tus --short'"  allow
test_case "config read include path" "g""it co""nfig --get include.path"        allow
test_case "config read hooksPath" "g""it co""nfig --get core.hooksPath"         allow
test_case "config read commit gpg" "g""it co""nfig commit.gpgsign"              allow
test_case "config commit gpg true" "g""it co""nfig commit.gpgsign true"         allow
test_case "global opt commit gpg true" "g""it -c commit.gpgsign=true co""mmit -m fix" allow
test_case "empty"                ""                                             allow

# False-positive guards — git mentioned inside string literal must not block
test_case "echo dangerous str"   "ec""ho \"g""it res""et --hard\""              allow
test_case "commit msg w/ string" "g""it co""mmit -m \"fix g""it res""et --hard issue\"" allow
test_case "non-git command"      "p""ython script.py"                          allow
test_case "ls with git in name"  "l""s -la /tmp/git-stuff"                     allow
test_case "command echo dangerous" "co""mmand ec""ho \"g""it res""et --hard\""  allow
test_case "env echo dangerous"   "en""v ec""ho g""it res""et --hard"           allow
test_case "git env assignment echo" "GIT_CONFIG_KEY_0=core.hooksPath ec""ho ok" allow
test_case "env git config global echo" "en""v GIT_CONFIG_GLOBAL=/tmp/gitconfig ec""ho ok" allow
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

# `git commit -n` is the short form of --no-verify; git also accepts unambiguous
# long-option abbreviations, so literal matching alone is a bypass.
test_case "commit -n"            "g""it co""mmit -n -m fix"                     block
test_case "commit -nm"           "g""it co""mmit -nm fix"                       block
test_case "commit -anm"          "g""it co""mmit -anm fix"                      block
test_case "commit -n after msg"  "g""it co""mmit -m fix -n"                     block
test_case "commit --amend -n"    "g""it co""mmit --amend -n"                    block
test_case "commit --no-ver"      "g""it co""mmit --no-ver -m fix"               block
test_case "commit --no-verif"    "g""it co""mmit -m fix --no-verif"             block
test_case "push --no-ver"        "g""it pu""sh --no-ver origin feat/x"          block
test_case "rebase --no-ver"      "g""it re""base --no-ver main"                 block
test_case "commit --no-gpg-s"    "g""it co""mmit --no-gpg-s -m fix"             block
test_case "reset --ha"           "g""it res""et --ha HEAD~1"                    block
test_case "reset --har"          "g""it res""et --har"                          block
test_case "push --del"           "g""it pu""sh --del origin feat/x"             block
test_case_in_dir "push --mir" "g""it pu""sh --mir origin" block "$FEATURE_REPO"
test_case_in_dir "push --pru" "g""it pu""sh --pru origin" block "$FEATURE_REPO"
test_case "clean --for"          "g""it cl""ean --for -d"                       block
test_case "branch --del --for"   "g""it br""anch --del --for feat/foo"          block
test_case "tag --del"            "g""it ta""g --del v1"                         block
test_case "config --glo"         "g""it co""nfig --glo user.name x"             block
test_case "config --sys"         "g""it co""nfig --sys user.name x"             block
test_case "restore --sta --wor ." "g""it res""tore --staged --wor ."            block
test_case "commit -mn is a message" "g""it co""mmit -mn"                        allow
test_case "commit -m -n message" "g""it co""mmit -m -n"                         allow
test_case "commit -am msg"       "g""it co""mmit -am fix"                       allow
test_case "commit -F -n file"    "g""it co""mmit -F -n"                         allow
test_case "commit --no-edit"     "g""it co""mmit --amend --no-edit"             allow
test_case "commit --no-status"   "g""it co""mmit --no-status -m fix"            allow
test_case "commit --no-post-rewrite" "g""it co""mmit --no-post-rewrite -m fix"  allow
test_case "commit -n after --"   "g""it co""mmit -m fix -- -n"                  allow
test_case "push -n dry run"      "g""it pu""sh -n origin feat/x"                allow
test_case "push --dry-run"       "g""it pu""sh --dry-run origin feat/x"         allow
test_case "push --dry"           "g""it pu""sh --dry origin feat/x"             allow
test_case "merge -n"             "g""it me""rge -n feat/x"                      allow
test_case "cherry-pick -n"       "g""it ch""erry-pick -n abc123"                allow
test_case "reset --soft"         "g""it res""et --soft HEAD~1"                  allow
test_case "reset --mixed"        "g""it res""et --mixed HEAD~1"                 allow
test_case "branch --list"        "g""it br""anch --list"                        allow
test_case "branch --show-current" "g""it br""anch --show-current"               allow
test_case "tag --list"           "g""it ta""g --list"                           allow
test_case "config --local"       "g""it co""nfig --local user.name x"           allow
test_case "config --get-regexp"  "g""it co""nfig --global --get-regexp user"    allow
test_case "config --glo --li"    "g""it co""nfig --glo --li"                    allow
test_case "restore --staged ."   "g""it res""tore --staged ."                   allow
test_case "restore --sta ."      "g""it res""tore --sta ."                      allow
test_case "clean -nfd dry run"   "g""it cl""ean -nfd"                           allow
test_case "clean -n -f -d"       "g""it cl""ean -n -f -d"                       allow
test_case "clean -fdn"           "g""it cl""ean -fdn"                           allow
test_case "clean --dry-run -f"   "g""it cl""ean --dry-run -fd"                  allow
test_case "clean --dry -f"       "g""it cl""ean --dry -fd"                      allow
test_case "clean -n"             "g""it cl""ean -n"                             allow
test_case "clean -fd still blocked with -e -n" "g""it cl""ean -fd -e -n"        block
test_case "clean -n then --no-dry-run" "g""it cl""ean -n --no-dry-run -fd"      block

# Shell constructs that used to hide a push from the guard. The shell parsing is shared with
# the external-CLI guard (.claude/scripts/shell_scan.py), so these cover the wrapper,
# compound-command, pipe-into-shell, and variable gaps that parser closes.
test_case "timeout wrapper push main"   "timeout 30 g""it pu""sh origin main"             block
test_case "timeout option wrapper"      "timeout -s KILL 30 g""it pu""sh origin main"     block
test_case "xargs wrapper push main"     "xargs g""it pu""sh origin main"                  block
test_case "xargs supplies the refspec"  "echo main | xargs g""it pu""sh origin"           block
test_case "stdbuf wrapper push main"    "stdbuf -o0 g""it pu""sh origin main"             block
test_case "nohup wrapper push main"     "nohup g""it pu""sh origin main"                  block
test_case "setsid wrapper push main"    "setsid g""it pu""sh origin main"                 block
test_case "nice wrapper push main"      "nice -n 5 g""it pu""sh origin main"              block
test_case "time wrapper push main"      "time g""it pu""sh origin main"                   block
test_case "exec wrapper push main"      "exec g""it pu""sh origin main"                   block
test_case "env -u wrapper push main"    "env -u FOO g""it pu""sh origin main"             block
test_case "sudo -u wrapper push main"   "sudo -u me g""it pu""sh origin main"             block
test_case "stacked wrappers push main"  "sudo env A=1 timeout 5 nohup g""it pu""sh origin main" block
test_case "for loop push main"          "for i in 1; do g""it pu""sh origin main; done"   block
test_case "while loop push main"        "while true; do g""it pu""sh origin main; done"   block
test_case "if body push main"           "if true; then g""it pu""sh origin main; fi"      block
test_case "brace group push main"       "{ g""it pu""sh origin main; }"                   block
test_case "negated push main"           "! g""it pu""sh origin main"                      block
test_case "find -exec push main"        "find . -name x -exec g""it pu""sh origin main \;" block
test_case "echo piped into bash"        "echo \"g\"\"it pu\"\"sh origin main\" | bash"    block
test_case "echo piped into path bash"   "echo \"g\"\"it pu\"\"sh origin main\" | /bin/bash" block
test_case "echo piped into sudo bash"   "echo \"g\"\"it pu\"\"sh origin main\" | sudo bash" block
test_case "echo piped into env bash"    "echo \"g\"\"it pu\"\"sh origin main\" | env bash" block
test_case "here-string into bash"       "bash <<< \"g\"\"it pu\"\"sh origin main\""       block
test_case "here-string with no space"   "bash<<<'g''it pu''sh origin main'"               block
test_case "heredoc into bash"           "bash <<EOF"$'\n'"g""it pu""sh origin main"$'\n'"EOF" block
test_case "quoted heredoc into bash"    "bash <<'EOF'"$'\n'"g""it pu""sh origin main"$'\n'"EOF" block
test_case "variable holds the program"  "G=g""it; \$G pu""sh origin main"                 block
test_case "variable holds program and subcommand" "G=\"g\"\"it pu\"\"sh\"; \$G origin main" block
test_case "unknown program pushing main" "\$TOOL pu""sh origin main"                      block
test_case "glob program name"           "/usr/bin/g?t pu""sh origin main"                 block
test_case "eval push main"              "eval \"g\"\"it pu\"\"sh origin main\""           block
test_case "command substitution push main" "echo \$(g""it pu""sh origin main)"            block
test_case "function forwards its arguments to git" "g() { g""it \"\$@\"; }; g pu""sh origin main" block
test_case "function forwards a whole command"    "r() { \"\$@\"; }; r g""it pu""sh origin main" block
test_case "function forwards a feature push"     "g() { g""it \"\$@\"; }; g sta""tus" allow
test_case "uppercase program name"              "GI""T pu""sh origin main"                  block
test_case "plain command skips the scanner"     "ls -la docs"                               allow
test_case "plain pipeline skips the scanner"    "cat notes.txt | head -5"                   allow
test_case "unterminated quote naming git" "g""it sta""tus 'unterminated"                  block

# Refspec words the guard cannot read literally.
test_case "brace refspec with empty arm" "g""it pu""sh origin {main,}"                    block
test_case "brace refspec under refs/heads" "g""it pu""sh origin refs/heads/{main,x}"      block
test_case "brace range refspec"         "g""it pu""sh origin {1..3}"                      block
test_case "ANSI-C quoted refspec"       "g""it pu""sh origin \$'ma\\x69n'"                block
test_case "ANSI-C quoted protected name in refspec" "g""it pu""sh origin \$'refs/heads/\\x6dain'" block
test_case "glob refspec in quotes"      "g""it pu""sh origin 'refs/heads/*:refs/heads/*'" block
test_case "glob refspec unquoted"       "g""it pu""sh origin 'feat/*'"                    block
test_case "variable refspec"            "g""it pu""sh origin \$BRANCH"                    block
test_case "quoted variable refspec"     "g""it pu""sh origin \"\$BRANCH\""                block
test_case "substitution refspec"        "g""it pu""sh origin \"\$(g""it branch --show-current)\"" block
test_case "variable-only target"        "g""it pu""sh \$ARGS"                              block
test_case "backslash in refspec"        "g""it pu""sh origin ma\\\\in"                    block
test_case "unknown --no-* global option" "g""it --no-advice pu""sh origin main"           block
test_case "unknown --opt=value global option" "g""it --future=1 pu""sh origin main"       block
test_case "unknown short global option" "g""it -Z pu""sh origin main"                     block
test_case "-P global option"            "g""it -P pu""sh origin main"                     block

# A bare push publishes HEAD of whichever repository git runs in, which is not always the
# hook's own directory.
test_case_in_dir "cd to main repo then bare push" "cd $MAIN_REPO && g""it pu""sh" block "$FEATURE_REPO"
test_case_in_dir "cd to main repo with semicolon" "cd $MAIN_REPO; g""it pu""sh" block "$FEATURE_REPO"
test_case_in_dir "cd then HEAD push" "cd $MAIN_REPO && g""it pu""sh origin HEAD" block "$FEATURE_REPO"
test_case_in_dir "pushd to main repo then bare push" "pushd $MAIN_REPO >/dev/null && g""it pu""sh" block "$FEATURE_REPO"
test_case_in_dir "subshell cd to main repo" "(cd $MAIN_REPO && g""it pu""sh)" block "$FEATURE_REPO"
test_case_in_dir "env -C main repo" "env -C $MAIN_REPO g""it pu""sh" block "$FEATURE_REPO"
test_case_in_dir "git -C main repo from a feature cwd" "g""it -C $MAIN_REPO pu""sh" block "$FEATURE_REPO"
test_case_in_dir "GIT_DIR main repo" "GIT_DIR=$MAIN_REPO/.git g""it pu""sh" block "$FEATURE_REPO"
test_case_in_dir "exported GIT_DIR main repo" "export GIT_DIR=$MAIN_REPO/.git; g""it pu""sh" block "$FEATURE_REPO"
test_case_in_dir "--git-dir= main repo" "g""it --git-dir=$MAIN_REPO/.git pu""sh" block "$FEATURE_REPO"
test_case_in_dir "--git-dir main repo" "g""it --git-dir $MAIN_REPO/.git pu""sh" block "$FEATURE_REPO"
test_case_in_dir "cd to a variable then bare push" "cd \"\$REPO\" && g""it pu""sh" block "$FEATURE_REPO"
test_case_in_dir "cd to home then bare push" "cd ~/repo && g""it pu""sh" block "$FEATURE_REPO"
test_case_in_dir "cd - then bare push" "cd - && g""it pu""sh" block "$FEATURE_REPO"
test_case_in_dir "-C variable then bare push" "g""it -C \"\$REPO\" pu""sh" block "$FEATURE_REPO"
test_case_in_dir "GIT_DIR variable then bare push" "GIT_DIR=\$X g""it pu""sh" block "$FEATURE_REPO"
test_case_in_dir "--work-tree then bare push" "g""it --work-tree=$MAIN_REPO pu""sh" block "$FEATURE_REPO"
test_case_in_dir "cd to main repo from a release cwd" "cd $MAIN_REPO && g""it pu""sh" block "$RELEASE_REPO"
test_case_in_dir "cd away from main cwd with ; still blocks" "cd $FEATURE_REPO; g""it pu""sh" block "$MAIN_REPO"

# False positives that must stay allowed.
test_case "quoted mention of a push"    "echo \"g\"\"it pu\"\"sh origin main\""           allow
test_case "single-quoted mention"       "echo 'run g''it pu''sh origin main by hand'"     allow
test_case "grep for a push"             "grep -rn 'g''it pu''sh origin main' docs"        allow
test_case "quoted heredoc mentions a push" "cat <<'EOF'"$'\n'"g""it pu""sh origin main"$'\n'"EOF" allow
test_case "unquoted heredoc mentions a push" "cat <<EOF"$'\n'"g""it pu""sh origin main"$'\n'"EOF" allow
test_case "arithmetic shift"            "echo \$((1<<2))"                                  allow
test_case "status through a wrapper"    "timeout 30 g""it sta""tus"                        allow
test_case "push feature through timeout" "timeout 30 g""it pu""sh origin feat/x"           allow
test_case "push feature through xargs"  "echo ok | xargs g""it sta""tus"                   allow
test_case "push feature in a loop"      "for b in a; do g""it pu""sh origin feat/x; done"  allow
test_case "push feature with unknown global option" "g""it --no-advice pu""sh origin feat/x" allow
test_case "push with a dynamic remote and literal branch" "g""it pu""sh \"\$REMOTE\" feat/x" allow
test_case "dynamic head that is plainly not git" "\$ROOT/bin/deploy pu""sh"               allow
test_case "commit with a heredoc message" "g""it co""mmit -m \"\$(cat <<'EOF'"$'\n'"it's a message with an apostrophe"$'\n'"EOF"$'\n'")\"" allow
test_case "git log piped to head"       "g""it log --oneline | head -5"                    allow
test_case_in_dir "cd to feature repo then bare push from main" "cd $FEATURE_REPO && g""it pu""sh" allow "$MAIN_REPO"
test_case_in_dir "git -C feature repo from a main cwd" "g""it -C $FEATURE_REPO pu""sh" allow "$MAIN_REPO"
test_case_in_dir "relative -C chain" "cd $FEATURE_REPO/.. && g""it -C $(basename "$FEATURE_REPO") pu""sh" allow "$MAIN_REPO"
test_case_in_dir "GIT_DIR feature repo from a main cwd" "GIT_DIR=$FEATURE_REPO/.git g""it pu""sh" allow "$MAIN_REPO"
test_case_in_dir "--git-dir feature repo from a main cwd" "g""it --git-dir=$FEATURE_REPO/.git pu""sh" allow "$MAIN_REPO"
test_case_in_dir "explicit feature refspec ignores the cwd branch" "cd \"\$X\" && g""it pu""sh origin feat/x" allow "$MAIN_REPO"
test_case_in_dir "cd to a directory that is not a repository" "cd .. && g""it pu""sh" allow "$FEATURE_REPO"
test_case_in_dir "subshell cd does not leak" "(cd $MAIN_REPO && g""it sta""tus); g""it pu""sh" allow "$FEATURE_REPO"

test_unexpected_error_fails_closed block-dangerous-git.sh 's/^block() {$/false\nblock() {/'
# shellcheck disable=SC2016 # A sed pattern, not a shell expansion.
INJECT_AFTER_INPUT='s/^INPUT=\$(cat)$/INPUT=$(cat)\nfalse/'
test_unexpected_error_fails_closed confluence-size-guard.sh "$INJECT_AFTER_INPUT"
test_unexpected_error_fails_closed atlassian-generic-write-guard.sh "$INJECT_AFTER_INPUT"
test_unexpected_error_fails_closed external-cli-write-guard.sh "$INJECT_AFTER_INPUT"

test_missing_jq
test_invalid_json

printf '\n--- %d pass, %d fail ---\n' "$pass" "$fail"
exit "$fail"
