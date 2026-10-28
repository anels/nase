#!/usr/bin/env bash
# PreToolUse Bash hook — block dangerous git operations.
#
# Aligns with CLAUDE.md rules: never push to protected branches; never run
# destructive ops without explicit user approval; never skip hooks or signing;
# never modify global git config. Pushes to feature branches are allowed so
# /nase:fsd and /nase:prep-merge keep working.
#
# Reads tool_input JSON from stdin, exits 2 to block (stderr reaches Claude).
#
# Finding the git invocations in a command string is shell_scan.py's job (shared with
# external-cli-write-guard.sh); this file keeps only the per-subcommand policy.

set -euo pipefail

# Load the shared lib before the EXIT trap below. A syntax error in a sourced file
# makes bash 3.2 exit through the trap with status 0, which would fail open; with no
# trap yet, `set -e` exits 2 and the guard blocks.
HOOK_DIR=${BASH_SOURCE[0]%/*}
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.
# shellcheck source=../lib/hook-common.sh
{ [ -r "$HOOK_DIR/../lib/hook-common.sh" ] && . "$HOOK_DIR/../lib/hook-common.sh"; } 2>/dev/null \
  || { echo "BLOCKED by block-dangerous-git: hook-common.sh is missing or unreadable; failing closed." >&2; exit 2; }

nase_install_fail_closed_trap block-dangerous-git

block_without_command() {
  printf 'BLOCKED: %s\nThe user has prevented this operation. Ask before retrying.\n' "$1" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || block_without_command 'jq is required by block-dangerous-git.sh to parse Bash tool input'

if ! CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null); then
  block_without_command 'block-dangerous-git.sh could not parse Bash tool input JSON'
fi

[[ -z "$CMD" ]] && exit 0

block() {
  printf 'BLOCKED: %s\nCommand: %s\nThe user has prevented this operation. Ask before retrying.\n' "$1" "$CMD" >&2
  exit 2
}

# Fast path. A command with no "git" in it and no character that could assemble the word
# (a quote, backslash, `$`, backtick, brace, or glob character) cannot run git, so it needs
# no scan. Case is folded because a case-insensitive filesystem runs `GIT` as git.
case "$CMD" in
  *[gG][iI][tT]*) ;;
  *[\$\`\\\'\"{}*?[]*) ;;
  *) exit 0 ;;
esac

command -v python3 >/dev/null 2>&1 || block_without_command 'python3 is required by block-dangerous-git.sh to parse shell commands'
SCANNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts"
[[ -f "$SCANNER_DIR/shell_scan.py" ]] || block_without_command "shell_scan.py is missing next to the hooks ($SCANNER_DIR)"

# Imported rather than run as a file so Python reuses the cached bytecode: compiling the
# module on every Bash call costs more than running it.
run_scanner() {
  python3 -S -c 'import sys; sys.path.insert(0, sys.argv[1]); import shell_scan; sys.exit(shell_scan.main(sys.argv[2:]))' "$SCANNER_DIR" "$@"
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

scan_git_config_value() {
  local config_value="$1"
  local key value key_lc value_lc alias_body

  key="${config_value%%=*}"
  value="${config_value#*=}"
  if [ "$key" = "$config_value" ]; then
    return 0
  fi

  key_lc=$(lowercase "$key")
  value_lc=$(lowercase "$value")
  case "$key_lc" in
    include.path|includeif.*.path)
      block "git config $key (hidden config include can bypass git safety checks)"
      ;;
    core.hookspath)
      block 'git config core.hooksPath (changes hook path)'
      ;;
    remote.*.push)
      block "git config $key (rewrites the refspec a push sends, hiding the target branch)"
      ;;
    commit.gpgsign|tag.gpgsign)
      case "$value_lc" in
        false|no|off|0)
          block "git config $key=false (bypassing signing)"
          ;;
      esac
      ;;
  esac

  if printf '%s' "$key" | grep -qi '^alias\.'; then
    case "$value" in
      '!'*)
        alias_body="${value#!}"
        ;;
      *)
        alias_body="git $value"
        ;;
    esac
    scan_nested_command "$alias_body"
  fi
}

scan_git_config_env_arg() {
  local config_env="$1"
  local key="${config_env%%=*}"
  local key_lc

  key_lc=$(lowercase "$key")
  case "$key_lc" in
    include.path|includeif.*.path)
      block "git --config-env $key (hidden config include can bypass git safety checks)"
      ;;
    alias.*)
      block 'git --config-env alias.* (hidden alias body can bypass git safety checks)'
      ;;
    core.hookspath)
      block 'git --config-env core.hooksPath (hidden hook path can bypass hooks)'
      ;;
    remote.*.push)
      block "git --config-env $key (hidden push refspec can bypass protected-branch checks)"
      ;;
    commit.gpgsign|tag.gpgsign)
      block "git --config-env $key (hidden signing config can bypass signing)"
      ;;
  esac
}

scan_git_env_assignment() {
  local assignment="$1"
  local key="${assignment%%=*}"
  local value="${assignment#*=}"
  local key_lc value_lc

  [ "$key" != "$assignment" ] || return 0
  key_lc=$(lowercase "$key")
  case "$key_lc" in
    git_config_global|git_config_system)
      block "git environment $key (hidden config file override)"
      ;;
    git_config_parameters)
      value_lc=$(lowercase "$value")
      case "$value_lc" in
        *alias.*|*include.path*|*includeif.*.path*|*core.hookspath*|*commit.gpgsign*|*tag.gpgsign*|*remote.*.push*)
          block "git environment $key (hidden unsafe config)"
          ;;
      esac
      ;;
    git_config_key_[0-9]*)
      scan_git_config_env_arg "$value=GIT_CONFIG_VALUE"
      ;;
  esac
}

# Shell parsing lives in .claude/scripts/shell_scan.py, shared with the external-CLI guard.
# It prints NUL-delimited fields (see `_records` there): `unparseable=0|1`, then per git
# invocation `INV`, via, stdin, head-dynamic, the candidate working directories, the
# environment assignments, and the argv with a dynamic flag per word, and finally `END`.
# A missing `END` means the scanner died, and that must block rather than allow.
scan_next() {
  if [ "$SCAN_IDX" -ge "${#SCAN_FIELDS[@]}" ]; then
    block 'shell scanner output was truncated (failing closed)'
  fi
  SCAN_VAL="${SCAN_FIELDS[$SCAN_IDX]}"
  SCAN_IDX=$((SCAN_IDX + 1))
}

# Resolve the directories a bare `git push` could run in: the hook's own directory, any
# cd/pushd the scanner saw, and every -C. "?" means the path is not a literal.
build_candidate_dirs() {
  local cwd dir
  CANDIDATE_DIRS=()
  for cwd in "${INV_CWDS[@]}"; do
    if [ "$cwd" = "?" ] || [ "$C_DYNAMIC" -ne 0 ] || [[ "$C_CHAIN" == "~"* ]]; then
      dir="?"
    elif [ -z "$C_CHAIN" ]; then
      dir="$cwd"
    elif [[ "$C_CHAIN" == /* ]] || [ -z "$cwd" ]; then
      dir="$C_CHAIN"
    else
      dir="${cwd%/}/$C_CHAIN"
    fi
    CANDIDATE_DIRS+=("$dir")
  done
}

# Skip git's global options to reach the subcommand. Any unrecognized `-` option before
# the subcommand is skipped as a flag: git has no other global option that takes a value,
# and an unknown one makes git itself exit before it does anything.
parse_git_global_options() {
  local idx=1 word

  while [ "$idx" -lt "${#INV_ARGS[@]}" ]; do
    word="${INV_ARGS[$idx]}"
    case "$word" in
      -c)
        if [ $((idx + 1)) -lt "${#INV_ARGS[@]}" ]; then
          scan_git_config_value "${INV_ARGS[$((idx + 1))]}"
        fi
        idx=$((idx + 2))
        ;;
      --config-env)
        if [ $((idx + 1)) -lt "${#INV_ARGS[@]}" ]; then
          scan_git_config_env_arg "${INV_ARGS[$((idx + 1))]}"
        fi
        idx=$((idx + 2))
        ;;
      -C)
        if [ $((idx + 1)) -lt "${#INV_ARGS[@]}" ]; then
          if [ "${INV_DYN[$((idx + 1))]}" -ne 0 ]; then
            C_DYNAMIC=1
          elif [[ "${INV_ARGS[$((idx + 1))]}" == /* ]] || [ -z "$C_CHAIN" ]; then
            C_CHAIN="${INV_ARGS[$((idx + 1))]}"
          else
            C_CHAIN="${C_CHAIN%/}/${INV_ARGS[$((idx + 1))]}"
          fi
        fi
        idx=$((idx + 2))
        ;;
      --git-dir)
        if [ $((idx + 1)) -lt "${#INV_ARGS[@]}" ]; then
          GITDIR_OVERRIDE="${INV_ARGS[$((idx + 1))]}"
          GITDIR_DYNAMIC="${INV_DYN[$((idx + 1))]}"
        fi
        idx=$((idx + 2))
        ;;
      --work-tree)
        WORKTREE_OVERRIDE=1
        idx=$((idx + 2))
        ;;
      --namespace|--exec-path|--super-prefix|--attr-source)
        idx=$((idx + 2))
        ;;
      --config-env=*)
        scan_git_config_env_arg "${word#--config-env=}"
        idx=$((idx + 1))
        ;;
      --git-dir=*)
        GITDIR_OVERRIDE="${word#--git-dir=}"
        GITDIR_DYNAMIC="${INV_DYN[$idx]}"
        idx=$((idx + 1))
        ;;
      --work-tree=*)
        WORKTREE_OVERRIDE=1
        idx=$((idx + 1))
        ;;
      -*)
        idx=$((idx + 1))
        ;;
      *)
        break
        ;;
    esac
  done

  NORM_CMD="git"
  NORM_ARGS=()
  NORM_DYN=()
  while [ "$idx" -lt "${#INV_ARGS[@]}" ]; do
    NORM_ARGS+=("${INV_ARGS[$idx]}")
    NORM_DYN+=("${INV_DYN[$idx]}")
    NORM_CMD+=" ${INV_ARGS[$idx]}"
    idx=$((idx + 1))
  done
}

# Read one INV record from the scanner output and apply the policy to it.
apply_scanned_invocation() {
  local count i kv key
  local -a INV_CWDS=() INV_ARGS=() INV_DYN=() INV_ENV=() INV_ENV_DYN=() NORM_ARGS=() NORM_DYN=() CANDIDATE_DIRS=()
  local C_CHAIN="" C_DYNAMIC=0 GITDIR_OVERRIDE="" GITDIR_DYNAMIC=0 WORKTREE_OVERRIDE=0 NORM_CMD=""

  scan_next # via
  scan_next # stdin
  scan_next # head dynamic
  scan_next
  count="$SCAN_VAL"
  for ((i = 0; i < count; i++)); do
    scan_next
    INV_CWDS+=("$SCAN_VAL")
  done
  scan_next
  count="$SCAN_VAL"
  for ((i = 0; i < count; i++)); do
    scan_next
    INV_ENV_DYN+=("$SCAN_VAL")
    scan_next
    INV_ENV+=("$SCAN_VAL")
  done
  scan_next
  count="$SCAN_VAL"
  for ((i = 0; i < count; i++)); do
    scan_next
    INV_DYN+=("$SCAN_VAL")
    scan_next
    INV_ARGS+=("$SCAN_VAL")
  done

  if [ "${#INV_ENV[@]}" -gt 0 ]; then
    for ((i = 0; i < ${#INV_ENV[@]}; i++)); do
      kv="${INV_ENV[$i]}"
      scan_git_env_assignment "$kv"
      key="${kv%%=*}"
      case "$key" in
        GIT_DIR)
          GITDIR_OVERRIDE="${kv#*=}"
          GITDIR_DYNAMIC="${INV_ENV_DYN[$i]}"
          ;;
        GIT_WORK_TREE)
          WORKTREE_OVERRIDE=1
          ;;
      esac
    done
  fi
  parse_git_global_options
  build_candidate_dirs
  apply_policy
}

check() {
  [[ "$NORM_CMD" =~ $1 ]] && block "$2"
  return 0
}

option_takes_value() {
  case "$1" in
    -m|--message|-F|--file|-C|-c|--reuse-message|--reedit-message|--author|--date|--pathspec-from-file)
      return 0
      ;;
  esac
  return 1
}

# git accepts any unambiguous prefix of a long option, so `--no-ver` is `--no-verify`.
# An abbreviation that is ambiguous in git is an error there, so matching every
# prefix of a guarded flag can only block more, never let a real flag through.
long_flag_matches() {
  local arg="$1" flag="$2" name
  [[ "$arg" == --* ]] || return 1
  name="${arg%%=*}"
  [ "${#name}" -ge 3 ] || return 1
  [[ "$flag" == "$name"* ]]
}

has_flag() {
  local flag="$1" i arg skip_next=0
  for ((i=1; i<${#NORM_ARGS[@]}; i++)); do
    arg="${NORM_ARGS[$i]}"
    if [ "$skip_next" -eq 1 ]; then
      skip_next=0
      continue
    fi
    [ "$arg" = "--" ] && return 1
    if option_takes_value "$arg"; then
      skip_next=1
      continue
    fi
    long_flag_matches "$arg" "$flag" && return 0
  done
  return 1
}

# Exact short-flag lookup that reads a cluster the way git does: scanning stops at an
# option that takes a value, because the rest of the cluster (or the next word) is
# that value. `-nm msg` has -n, `-mn` is the message "n", `-m -n` is the message "-n".
#   $1 flag character   $2 characters that take a value   $3 characters with an
#   optional attached value
has_short_cluster_flag() {
  local flag="$1" value_chars="$2" optional_chars="$3" i j arg cluster ch skip_next=0
  for ((i=1; i<${#NORM_ARGS[@]}; i++)); do
    arg="${NORM_ARGS[$i]}"
    if [ "$skip_next" -eq 1 ]; then
      skip_next=0
      continue
    fi
    [ "$arg" = "--" ] && return 1
    if [[ "$arg" == --* ]]; then
      option_takes_value "$arg" && skip_next=1
      continue
    fi
    [[ "$arg" == -?* ]] || continue
    cluster="${arg#-}"
    for ((j=0; j<${#cluster}; j++)); do
      ch="${cluster:j:1}"
      [ "$ch" = "$flag" ] && return 0
      if [[ "$value_chars" == *"$ch"* ]]; then
        [ $((j + 1)) -lt "${#cluster}" ] || skip_next=1
        break
      fi
      [[ "$optional_chars" == *"$ch"* ]] && break
    done
  done
  return 1
}

# `git clean -n` and `--dry-run` list what would go and delete nothing, even with -f.
# `-e` takes a pattern, so `-e -n` is not a dry run. A later `--no-dry-run` cancels it.
git_clean_is_dry_run() {
  has_flag "--no-dry-run" && return 1
  has_flag "--dry-run" && return 0
  has_short_cluster_flag "n" "e" ""
}

has_short_flag() {
  local flag="$1" i arg skip_next=0
  for ((i=1; i<${#NORM_ARGS[@]}; i++)); do
    arg="${NORM_ARGS[$i]}"
    if [ "$skip_next" -eq 1 ]; then
      skip_next=0
      continue
    fi
    [ "$arg" = "--" ] && return 1
    if option_takes_value "$arg"; then
      skip_next=1
      continue
    fi
    if [[ "$arg" == -[^-]* && "$arg" == *"$flag"* ]]; then
      return 0
    fi
  done
  return 1
}

has_arg() {
  local target="$1" arg
  for arg in "${NORM_ARGS[@]:1}"; do
    [ "$arg" = "$target" ] && return 0
  done
  return 1
}

# A pathspec that covers the whole work tree: `.`, `./`, `..`, `*`, `:/`, `:(top)`.
has_whole_tree_pathspec() {
  local arg
  for arg in "${NORM_ARGS[@]:1}"; do
    [[ "$arg" =~ ^(\.{1,2}(/+\.{1,2})*/*|\*|:/\*?|:\(top\)\*?)$ ]] && return 0
  done
  return 1
}

