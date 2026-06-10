#!/usr/bin/env bash
# High-confidence scan for sensitive values in ignored local debug artifacts.

set -uo pipefail

ROOT="${NASE_SENSITIVE_SCAN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT" || exit 1

if ! command -v rg >/dev/null 2>&1; then
  printf 'FAIL: rg is required for sensitive artifact scan.\n' >&2
  exit 1
fi

targets=(
  ".playwright-cli"
  ".playwright-mcp"
  ".omc"
  ".serena"
  ".full-review"
  ".claude/settings.local.json"
  "workspace/tmp"
  "workspace/logs"
  "workspace/cache"
)

existing_targets=()
for target in "${targets[@]}"; do
  if [ -e "$target" ]; then
    existing_targets+=("$target")
  fi
done

if [ "${#existing_targets[@]}" -eq 0 ]; then
  printf 'PASS: no local sensitive artifact directories found.\n'
  exit 0
fi

pattern='([Aa]uthorization[":[:space:]]*[[:space:]]*[Bb]earer[[:space:]]+[A-Za-z0-9._-]{20,}|(access_token|id_token|refresh_token)[A-Za-z0-9_"[:space:]=:-]{0,24}eyJ[A-Za-z0-9._-]+|-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----)'

hits=$(rg -nIl --hidden --no-ignore \
  -g '*.log' \
  -g '*.json' \
  -g '*.md' \
  -g '*.txt' \
  -g '*.yml' \
  -g '*.yaml' \
  -e "$pattern" \
  "${existing_targets[@]}" 2>/dev/null || true)

if [ -n "$hits" ]; then
  printf 'FAIL: sensitive values found in ignored local artifacts. Remove/rotate before sharing this workspace:\n' >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi

printf 'PASS: no sensitive values found in local artifacts.\n'
