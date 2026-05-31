#!/usr/bin/env bash
# Regression tests for .claude/scripts/help-summary.py.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/help-summary.py"
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

mkdir -p "$FIXTURE/workspace/kb/general" "$FIXTURE/workspace/kb/projects" "$FIXTURE/workspace/tasks" "$FIXTURE/workspace/logs" "$FIXTURE/workspace/skills"
touch "$FIXTURE/workspace/kb/general/workflow.md"
touch "$FIXTURE/workspace/kb/projects/repo.md"
touch "$FIXTURE/workspace/tasks/lessons.md"
touch "$FIXTURE/workspace/skills/alpha.md" "$FIXTURE/workspace/skills/beta.md"

cat > "$FIXTURE/README.md" <<'EOF'
# fixture

Fixture workspace intro paragraph.

## Available commands

### Setup
| Command | Purpose |
|---------|---------|
| `/nase:a [x|y]` | command a |
| `/nase:b` | command b has a deliberately long purpose |
| `/nase:c` | command c |
| `/nase:d` | command d |
| `/nase:e` | command e |
| `/nase:f` | command f |

### Work
| Command | Purpose |
|---------|---------|
| `/nase:g` | command g |

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
assert_contains "compact preserves code-span pipe" "$out" "\`/nase:a [x|y]\` - command a"
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

assert_contains "verbose includes full command section" "$out" "\`/nase:f\` | command f"
assert_contains "verbose includes hooks section" "$out" "Full hook table text."
assert_contains "verbose includes all workspace skills" "$out" "\`/nase:workspace:beta\`"

command_doc=$(sed -n '1,40p' "$HELP_COMMAND")
assert_contains "help command uses root-qualified helper" "$command_doc" 'python3 "$ROOT/.claude/scripts/help-summary.py"'

repo_out=$(python3 "$SCRIPT" --root "$ROOT" 2>&1)
assert_even_backticks "repo compact help keeps code spans balanced" "$repo_out"

total=$((pass + fail))
printf '\n%d/%d assertions passed\n' "$pass" "$total"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