# A fresh Bash tool call has no positional parameters, so `git "$@"` only matters inside a
# function, and the scanner re-emits a function call with its real arguments. That makes
# a bare positional subcommand safe when the command defines a function and never rewrites
# the positionals with `set`. Anything else stays unverifiable.
positional_forward_is_resolved() {
  [[ "$1" =~ ^[\$](@|\*|[0-9]|\{[0-9@*]+\})$ ]] || return 1
  [[ "$CMD" =~ (^|[^[:alnum:]_])(function[[:space:]]+[[:alnum:]_]+|[[:alnum:]_]+[[:space:]]*\(\)) ]] || return 1
  [[ ! "$CMD" =~ (^|[;&|\(\{[:space:]])set[[:space:]] ]]
}

# A flag assembled from a variable (`-$F`, `--$F`) cannot be read, so block it. On reset
# and clean a bare variable word is blocked too, because it can carry `--hard` or `-f`.
guard_dynamic_flag_words() {
  local idx arg
  for ((idx = 1; idx < ${#NORM_ARGS[@]}; idx++)); do
    [ "${NORM_DYN[$idx]:-0}" -ne 0 ] || continue
    arg="${NORM_ARGS[$idx]}"
    if [[ "$arg" =~ ^-+[\$\`] ]]; then
      block "git $1 flag '$arg' uses a variable or substitution this guard cannot verify (use a literal flag)"
    fi
    case "$1" in
      reset|clean)
        if [[ "$arg" =~ ^[\$\`] ]]; then
          block "git $1 argument '$arg' uses a variable or substitution that could carry a destructive flag (use literals)"
        fi
        ;;
    esac
  done
  return 0
}

git_config_is_read_only() {
  # git's own read actions. `--list` and its short form print; every `--get` variant
  # queries. Anything else on a --global or --system invocation is treated as a write.
  # Only options before the key count. A later word is a value, so `core.pager -l` or
  # `core.pager --list` is still a write.
  local idx=1 arg flag
  while [ "$idx" -lt "${#NORM_ARGS[@]}" ]; do
    arg="${NORM_ARGS[$idx]}"
    [ "$arg" = "-l" ] && return 0
    for flag in --get --get-all --get-regexp --get-urlmatch --get-color --get-colorbool --list; do
      long_flag_matches "$arg" "$flag" && return 0
    done
    case "$arg" in
      --)
        break
        ;;
      --file|--blob|--type|-f|-t)
        idx=$((idx + 2))
        continue
        ;;
      -*)
        idx=$((idx + 1))
        continue
        ;;
    esac
    break
  done
  return 1
}

scan_git_config_args() {
  local idx=1 arg key value

  while [ "$idx" -lt "${#NORM_ARGS[@]}" ]; do
    arg="${NORM_ARGS[$idx]}"
    case "$arg" in
      --)
        idx=$((idx + 1))
        break
        ;;
      --file|--blob|--type|--get-color|--get-colorbool|-f|-t)
        idx=$((idx + 2))
        continue
        ;;
      --file=*|--blob=*|--type=*|--get-color=*|--get-colorbool=*)
        idx=$((idx + 1))
        continue
        ;;
      -*)
        idx=$((idx + 1))
        continue
        ;;
    esac
    break
  done

  [ "$idx" -lt "${#NORM_ARGS[@]}" ] || return 0
  key="${NORM_ARGS[$idx]}"
  if [[ "$key" == *=* ]]; then
    scan_git_config_value "$key"
    return 0
  fi
  [ $((idx + 1)) -lt "${#NORM_ARGS[@]}" ] || return 0
  value="${NORM_ARGS[$((idx + 1))]}"
  scan_git_config_value "$key=$value"
}

# Name the branch HEAD points at in directory $1 ("" means the hook's own directory),
# honoring --git-dir/GIT_DIR when one was given as a literal. Prints nothing when it
# cannot tell, which the caller reads as "not a repository, nothing to protect".
current_git_branch() {
  local dir="$1" branch=""
  local -a base=(git)

  if [ -n "$dir" ]; then
    base=(git -C "$dir")
  fi
  if [ -n "$GITDIR_OVERRIDE" ]; then
    base+=(--git-dir="$GITDIR_OVERRIDE")
    branch=$("${base[@]}" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  else
    branch=$("${base[@]}" branch --show-current 2>/dev/null || true)
    if [ -z "$branch" ]; then
      branch=$("${base[@]}" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    fi
  fi

  printf '%s' "$branch"
}

is_protected_branch_name() {
  case "$1" in
    main|master|develop|release/*)
      return 0
      ;;
  esac
  return 1
}

protected_branch_push_msg() {
  case "$1" in
    release/*)
      printf 'default push from release/* branch (use cherry-pick PR flow instead)'
      ;;
    *)
      printf 'default push from protected branch (main/master/develop) per CLAUDE.md'
      ;;
  esac
}

push_option_takes_value() {
  case "$1" in
    --receive-pack|--exec|--repo|--push-option|-o)
      return 0
      ;;
  esac
  return 1
}

# A refspec word the guard cannot read literally could name a protected branch once the
# shell has expanded it: `$BR`, `{main,}`, `refs/heads/*:refs/heads/*`, `$'ma\x69n'` kept
# as text. Any such word fails closed.
push_word_is_unverifiable() {
  case "$1" in
    *'*'*|*'?'*|*'['*|*'{'*|*'}'*|*'$'*|*\\*|*'`'*)
      return 0
      ;;
  esac
  return 1
}

collect_push_positionals() {
  local idx=1 arg saw_remote=0 remote_dynamic=0 after_dashes=0

  PUSH_REFSPECS=()
  PUSH_UNVERIFIABLE=""
  while [ "$idx" -lt "${#NORM_ARGS[@]}" ]; do
    arg="${NORM_ARGS[$idx]}"
    if [ "$after_dashes" -eq 0 ]; then
      case "$arg" in
        --)
          after_dashes=1
          idx=$((idx + 1))
          continue
          ;;
        --receive-pack=*|--exec=*|--repo=*|--push-option=*|-o=*)
          idx=$((idx + 1))
          continue
          ;;
        -*)
          if push_option_takes_value "$arg"; then
            idx=$((idx + 2))
          else
            idx=$((idx + 1))
          fi
          continue
          ;;
      esac
    fi
    if [ "$saw_remote" -eq 0 ]; then
      saw_remote=1
      remote_dynamic="${NORM_DYN[$idx]}"
    else
      PUSH_REFSPECS+=("$arg")
      if [ "${NORM_DYN[$idx]}" -ne 0 ] || push_word_is_unverifiable "$arg"; then
        PUSH_UNVERIFIABLE="$arg"
      fi
    fi
    idx=$((idx + 1))
  done
  # `git push $ARGS` with nothing after the remote slot could be hiding the refspec.
  if [ "$remote_dynamic" -ne 0 ] && [ "${#PUSH_REFSPECS[@]}" -eq 0 ]; then
    PUSH_UNVERIFIABLE='<remote>'
  fi
}

block_implicit_protected_push() {
  local dir branch msg refspec normalized need_branch=0

  if [ "${#PUSH_REFSPECS[@]}" -eq 0 ]; then
    need_branch=1
  else
    for refspec in "${PUSH_REFSPECS[@]}"; do
      normalized="${refspec#+}"
      if [ "$normalized" = "HEAD" ] || [ "$normalized" = "@" ]; then
        need_branch=1
      fi
    done
  fi
  [ "$need_branch" -eq 1 ] || return 0

  # The branch a bare push publishes is HEAD of whichever repository git runs in. A
  # directory this guard cannot read literally, or a GIT_DIR/--work-tree it cannot read,
  # may be a protected branch, so it fails closed instead of reading the hook's own repo.
  if [ "$WORKTREE_OVERRIDE" -ne 0 ] || [ "$GITDIR_DYNAMIC" -ne 0 ] \
    || [[ "$GITDIR_OVERRIDE" == "~"* ]]; then
    block 'push with no explicit branch, but GIT_DIR/--git-dir/--work-tree is not a literal path this guard can read (name the branch: git push origin <branch>)'
  fi
  for dir in "${CANDIDATE_DIRS[@]}"; do
    if [ "$dir" = "?" ]; then
      block 'push with no explicit branch from a directory this guard cannot resolve (cd/pushd/-C with a variable or ~; use git -C <literal path> push origin <branch>)'
    fi
    branch=$(current_git_branch "$dir")
    [ -n "$branch" ] || continue
    is_protected_branch_name "$branch" || continue
    msg=$(protected_branch_push_msg "$branch")
    block "$msg"
  done
}

apply_policy() {
  local subcmd="${NORM_ARGS[0]:-}"
  local protected_ref='((refs/)?heads/)?(main|master|develop)'
  local release_ref='((refs/)?heads/)?release/'
  local remote_ref='[^[:space:]-][^[:space:]]*'
  local protected_msg='push to protected branch (main/master/develop) per CLAUDE.md'
  local release_msg='push to release/* branch (use cherry-pick PR flow instead)'

  if { [ "${NORM_DYN[0]:-0}" -ne 0 ] || [[ "$subcmd" == *[\$\`]* ]]; } \
    && ! positional_forward_is_resolved "$subcmd"; then
    block "git subcommand '$subcmd' uses a variable or substitution this guard cannot verify (use a literal subcommand)"
  fi
  case "$subcmd" in
    reset|clean|branch|checkout|restore|tag|reflog|commit|push|merge|rebase|cherry-pick|config)
      guard_dynamic_flag_words "$subcmd"
      ;;
  esac

  case "$subcmd" in
    reset)
      has_flag "--hard" && block 'git reset --hard (loses uncommitted work)'
      ;;
    clean)
      if { has_short_flag "f" || has_flag "--force"; } && ! git_clean_is_dry_run; then
        block 'git clean -f (deletes untracked files)'
      fi
      ;;
    branch)
      if has_short_flag "D" \
        || { { has_short_flag "d" || has_flag "--delete"; } && { has_short_flag "f" || has_flag "--force"; }; }; then
        block 'git branch -D/--delete --force (force-deletes branch)'
      fi
      ;;
    checkout|restore)
      if has_whole_tree_pathspec; then
        # `git restore --staged` rewrites index entries from HEAD and leaves every file
        # alone, so a whole-tree pathspec cannot discard work there. Adding --worktree,
        # or using it on its own, does touch files and still blocks. `git checkout` has
        # no index-only mode, so it is never exempt.
        if [ "$subcmd" = "restore" ] \
          && has_flag "--staged" && ! has_flag "--worktree"; then
          :
        else
          block 'git checkout/restore . or :/ (discards working tree)'
        fi
      fi
      ;;
    config)
      if has_flag "--global" || has_flag "--system"; then
        # An explicit read-only action is distinguishable from a write, so reading user
        # or system config is allowed. A bare `git config --global some.key` is a read
        # too, but telling that from `git config --global some.key value` needs argument
        # counting rather than a flag, and this guard stays on the conservative end of
        # anything it cannot distinguish.
        if git_config_is_read_only; then
          :
        else
          block 'git config --global/--system (modifies user/system config)'
        fi
      fi
      scan_git_config_args
      ;;
    commit|push|merge|rebase|cherry-pick)
      has_flag "--no-verify" && block 'skipping hooks (--no-verify)'
      ;;
  esac


  case "$subcmd" in
    commit)
      # -n is the short form of --no-verify here. On push, merge, rebase, cherry-pick
      # and clean it means something else (dry run, no stat, no commit).
      has_short_cluster_flag "n" "mFCct" "Su" && block 'skipping hooks (commit -n is --no-verify)'
      ;;
  esac

  case "$subcmd" in
    commit|push)
      has_flag "--no-gpg-sign" && block 'bypassing GPG signing'
      ;;
  esac

  case "$subcmd" in
    tag)
      # Force-overwrite / delete — rewrites a published ref, breaks downstream consumers.
      if has_short_flag "f" || has_short_flag "d" || has_flag "--force" || has_flag "--delete"; then
        block 'git tag -f/-d (overwrites or deletes a tag)'
      fi
      ;;
    reflog)
      # Destroys the recovery safety net that protects unreferenced commits.
      [ "${NORM_ARGS[1]:-}" = "expire" ] && block 'git reflog expire (removes recovery safety net)'
      ;;
  esac

  # Push to protected branches (any form: explicit ref, HEAD:ref, release/*).
  if [ "$subcmd" = "push" ]; then
    collect_push_positionals
    if [ -n "$PUSH_UNVERIFIABLE" ]; then
      block "git push target '$PUSH_UNVERIFIABLE' uses a variable, glob, or brace expansion this guard cannot verify (use a literal branch name)"
    fi
    block_implicit_protected_push
    check "${remote_ref}[[:space:]]+\+?${protected_ref}([[:space:]:]|$)" "$protected_msg"
    check "${remote_ref}[[:space:]]+[^[:space:]]+:\+?${protected_ref}([[:space:]]|$)" "$protected_msg"
    check "HEAD:\+?${protected_ref}([[:space:]]|$)" 'push HEAD to protected branch'
    check "${remote_ref}[[:space:]]+\+?${release_ref}" "$release_msg"
    check "${remote_ref}[[:space:]]+[^[:space:]]+:\+?${release_ref}" "$release_msg"
    check "HEAD:\+?${release_ref}" 'push HEAD to release/* branch (use cherry-pick PR flow instead)'
    if [[ "$NORM_CMD" =~ (--force([[:space:]]|=|$)|--force-with-lease|[[:space:]]-f([[:space:]]|$)) ]]; then
      check "${remote_ref}[[:space:]]+${protected_ref}" 'force push to main/master/develop'
    fi
    # Remote branch deletion via `git push <remote> :<branch>` or `--delete <branch>`.
    check "${remote_ref}[[:space:]]+:[A-Za-z0-9._/-]+([[:space:]]|$)" 'remote branch deletion (push remote :branch)'
    if has_flag "--delete" || has_short_flag "d"; then
      block 'remote branch deletion (push --delete/-d)'
    fi
    has_flag "--mirror" && block 'git push --mirror (rewrites/deletes remote refs)'
    has_flag "--prune" && block 'git push --prune (deletes remote refs missing locally)'
    has_flag "--all" && block 'git push --all (may push protected branches)'
  fi
  return 0
}

apply_command_string() {
  local command_string="$1" field kind
  local -a SCAN_FIELDS=()
  local SCAN_IDX=0 SCAN_VAL=""

  while IFS= read -r -d '' field; do
    SCAN_FIELDS+=("$field")
  done < <(printf '%s' "$command_string" | run_scanner --argv0 git 2>/dev/null)

  if [ "${#SCAN_FIELDS[@]}" -lt 2 ] || [ "${SCAN_FIELDS[$((${#SCAN_FIELDS[@]} - 1))]}" != "END" ]; then
    block 'shell scanner failed (failing closed)'
  fi

  scan_next
  kind="$SCAN_VAL"
  while [ "$SCAN_IDX" -lt $((${#SCAN_FIELDS[@]} - 1)) ]; do
    scan_next
    [ "$SCAN_VAL" = "INV" ] || block 'shell scanner output was malformed (failing closed)'
    apply_scanned_invocation
  done

  # A shell runs the commands before a syntax error, so the invocations above still
  # count. What cannot be judged is the rest: with git named anywhere, refuse.
  if [ "$kind" = "unparseable=1" ] && [[ "$command_string" == *[gG][iI][tT]* ]]; then
    block 'could not safely parse this command and it names git (rewrite it with plain quoting)'
  fi
  return 0
}

scan_nested_command() {
  local nested="$1"

  if [ -n "$nested" ]; then
    apply_command_string "$nested"
  fi
  return 0
}

apply_command_string "$CMD"
