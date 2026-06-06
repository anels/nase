#!/usr/bin/env bash
# Regression tests for .claude/hooks/session-start.sh
#
# Run from repo root:  bash tests/hooks/test-session-start.sh

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
HOOK="$ROOT/.claude/hooks/session-start.sh"

pass=0
fail=0

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    printf 'PASS  %s\n' "$desc"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s\n      missing: %s\n      out: %s\n' "$desc" "$needle" "$haystack" >&2
    fail=$((fail + 1))
  fi
}

assert_json_reload() {
  local desc="$1" output="$2"
  if jq -e '.hookSpecificOutput.hookEventName == "SessionStart" and .hookSpecificOutput.reloadSkills == true' >/dev/null 2>&1 <<<"$output"; then
    printf 'PASS  %s\n' "$desc"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s\n      out: %s\n' "$desc" "$output" >&2
    fail=$((fail + 1))
  fi
}

assert_lte() {
  local desc="$1" actual="$2" max="$3"
  if [ "$actual" -le "$max" ]; then
    printf 'PASS  %s\n' "$desc"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s\n      expected <= %s, got %s\n' "$desc" "$max" "$actual" >&2
    fail=$((fail + 1))
  fi
}

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

repo="$fixture/repo"
mkdir -p "$repo/.claude/hooks" "$repo/workspace/logs" "$repo/workspace/skills"
git -C "$repo" init -q
cp "$HOOK" "$repo/.claude/hooks/session-start.sh"
printf '%s\n' '2026-05-28T00:00:00 [WARNING] backup target unavailable' > "$repo/workspace/logs/.backup-status"
printf 'backup-target=%s\n' "$fixture/backups" > "$repo/.local-paths"

cat > "$repo/workspace/skills/read-only.md" <<'SKILL'
---
description: Read-only skill with "quotes" and C:\tmp\skill
allowed-tools: Bash(read-only:*)
disallowed-tools:
  - Bash
  - Edit
---

Read only.
SKILL

cat > "$repo/workspace/skills/long-desc.md" <<'SKILL'
---
description: This workspace skill has an intentionally long description that should keep the useful trigger terms near the front while avoiding a generated command wrapper that puts an entire paragraph into slash command metadata and wastes context across future sessions when command descriptions are listed for model routing.
---

The full skill body still lives here and should not be truncated by session-start.
SKILL

out=$(cd "$repo" && bash .claude/hooks/session-start.sh)
rc=$?
if [ "$rc" -eq 0 ]; then
  printf 'PASS  session-start exits cleanly\n'
  pass=$((pass + 1))
else
  printf 'FAIL  session-start exits cleanly (rc=%s)\n      out: %s\n' "$rc" "$out" >&2
  fail=$((fail + 1))
fi

wrapper="$repo/.claude/commands/nase/workspace/read-only.md"
if [ -f "$wrapper" ]; then
  printf 'PASS  workspace wrapper generated\n'
  pass=$((pass + 1))
  content=$(cat "$wrapper")
  assert_contains "wrapper escapes quotes" "$content" 'description: "Read-only skill with \"quotes\" and C:\\tmp\\skill"'
  assert_contains "inline allowed-tools forwarded" "$content" "allowed-tools: Bash(read-only:*)"
  assert_contains "list disallowed-tools key forwarded" "$content" "disallowed-tools:"
  assert_contains "list disallowed-tools Bash forwarded" "$content" "  - Bash"
  assert_contains "list disallowed-tools Edit forwarded" "$content" "  - Edit"
else
  printf 'FAIL  workspace wrapper generated\n' >&2
  fail=$((fail + 1))
fi

long_wrapper="$repo/.claude/commands/nase/workspace/long-desc.md"
if [ -f "$long_wrapper" ]; then
  printf 'PASS  long description wrapper generated\n'
  pass=$((pass + 1))
  long_desc_line=$(grep '^description: "' "$long_wrapper" || true)
  long_desc=${long_desc_line#description: \"}
  long_desc=${long_desc%\"}
  assert_lte "long description is capped" "${#long_desc}" 240
  assert_contains "long description keeps trigger terms" "$long_desc" "workspace skill"
  assert_contains "long description indicates truncation" "$long_desc" "..."
else
  printf 'FAIL  long description wrapper generated\n' >&2
  fail=$((fail + 1))
fi

assert_json_reload "reloadSkills true after wrapper sync" "$out"
assert_contains "warning-only backup status does not abort" "$out" "no successful backup recorded yet"
assert_contains "backup-target-only local paths does not abort" "$out" "backup target not reachable"

printf '\n--- %s pass, %s fail ---\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
