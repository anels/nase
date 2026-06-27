#!/usr/bin/env bash
# Regression tests for .claude/scripts/help-summary.py.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/help-summary.py"
CATALOG="$ROOT/.claude/scripts/command_catalog.py"
HELP_COMMAND="$ROOT/.claude/commands/nase/help.md"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

pass=0
fail=0

assert_contains() {
  local desc="$1" actual="$2" needle="$3"
  if printf '%s' "$actual" | grep -qF "$needle"; then
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n  expected to contain: %s\n  actual: %s\n' "$desc" "$needle" "$actual" >&2
  fi
}

assert_not_contains() {
  local desc="$1" actual="$2" needle="$3"
  if printf '%s' "$actual" | grep -qF "$needle"; then
    fail=$((fail + 1))
    printf 'FAIL  %s\n  expected NOT to contain: %s\n  actual: %s\n' "$desc" "$needle" "$actual" >&2
  else
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$desc"
  fi
}

assert_even_backticks() {
  local desc="$1" actual="$2" bad
  bad=$(printf '%s\n' "$actual" | python3 -c 'import sys; print("\n".join(f"{i}:{line.rstrip()}" for i,line in enumerate(sys.stdin,1) if line.count("`") % 2))')
  if [ -z "$bad" ]; then
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n  odd backtick lines:\n%s\n' "$desc" "$bad" >&2
  fi
}

mkdir -p "$FIXTURE/.claude/commands/nase" "$FIXTURE/workspace/kb/general" "$FIXTURE/workspace/kb/projects" "$FIXTURE/workspace/tasks" "$FIXTURE/workspace/logs" "$FIXTURE/workspace/skills"
touch "$FIXTURE/workspace/kb/general/workflow.md"
touch "$FIXTURE/workspace/kb/projects/repo.md"
touch "$FIXTURE/workspace/tasks/lessons.md"
touch "$FIXTURE/workspace/skills/alpha.md" "$FIXTURE/workspace/skills/beta.md"

create_command() {
  local name="$1" category="$2" order="$3" description="$4" frontmatter_name="${5:-nase:${1}}"
  cat > "$FIXTURE/.claude/commands/nase/${name}.md" <<EOF
---
name: ${frontmatter_name}
description: "${description}"
pattern: utility
category: ${category}
order: ${order}
---

# ${name}
EOF
}

create_command a "Setup & health" 1 "command a" "frontmatter:name-is-not-command"
create_command b "Setup & health" 2 "command b has a deliberately long purpose"
create_command c "Setup & health" 3 "command c"
create_command d "Setup & health" 4 "command d"
create_command e "Setup & health" 5 "command e"
create_command f "Setup & health" 6 "command f"
create_command g "Reporting" 1 "command g"

cat > "$FIXTURE/README.md" <<'EOF'
# fixture

Fixture workspace intro paragraph.

## Hooks at a glance

Full hook table text.

## Other section
EOF

out=$(python3 "$SCRIPT" --root "$FIXTURE" --command-limit 5 2>&1)
rc=$?
if [ "$rc" = 0 ]; then
  pass=$((pass + 1))
  printf 'PASS  compact exits 0\n'
else
  fail=$((fail + 1))
  printf 'FAIL  compact exits 0 (got %s)\n%s\n' "$rc" "$out" >&2
fi

assert_contains "compact shows intro" "$out" "Fixture workspace intro paragraph."
assert_contains "compact uses command filename" "$out" "\`/nase:a\` - command a"
assert_not_contains "compact does not trust frontmatter name for command id" "$out" "frontmatter:name-is-not-command"
assert_contains "compact caps command groups" "$out" "(+1 more; run \`/nase:help --verbose\`)"
assert_not_contains "compact omits capped command detail" "$out" "\`/nase:f\` - command f"
assert_contains "compact includes KB layout counts" "$out" "\`workspace/kb/general/\` - general KB, 1 md file(s)"
assert_contains "compact includes workspace skills" "$out" "\`/nase:workspace:alpha\`"
assert_even_backticks "compact keeps code spans balanced" "$out"

out_short=$(python3 "$SCRIPT" --root "$FIXTURE" --purpose-chars 12 2>&1)
assert_contains "compact truncates long purposes" "$out_short" "command b..."
assert_even_backticks "short compact keeps code spans balanced" "$out_short"

out=$(python3 "$SCRIPT" --root "$FIXTURE" --verbose 2>&1)
rc=$?
if [ "$rc" = 0 ]; then
  pass=$((pass + 1))
  printf 'PASS  verbose exits 0\n'
else
  fail=$((fail + 1))
  printf 'FAIL  verbose exits 0 (got %s)\n%s\n' "$rc" "$out" >&2
fi

assert_contains "verbose includes generated command section" "$out" "## Available commands"
assert_contains "verbose includes full command section" "$out" "| \`/nase:f\` | command f |"
assert_contains "verbose includes hooks section" "$out" "Full hook table text."
assert_contains "verbose includes all workspace skills" "$out" "\`/nase:workspace:beta\`"

command_doc=$(sed -n '1,40p' "$HELP_COMMAND")
assert_contains "help command uses root-qualified helper" "$command_doc" 'python3 "$ROOT/.claude/scripts/help-summary.py"'

catalog_json=$(python3 "$CATALOG" --root "$FIXTURE" --format json 2>&1)
assert_contains "catalog emits filename-derived command id" "$catalog_json" '"/nase:a"'
assert_contains "catalog emits category" "$catalog_json" '"category": "Setup & health"'
assert_contains "catalog emits Claude-native argument-hint key" "$catalog_json" '"argument-hint":'
assert_contains "catalog keeps compatible argument_hint key" "$catalog_json" '"argument_hint":'

create_command typo "Git workflows" 9 "invalid category fixture"
bad_catalog=$(python3 "$CATALOG" --root "$FIXTURE" --format json 2>&1)
rc=$?
if [ "$rc" != 0 ]; then
  pass=$((pass + 1))
  printf 'PASS  catalog rejects unknown category\n'
else
  fail=$((fail + 1))
  printf 'FAIL  catalog rejects unknown category (got %s)\n%s\n' "$rc" "$bad_catalog" >&2
fi
assert_contains "catalog reports unknown category" "$bad_catalog" "unknown category: Git workflows"

repo_out=$(python3 "$SCRIPT" --root "$ROOT" 2>&1)
assert_even_backticks "repo compact help keeps code spans balanced" "$repo_out"

catalog_check=$(python3 "$CATALOG" --root "$ROOT" --check-readme 2>&1)
rc=$?
if [ "$rc" = 0 ]; then
  pass=$((pass + 1))
  printf 'PASS  repo README command catalog has no drift\n'
else
  fail=$((fail + 1))
  printf 'FAIL  repo README command catalog has no drift (got %s)\n%s\n' "$rc" "$catalog_check" >&2
fi

total=$((pass + fail))
printf '\n%d/%d assertions passed\n' "$pass" "$total"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
