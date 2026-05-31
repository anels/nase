#!/usr/bin/env bash
# PreToolUse Bash hook — block dangerous git operations.
#
# Aligns with CLAUDE.md rules: never push to protected branches; never run
# destructive ops without explicit user approval; never skip hooks or signing;
# never modify global git config. Pushes to feature branches are allowed so
# /nase:fsd and /nase:prep-merge keep working.
#
# Reads tool_input JSON from stdin, exits 2 to block (stderr reaches Claude).

set -euo pipefail

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

is_assignment() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]
}

is_basename() {
  local word="$1" name="$2"
  [[ "$word" == "$name" || "$word" == */"$name" ]]
}

is_shell_keyword() {
  case "$1" in
    if|then|elif|else|fi|while|until|do|done|for|select|'case'|'esac'|'!')
      return 0
      ;;
  esac
  return 1
}

skip_prefix_wrapper() {
  local idx="$1"
  local word="${WORDS[$idx]}"
  local opt_i value_pos

  NEXT_IDX="$idx"
  case "$word" in
    time)
      idx=$((idx + 1))
      while [ "$idx" -lt "${#WORDS[@]}" ]; do
        case "${WORDS[$idx]}" in
          -p)
            idx=$((idx + 1))
            continue
            ;;
        esac
        break
      done
      ;;
    exec)
      idx=$((idx + 1))
      while [ "$idx" -lt "${#WORDS[@]}" ]; do
        case "${WORDS[$idx]}" in
          --)
            idx=$((idx + 1))
            break
            ;;
          -a)
            idx=$((idx + 2))
            continue
            ;;
          -c|-l)
            idx=$((idx + 1))
            continue
            ;;
        esac
        break
      done
      ;;
    *)
      if is_basename "$word" "sudo" || is_basename "$word" "doas"; then
        idx=$((idx + 1))
        while [ "$idx" -lt "${#WORDS[@]}" ]; do
          word="${WORDS[$idx]}"
          case "$word" in
            --)
              idx=$((idx + 1))
              break
              ;;
            -C|-D|-g|-h|-p|-R|-r|-t|-T|-U|-u|--chdir|--close-from|--command-timeout|--group|--host|--other-user|--prompt|--role|--type|--user)
              idx=$((idx + 2))
              continue
              ;;
            --chdir=*|--close-from=*|--command-timeout=*|--group=*|--host=*|--other-user=*|--prompt=*|--role=*|--type=*|--user=*)
              idx=$((idx + 1))
              continue
              ;;
            -*)
              value_pos=-1
              for ((opt_i=1; opt_i<${#word}; opt_i++)); do
                case "${word:opt_i:1}" in
                  C|D|g|h|p|R|r|t|T|U|u)
                    value_pos="$opt_i"
                    break
                    ;;
                esac
              done
              if [ "$value_pos" -ge 1 ] && [ $((value_pos + 1)) -eq "${#word}" ]; then
                idx=$((idx + 2))
              else
                idx=$((idx + 1))
              fi
              continue
              ;;
          esac
          if is_assignment "$word"; then
            idx=$((idx + 1))
            continue
          fi
          break
        done
      elif is_basename "$word" "nohup"; then
        idx=$((idx + 1))
      elif is_basename "$word" "nice"; then
        idx=$((idx + 1))
        while [ "$idx" -lt "${#WORDS[@]}" ]; do
          word="${WORDS[$idx]}"
          case "$word" in
            --)
              idx=$((idx + 1))
              break
              ;;
            -n|--adjustment)
              idx=$((idx + 2))
              continue
              ;;
            -n*|-[0-9]*|--adjustment=*)
              idx=$((idx + 1))
              continue
              ;;
          esac
          break
        done
      elif is_basename "$word" "arch"; then
        idx=$((idx + 1))
        while [ "$idx" -lt "${#WORDS[@]}" ] && [[ "${WORDS[$idx]}" == -* ]]; do
          idx=$((idx + 1))
        done
      elif is_basename "$word" "xcrun"; then
        idx=$((idx + 1))
        while [ "$idx" -lt "${#WORDS[@]}" ]; do
          word="${WORDS[$idx]}"
          case "$word" in
            --)
              idx=$((idx + 1))
              break
              ;;
            -sdk|-toolchain|-log|--sdk|--toolchain|--log)
              idx=$((idx + 2))
              continue
              ;;
            -sdk=*|-toolchain=*|-log=*|--sdk=*|--toolchain=*|--log=*|--find|--run|--kill-cache|--no-cache|--verbose)
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
      else
        return 1
      fi
      ;;
  esac

  NEXT_IDX="$idx"
  return 0
}

