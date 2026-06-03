#!/usr/bin/env bash
# Verify every `.claude/docs/<name>.md` and `workspace/skills/docs/<name>.md`
# reference in skill / CLAUDE.md / README files points at an existing file.
# Catches rename/delete drift between skills and their shared docs.
#
# Run from repo root:  bash tests/check-shared-doc-refs.sh
# Exit 0 = all references resolve, exit 1 = at least one missing reference.

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

scan_paths=(
  ".claude/commands/nase"
  ".claude/docs"
  "workspace/skills"
  "CLAUDE.md"
  "README.md"
)

existing_scan_paths=()
for path in "${scan_paths[@]}"; do
  [[ -e "$path" ]] && existing_scan_paths+=("$path")
done

if [[ "${#existing_scan_paths[@]}" -eq 0 ]]; then
  echo "OK: no scan paths found"
  exit 0
fi

# NUL-delimited filenames (-Z) so paths containing `:` parse safely.
pairs=$({ grep -rZoE '(\.claude/docs|workspace/skills/docs)/[a-zA-Z0-9_-]+\.md' "${existing_scan_paths[@]}" 2>/dev/null || true; } \
  | awk -F '\0' 'NF==2 {print $1 "\t" $2}' \
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
  echo "OK: all shared doc references resolve"
  exit 0
fi

printf '\n%d missing reference(s)\n' "$missing" >&2
exit 1
