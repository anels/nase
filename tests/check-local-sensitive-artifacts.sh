#!/usr/bin/env bash
# High-confidence scan for sensitive values in ignored local debug artifacts.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

if ! command -v rg >/dev/null 2>&1; then
  printf 'SKIP: rg not installed locally; sensitive artifact scan not run.\n'
  exit 0
fi

target=".playwright-cli"
if [ ! -e "$target" ]; then
  printf 'PASS: no local sensitive artifact directories found.\n'
  exit 0
fi

pattern='(access_token|id_token|refresh_token)=eyJ[A-Za-z0-9._-]+|Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]{20,}|-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----'

hits=$(rg -nIl --hidden --no-ignore \
  -g '*.log' \
  -g '*.json' \
  -g '*.txt' \
  -g '*.yml' \
  -g '*.yaml' \
  -e "$pattern" \
  "$target" 2>/dev/null || true)

if [ -n "$hits" ]; then
  printf 'FAIL: sensitive values found in ignored local artifacts. Remove/rotate before sharing this workspace:\n' >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi

printf 'PASS: no sensitive values found in local artifacts.\n'