scan_git_config_value() {
  local config_value="$1"
  local key value alias_body

  key="${config_value%%=*}"
  value="${config_value#*=}"
  if [ "$key" = "$config_value" ]; then
    return 0
  fi
  if ! printf '%s' "$key" | grep -qi '^alias\.'; then
    return 0
  fi
  case "$value" in
    '!'*)
      alias_body="${value#!}"
      ;;
    *)
      alias_body="git $value"
      ;;
  esac
  scan_nested_command "$alias_body"
}

scan_git_config_env_arg() {
  local config_env="$1"
  local key="${config_env%%=*}"

  if printf '%s' "$key" | grep -qi '^alias\.'; then
    block 'git --config-env alias.* (hidden alias body can bypass git safety checks)'
  fi
}

split_segments() {
  local input="$1"
  local len=${#input}
  local i=0 start=0 quote="" ch next segment

  SEGMENTS=()
  while [ "$i" -lt "$len" ]; do
    ch="${input:i:1}"
    next=""
    if [ $((i + 1)) -lt "$len" ]; then
      next="${input:i+1:1}"
    fi

    if [ -n "$quote" ]; then
      if [ "$quote" = '"' ] && [ "$ch" = "\\" ]; then
        i=$((i + 2))
        continue
      fi
      if [ "$ch" = "$quote" ]; then
        quote=""
      fi
      i=$((i + 1))
      continue
    fi

    if [ "$ch" = "$" ] && { [ "$next" = "'" ] || [ "$next" = '"' ]; }; then
      quote="$next"
      i=$((i + 2))
      continue
    fi

    case "$ch" in
      "'"|'"')
        quote="$ch"
        ;;
      ';'|$'\n'|'|'|'('|')'|'{'|'}')
        segment="${input:start:i-start}"
        SEGMENTS+=("$segment")
        if [ "$ch" = "|" ] && [ "$next" = "|" ]; then
          i=$((i + 1))
        fi
        start=$((i + 1))
        ;;
      '&')
        segment="${input:start:i-start}"
        SEGMENTS+=("$segment")
        if [ "$next" = "&" ]; then
          i=$((i + 1))
        fi
        start=$((i + 1))
        ;;
    esac
    i=$((i + 1))
  done

  SEGMENTS+=("${input:start}")
}

split_words() {
  local input="$1"
  local len=${#input}
  local i=0 quote="" ch next current=""

  WORDS=()
  while [ "$i" -lt "$len" ]; do
    ch="${input:i:1}"
    next=""
    if [ $((i + 1)) -lt "$len" ]; then
      next="${input:i+1:1}"
    fi

    if [ -n "$quote" ]; then
      if [ "$quote" = '"' ] && [ "$ch" = "\\" ] && [ -n "$next" ]; then
        current+="$next"
        i=$((i + 2))
        continue
      fi
      if [ "$ch" = "$quote" ]; then
        quote=""
      else
        current+="$ch"
      fi
      i=$((i + 1))
      continue
    fi

    if [ "$ch" = "$" ] && { [ "$next" = "'" ] || [ "$next" = '"' ]; }; then
      quote="$next"
      i=$((i + 2))
      continue
    fi

    case "$ch" in
      "'"|'"')
        quote="$ch"
        ;;
      [[:space:]])
        if [ -n "$current" ]; then
          WORDS+=("$current")
          current=""
        fi
        ;;
      "\\")
        if [ -n "$next" ]; then
          current+="$next"
          i=$((i + 1))
        fi
        ;;
      *)
        current+="$ch"
        ;;
    esac
    i=$((i + 1))
  done

  if [ -n "$current" ]; then
    WORDS+=("$current")
  fi
}

