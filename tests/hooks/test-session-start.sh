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
  local expected="${3:-true}"
  if jq -e --argjson expected "$expected" '.hookSpecificOutput.hookEventName == "SessionStart" and .hookSpecificOutput.reloadSkills == $expected' >/dev/null 2>&1 <<<"$output"; then
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

assert_equals() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    printf 'PASS  %s\n' "$desc"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s\n      expected %s, got %s\n' "$desc" "$expected" "$actual" >&2
    fail=$((fail + 1))
  fi
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
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

cat > "$repo/workspace/skills/multiline-desc.md" <<'SKILL'
---
description: |
  Multiline workspace skill keeps discovery terms.
  Trigger on alpha beta gamma.
allowed-tools: Bash(multiline:*)
---

The full skill body still lives here.
SKILL

mkdir -p "$repo/.claude/commands/nase/workspace"
mkdir -p "$repo/.claude/skills/playwright-cli" "$repo/.claude/skills/nase-workspace-orphan"
cat > "$repo/.claude/commands/nase/workspace/long-desc.md" <<'WRAPPER'
---
name: nase:workspace:long-desc
description: "This stale generated wrapper is intentionally much longer than the current cap and should be regenerated even when its filesystem timestamp is newer than the source skill file. If session-start only compares mtimes, this stale description remains loaded into slash command metadata and wastes context."
---

Read `workspace/skills/long-desc.md` and follow every step exactly as written.

$ARGUMENTS
WRAPPER
touch -t 299901010000 "$repo/.claude/commands/nase/workspace/long-desc.md"
cat > "$repo/.claude/skills/playwright-cli/SKILL.md" <<'SKILL'
---
description: Hand-written local skill.
---

Keep me.
SKILL
cat > "$repo/.claude/skills/nase-workspace-orphan/SKILL.md" <<'SKILL'
---
description: Old generated skill.
user-invocable: false
---

<!-- NASE-GENERATED-WORKSPACE-SKILL; source: workspace/skills/orphan.md -->

Delete me.
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
  assert_equals "workspace wrapper mode is readable" "$(file_mode "$wrapper")" "644"
else
  printf 'FAIL  workspace wrapper generated\n' >&2
  fail=$((fail + 1))
fi

native_skill="$repo/.claude/skills/nase-workspace-read-only/SKILL.md"
if [ -f "$native_skill" ]; then
  printf 'PASS  native workspace skill generated\n'
  pass=$((pass + 1))
  native_content=$(cat "$native_skill")
  assert_contains "native skill has generated marker" "$native_content" "<!-- NASE-GENERATED-WORKSPACE-SKILL; source: workspace/skills/read-only.md -->"
  assert_contains "native skill is hidden from slash commands" "$native_content" "user-invocable: false"
  assert_contains "native skill forwards allowed-tools" "$native_content" "allowed-tools: Bash(read-only:*)"
  assert_contains "native skill forwards disallowed-tools" "$native_content" "disallowed-tools:"
  assert_contains "native skill keeps source body" "$native_content" "Read only."
  assert_equals "native skill file mode is readable" "$(file_mode "$native_skill")" "644"
else
  printf 'FAIL  native workspace skill generated\n' >&2
  fail=$((fail + 1))
fi

if [ -f "$repo/.claude/skills/playwright-cli/SKILL.md" ]; then
  printf 'PASS  hand-written local skill preserved\n'
  pass=$((pass + 1))
else
  printf 'FAIL  hand-written local skill preserved\n' >&2
  fail=$((fail + 1))
fi

if [ ! -e "$repo/.claude/skills/nase-workspace-orphan" ]; then
  printf 'PASS  orphaned generated native skill removed\n'
  pass=$((pass + 1))
else
  printf 'FAIL  orphaned generated native skill removed\n' >&2
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
  assert_equals "rewritten stale wrapper mode is readable" "$(file_mode "$long_wrapper")" "644"
else
  printf 'FAIL  long description wrapper generated\n' >&2
  fail=$((fail + 1))
fi

multiline_wrapper="$repo/.claude/commands/nase/workspace/multiline-desc.md"
if [ -f "$multiline_wrapper" ]; then
  printf 'PASS  multiline description wrapper generated\n'
  pass=$((pass + 1))
  multiline_content=$(cat "$multiline_wrapper")
  assert_contains "multiline description keeps content" "$multiline_content" 'description: "Multiline workspace skill keeps discovery terms. Trigger on alpha beta gamma."'
  assert_contains "multiline allowed-tools forwarded" "$multiline_content" "allowed-tools: Bash(multiline:*)"
else
  printf 'FAIL  multiline description wrapper generated\n' >&2
  fail=$((fail + 1))
fi

assert_json_reload "reloadSkills true after wrapper sync" "$out"
assert_contains "warning-only backup status does not abort" "$out" "no successful backup recorded yet"
assert_contains "backup-target-only local paths does not abort" "$out" "backup target not reachable"

chmod 0600 "$wrapper"
out=$(cd "$repo" && bash .claude/hooks/session-start.sh)
rc=$?
if [ "$rc" -eq 0 ]; then
  printf 'PASS  session-start exits cleanly on mode-only repair\n'
  pass=$((pass + 1))
else
  printf 'FAIL  session-start exits cleanly on mode-only repair (rc=%s)\n      out: %s\n' "$rc" "$out" >&2
  fail=$((fail + 1))
fi
assert_equals "unchanged wrapper mode is repaired" "$(file_mode "$wrapper")" "644"
assert_json_reload "mode-only repair does not reload skills" "$out" false

printf '\n--- %s pass, %s fail ---\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
