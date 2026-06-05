#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

SCRIPT=".claude/scripts/extensions-check.sh"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

failures=0

pass() {
  printf 'PASS  %s\n' "$1"
}

fail() {
  printf 'FAIL  %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_cmd() {
  local name="$1"
  shift
  if "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
}

workspace="$TMPDIR_TEST/repo"
mkdir -p "$workspace/.claude"
cat > "$workspace/.claude/extensions.yml" <<'YAML'
schema_version: "1.0"
hooks:
  before_fsd:
    - command: /nase:onboard
      description: Refresh repo KB
      optional: true
    - command: /nase:design
      description: Lock design first
      optional: false
    - command: /nase:disabled
      description: Disabled hook
      enabled: false
YAML

out=$(WORKSPACE="$workspace" bash "$SCRIPT" before_fsd)
assert_cmd "optional hook emitted" grep -q '^OPTIONAL_HOOK: /nase:onboard — Refresh repo KB$' <<<"$out"
assert_cmd "mandatory hook emitted" grep -q '^EXECUTE_COMMAND: /nase:design — Lock design first$' <<<"$out"
assert_cmd "disabled hook skipped" bash -c '! grep -q disabled <<<"$1"' _ "$out"

no_hooks=$(WORKSPACE="$workspace" bash "$SCRIPT" after_fsd)
assert_cmd "missing event emits NO_HOOKS" test "$no_hooks" = "NO_HOOKS"

cat > "$workspace/.claude/extensions.yml" <<'YAML'
schema_version: "1.0"
hooks: {}
YAML
empty_hooks=$(WORKSPACE="$workspace" bash "$SCRIPT" before_fsd)
assert_cmd "empty hooks emits NO_HOOKS" test "$empty_hooks" = "NO_HOOKS"

cat > "$workspace/.claude/extensions.yml" <<'YAML'
schema_version: "1.0"
hooks: []
YAML
invalid_shape=$(WORKSPACE="$workspace" bash "$SCRIPT" before_fsd)
assert_cmd "invalid hooks shape emits NO_HOOKS" test "$invalid_shape" = "NO_HOOKS"

if [[ "$failures" -eq 0 ]]; then
  printf '\nextensions-check tests passed.\n'
  exit 0
fi

printf '\n%d extensions-check assertion(s) failed.\n' "$failures" >&2
exit 1