normalize_segment() {
  local segment="$1"
  local idx=0 word found_git=0

  split_words "$segment"
  [ "${#WORDS[@]}" -gt 0 ] || return 1

  while [ "$idx" -lt "${#WORDS[@]}" ]; do
    word="${WORDS[$idx]}"

    if is_assignment "$word"; then
      idx=$((idx + 1))
      continue
    fi

    if is_shell_keyword "$word"; then
      idx=$((idx + 1))
      continue
    fi

    if skip_prefix_wrapper "$idx"; then
      idx="$NEXT_IDX"
      continue
    fi

    if [ "$word" = "command" ]; then
      idx=$((idx + 1))
      if [ "$idx" -lt "${#WORDS[@]}" ] && [ "${WORDS[$idx]}" = "-p" ]; then
        idx=$((idx + 1))
      fi
      if [ "$idx" -lt "${#WORDS[@]}" ] && [ "${WORDS[$idx]}" = "--" ]; then
        idx=$((idx + 1))
      fi
      continue
    fi

    if is_basename "$word" "env"; then
      idx=$((idx + 1))
      while [ "$idx" -lt "${#WORDS[@]}" ]; do
        word="${WORDS[$idx]}"
        case "$word" in
          -i|--ignore-environment|--unset=*|--chdir=*)
            idx=$((idx + 1))
            continue
            ;;
          --)
            idx=$((idx + 1))
            break
            ;;
          -u|--unset|-C|--chdir)
            idx=$((idx + 2))
            continue
            ;;
        esac
        if is_assignment "$word"; then
          idx=$((idx + 1))
          continue
        fi
        break
      done
      continue
    fi

    if is_basename "$word" "git"; then
      found_git=1
      idx=$((idx + 1))
      break
    fi

    return 1
  done

  if [ "$found_git" -ne 1 ]; then
    return 1
  fi

  while [ "$idx" -lt "${#WORDS[@]}" ]; do
    word="${WORDS[$idx]}"
    case "$word" in
      -c)
        if [ $((idx + 1)) -lt "${#WORDS[@]}" ]; then
          scan_git_config_value "${WORDS[$((idx + 1))]}"
        fi
        idx=$((idx + 2))
        ;;
      --config-env)
        if [ $((idx + 1)) -lt "${#WORDS[@]}" ]; then
          scan_git_config_env_arg "${WORDS[$((idx + 1))]}"
        fi
        idx=$((idx + 2))
        ;;
      -C|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix|--attr-source)
        idx=$((idx + 2))
        ;;
      --config-env=*)
        scan_git_config_env_arg "${word#--config-env=}"
        idx=$((idx + 1))
        ;;
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|--super-prefix=*|--attr-source=*|--list-cmds=*)
        idx=$((idx + 1))
        ;;
      -p|-P|--paginate|--no-pager|--bare|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--no-replace-objects|--no-optional-locks|--no-lazy-fetch)
        idx=$((idx + 1))
        ;;
      *)
        break
        ;;
    esac
  done

  NORM_CMD="git"
  NORM_ARGS=()
  while [ "$idx" -lt "${#WORDS[@]}" ]; do
    NORM_ARGS+=("${WORDS[$idx]}")
    NORM_CMD+=" ${WORDS[$idx]}"
    idx=$((idx + 1))
  done
  return 0
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
    [[ "$arg" == "$flag" || "$arg" == "$flag="* ]] && return 0
  done
  return 1
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

scan_git_config_alias_args() {
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
  value="${NORM_ARGS[$((idx + 1))]:-}"
  scan_git_config_value "$key=$value"
}

apply_policy() {
  local subcmd="${NORM_ARGS[0]:-}"
  local protected_ref='(refs/heads/)?(main|master|develop)'
  local release_ref='(refs/heads/)?release/'
  local remote_ref='[^[:space:]-][^[:space:]]*'
  local protected_msg='push to protected branch (main/master/develop) per CLAUDE.md'
  local release_msg='push to release/* branch (use cherry-pick PR flow instead)'

  case "$subcmd" in
    reset)
      has_flag "--hard" && block 'git reset --hard (loses uncommitted work)'
      ;;
    clean)
      if has_short_flag "f" || has_flag "--force"; then
        block 'git clean -f (deletes untracked files)'
      fi
      ;;
    branch)
      if has_short_flag "D" || { has_flag "--delete" && has_flag "--force"; }; then
        block 'git branch -D/--delete --force (force-deletes branch)'
      fi
      ;;
    checkout|restore)
      if has_arg "." || has_arg ":/" || has_arg ":(top)"; then
        block 'git checkout/restore . or :/ (discards working tree)'
      fi
      ;;
    config)
      if has_flag "--global" || has_flag "--system"; then
        block 'git config --global/--system (modifies user/system config)'
      fi
      scan_git_config_alias_args
      ;;
    commit|push|merge|rebase|cherry-pick)
      has_flag "--no-verify" && block 'skipping hooks (--no-verify)'
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
  local command_string="$1" segment
  local -a segments_copy

  split_segments "$command_string"
  segments_copy=("${SEGMENTS[@]}")
  for segment in "${segments_copy[@]}"; do
    scan_indirect_command_segment "$segment"
    if normalize_segment "$segment"; then
      apply_policy
    fi
  done
}

