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

command -v jq >/dev/null 2>&1 || exit 0

CMD=$(jq -r '.tool_input.command // empty')

# Hot path: hook fires on every Bash tool call. Most aren't git — short-circuit
# to avoid pattern work on `ls`, `cat`, `python ...`, etc.
[[ -z "$CMD" || "$CMD" != *git* ]] && exit 0

# Anchor `git` to start of command or after a shell separator (; && || |) so
# string literals (`echo "git reset --hard"`, commit messages mentioning
# `git reset --hard`) don't trigger blocks.
G='(^|[;&|][[:space:]]*)git'

block() {
  printf 'BLOCKED: %s\nCommand: %s\nThe user has prevented this operation. Ask before retrying.\n' "$1" "$CMD" >&2
  exit 2
}

check() {
  [[ "$CMD" =~ $1 ]] && block "$2"
  return 0
}

# Always-destructive operations.
check "${G}[[:space:]]+reset[[:space:]]+(([^&|;]*[[:space:]])?--hard)([[:space:]]|$)"            'git reset --hard (loses uncommitted work)'
check "${G}[[:space:]]+clean[[:space:]]+-[a-zA-Z]*f"                                              'git clean -f (deletes untracked files)'
check "${G}[[:space:]]+branch[[:space:]]+-D[[:space:]]"                                           'git branch -D (force-deletes branch)'
check "${G}[[:space:]]+(checkout|restore)[[:space:]]+(--[[:space:]]+)?\.([[:space:]]|$)"          'git checkout/restore . (discards working tree)'
check "${G}[[:space:]]+config[[:space:]]+(--global|--system)"                                     'git config --global/--system (modifies user/system config)'
check "${G}[[:space:]]+(commit|push|merge|rebase|cherry-pick)[[:space:]]+([^&|;]*[[:space:]])?--no-verify([[:space:]]|=|$)" 'skipping hooks (--no-verify)'
check "${G}[[:space:]]+(commit|push)[[:space:]]+([^&|;]*[[:space:]])?--no-gpg-sign([[:space:]]|$)" 'bypassing GPG signing'

# Push to protected branches (any form: explicit ref, HEAD:ref, release/*).
if [[ "$CMD" =~ ${G}[[:space:]]+push ]]; then
  check '(origin|upstream)[[:space:]]+(main|master|develop)([[:space:]:]|$)'           'push to protected branch (main/master/develop) per CLAUDE.md'
  check 'HEAD:(refs/heads/)?(main|master|develop)([[:space:]]|$)'                      'push HEAD to protected branch'
  check '(origin|upstream)[[:space:]]+release/'                                        'push to release/* branch (use cherry-pick PR flow instead)'
  if [[ "$CMD" =~ (--force([[:space:]]|=|$)|--force-with-lease|[[:space:]]-f([[:space:]]|$)) ]]; then
    check '(origin|upstream)[[:space:]]+(main|master|develop)'                         'force push to main/master/develop'
  fi
fi

exit 0
