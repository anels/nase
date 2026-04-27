#!/usr/bin/env bash
# Verify every `.claude/docs/<name>.md` reference in skill / CLAUDE.md / README
# files points at an existing file. Catches rename/delete drift between skills
# and their shared docs.
#
# Run from repo root:  bash tests/check-shared-doc-refs.sh
# Exit 0 = all references resolve, exit 1 = at least one missing reference.

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

scan_paths=(
  ".claude/commands/nase"
  ".claude/docs"
  "CLAUDE.md"
  "README.md"
)

# Collect (source_file, doc_ref) pairs, deduped via sort -u.
# `grep -rnoE` prints `path:lineno:match`; awk strips path and emits
# tab-separated (path, match) so we keep the source for the failure message.
pairs=$(grep -rnoE '\.claude/docs/[a-zA-Z0-9_-]+\.md' "${scan_paths[@]}" 2>/dev/null \
  | awk -F: '{print $1 "\t" $NF}' \
  | sort -u)

missing=0
while IFS=$'\t' read -r src ref; do
  [[ -z "$src" || -z "$ref" ]] && continue
  if [[ ! -f "$ref" ]]; then
    printf 'MISSING  %s -> %s\n' "$src" "$ref"
    missing=$((missing+1))
  fi
done <<< "$pairs"

if [[ "$missing" -eq 0 ]]; then
  echo "OK: all .claude/docs/*.md references resolve"
  exit 0
fi

printf '\n%d missing reference(s)\n' "$missing" >&2
exit 1