scan_nested_command() {
  local nested="$1"

  if [ -n "$nested" ]; then
    apply_command_string "$nested"
    scan_command_substitutions "$nested"
  fi
}

join_words_from() {
  local idx="$1"
  local out=""

  while [ "$idx" -lt "${#WORDS[@]}" ]; do
    if [ -z "$out" ]; then
      out="${WORDS[$idx]}"
    else
      out+=" ${WORDS[$idx]}"
    fi
    idx=$((idx + 1))
  done
  printf '%s' "$out"
}

scan_indirect_command_segment() {
  local segment="$1"
  local idx=0 word arg nested

  split_words "$segment"
  [ "${#WORDS[@]}" -gt 0 ] || return 0

  while [ "$idx" -lt "${#WORDS[@]}" ]; do
    word="${WORDS[$idx]}"

    if is_assignment "$word" || is_shell_keyword "$word"; then
      idx=$((idx + 1))
      continue
    fi

    if skip_prefix_wrapper "$idx"; then
      idx="$NEXT_IDX"
      continue
    fi

    if [ "$word" = "command" ]; then
      idx=$((idx + 1))
      if [ "$idx" -lt "${#WORDS[@]}" ] && [ "${WORDS[$idx]}" = "-p" ]; then
        idx=$((idx + 1))
      fi
      if [ "$idx" -lt "${#WORDS[@]}" ] && [ "${WORDS[$idx]}" = "--" ]; then
        idx=$((idx + 1))
      fi
      continue
    fi

    if is_basename "$word" "env"; then
      idx=$((idx + 1))
      while [ "$idx" -lt "${#WORDS[@]}" ]; do
        word="${WORDS[$idx]}"
        case "$word" in
          -i|--ignore-environment|--unset=*|--chdir=*)
            idx=$((idx + 1))
            continue
            ;;
          --)
            idx=$((idx + 1))
            break
            ;;
          -u|--unset|-C|--chdir)
            idx=$((idx + 2))
            continue
            ;;
          -S|--split-string)
            idx=$((idx + 1))
            if [ "$idx" -lt "${#WORDS[@]}" ]; then
              scan_nested_command "${WORDS[$idx]}"
            fi
            return 0
            ;;
          --split-string=*)
            nested="${word#--split-string=}"
            scan_nested_command "$nested"
            return 0
            ;;
        esac
        if is_assignment "$word"; then
          idx=$((idx + 1))
          continue
        fi
        break
      done
      continue
    fi

    break
  done

  [ "$idx" -lt "${#WORDS[@]}" ] || return 0
  word="${WORDS[$idx]}"

  if is_basename "$word" "eval"; then
    idx=$((idx + 1))
    nested=$(join_words_from "$idx")
    scan_nested_command "$nested"
    return 0
  fi

  if is_basename "$word" "bash" || is_basename "$word" "sh" || is_basename "$word" "zsh" || is_basename "$word" "dash" || is_basename "$word" "ksh"; then
    idx=$((idx + 1))
    while [ "$idx" -lt "${#WORDS[@]}" ]; do
      arg="${WORDS[$idx]}"
      if [ "$arg" = "--" ]; then
        return 0
      fi
      if [ "$arg" = "-c" ] || [[ "$arg" == -[!-]*c* ]]; then
        idx=$((idx + 1))
        if [ "$idx" -lt "${#WORDS[@]}" ]; then
          scan_nested_command "${WORDS[$idx]}"
        fi
        return 0
      fi
      case "$arg" in
        -O|+O|-o|+o|--rcfile|--init-file)
          idx=$((idx + 2))
          continue
          ;;
      esac
      if [[ "$arg" == -* ]]; then
        idx=$((idx + 1))
        continue
      fi
      return 0
    done
  fi
}

