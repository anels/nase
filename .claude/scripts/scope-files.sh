#!/usr/bin/env bash
# scope-files.sh — Resolve the "recently modified files" scope for cleanup passes
#
# Usage: bash .claude/scripts/scope-files.sh "<arguments>" [repo-path]
# Output (stdout): deduplicated file paths, one per line (empty output = nothing in scope)
# Exit: always 0 — an unusable repo or missing ref resolves to an empty scope, and the
# caller decides what an empty scope means.
#
# Paths are relative to the repo, so pass the repo path when the caller works on a
# checkout other than the current directory.
#
# Scope selection, matched against the lowercased argument string in this order:
#   --scope=<glob>            tracked + untracked files matching the glob
#   ...unstaged...            unstaged tracked changes + untracked files
#   ...staged...              staged changes only
#   ...last-commit/last commit  HEAD~1..HEAD
#   (anything else)           merge-base with origin/<default> + staged + unstaged + untracked
#
# Selection matching is case-insensitive, but the glob keeps the case it was typed in:
# git paths are case-sensitive, so lowercasing the glob would silently miss files.

set -uo pipefail

ARGUMENTS="${1-}"
REPO="${2-.}"
LOWER=$(printf '%s' "$ARGUMENTS" | tr '[:upper:]' '[:lower:]')

git() { command git -C "$REPO" "$@"; }

git fetch origin --quiet || true
DEFAULT=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
[ -z "$DEFAULT" ] && DEFAULT=main
BASE_REF="origin/$DEFAULT"
MERGE_BASE=$(git merge-base HEAD "$BASE_REF" 2>/dev/null || git rev-parse HEAD)

case "$LOWER" in
  *--scope=*) # Locate the glob in the lowercased copy, then slice the same tail out of
              # the raw string so the flag may be spelled in any case.
              TAIL="${LOWER##*--scope=}"
              GLOB="${ARGUMENTS:$(( ${#ARGUMENTS} - ${#TAIL} ))}"
              GLOB="${GLOB%% *}"
              FILES=$({
                git ls-files -- "$GLOB"
                git ls-files --others --exclude-standard -- "$GLOB"
              } | sort -u) ;;
  *unstaged*) FILES=$({
                git diff --name-only
                git ls-files --others --exclude-standard
              } | sort -u) ;;
  *staged*)   FILES=$(git diff --name-only --cached | sort -u) ;;
  *"last-commit"*|*"last commit"*)
              FILES=$(git diff --name-only HEAD~1 HEAD | sort -u) ;;
  *)          FILES=$({
                git diff --name-only "$MERGE_BASE" HEAD
                git diff --name-only
                git diff --name-only --cached
                git ls-files --others --exclude-standard
              } | sort -u) ;;
esac

[ -n "$FILES" ] && printf '%s\n' "$FILES"
exit 0