find_matching_paren() {
  local input="$1"
  local start_pos="$2"
  local len=${#input}
  local i=$((start_pos + 2))
  local depth=1 quote="" ch next

  while [ "$i" -lt "$len" ]; do
    ch="${input:i:1}"
    next=""
    if [ $((i + 1)) -lt "$len" ]; then
      next="${input:i+1:1}"
    fi

    if [ -n "$quote" ]; then
      case "$quote" in
        "'")
          [ "$ch" = "'" ] && quote=""
          ;;
        '"')
          if [ "$ch" = "\\" ]; then
            i=$((i + 2))
            continue
          fi
          [ "$ch" = '"' ] && quote=""
          ;;
        '`')
          if [ "$ch" = "\\" ]; then
            i=$((i + 2))
            continue
          fi
          [ "$ch" = '`' ] && quote=""
          ;;
      esac
      i=$((i + 1))
      continue
    fi

    case "$ch" in
      "'"|'"'|'`')
        quote="$ch"
        ;;
      '$'|'<'|'>')
        if [ "$next" = "(" ]; then
          depth=$((depth + 1))
          i=$((i + 1))
        fi
        ;;
      ')')
        depth=$((depth - 1))
        if [ "$depth" -eq 0 ]; then
          MATCH_END="$i"
          return 0
        fi
        ;;
    esac
    i=$((i + 1))
  done
  return 1
}

find_matching_backtick() {
  local input="$1"
  local start_pos="$2"
  local len=${#input}
  local i=$((start_pos + 1))
  local ch

  while [ "$i" -lt "$len" ]; do
    ch="${input:i:1}"
    if [ "$ch" = "\\" ]; then
      i=$((i + 2))
      continue
    fi
    if [ "$ch" = '`' ]; then
      MATCH_END="$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

scan_command_substitutions() {
  local input="$1"
  local len=${#input}
  local i=0 quote="" ch next body_start body_len body

  while [ "$i" -lt "$len" ]; do
    ch="${input:i:1}"
    next=""
    if [ $((i + 1)) -lt "$len" ]; then
      next="${input:i+1:1}"
    fi

    if [ "$quote" = "'" ]; then
      [ "$ch" = "'" ] && quote=""
      i=$((i + 1))
      continue
    fi

    if [ "$quote" = '"' ]; then
      if [ "$ch" = "\\" ]; then
        i=$((i + 2))
        continue
      fi
      if [ "$ch" = '"' ]; then
        quote=""
        i=$((i + 1))
        continue
      fi
    elif [ "$ch" = "'" ] || [ "$ch" = '"' ]; then
      quote="$ch"
      i=$((i + 1))
      continue
    fi

    if [ "$ch" = "\\" ]; then
      i=$((i + 2))
      continue
    fi

    if [ "$ch" = '$' ] && [ "$next" = "(" ]; then
      if find_matching_paren "$input" "$i"; then
        body_start=$((i + 2))
        body_len=$((MATCH_END - body_start))
        body="${input:body_start:body_len}"
        scan_nested_command "$body"
        i=$((MATCH_END + 1))
        continue
      fi
    elif [ "$ch" = '`' ]; then
      if find_matching_backtick "$input" "$i"; then
        body_start=$((i + 1))
        body_len=$((MATCH_END - body_start))
        body="${input:body_start:body_len}"
        scan_nested_command "$body"
        i=$((MATCH_END + 1))
        continue
      fi
    elif [ -z "$quote" ] && { [ "$ch" = "<" ] || [ "$ch" = ">" ]; } && [ "$next" = "(" ]; then
      if find_matching_paren "$input" "$i"; then
        body_start=$((i + 2))
        body_len=$((MATCH_END - body_start))
        body="${input:body_start:body_len}"
        scan_nested_command "$body"
        i=$((MATCH_END + 1))
        continue
      fi
    fi

    i=$((i + 1))
  done
}

apply_command_string "$CMD"
scan_command_substitutions "$CMD"

exit 0
