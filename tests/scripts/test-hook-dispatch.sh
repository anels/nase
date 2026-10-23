#!/usr/bin/env bash
# Regression tests for .claude/scripts/hook-dispatch.sh.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/hook-dispatch.sh"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

pass=0
fail=0

pass_msg() {
  pass=$((pass + 1))
  printf 'PASS  %s\n' "$1"
}

fail_msg() {
  fail=$((fail + 1))
  printf 'FAIL  %s\n' "$1" >&2
}

mkdir -p "$FIXTURE/.claude/hooks"
cat > "$FIXTURE/.claude/hooks/echo-args.sh" <<'EOF'
#!/usr/bin/env bash
printf 'root=%s args=%s\n' "${NASE_ROOT:-unset}" "$*"
EOF

out=$(NASE_ROOT="$FIXTURE" bash "$SCRIPT" echo-args.sh one two 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "root=$FIXTURE args=one two" ]; then
  pass_msg "dispatch resolves the hook and exports NASE_ROOT"
else
  fail_msg "dispatch resolves the hook and exports NASE_ROOT (rc=$rc out=$out)"
fi

bash "$SCRIPT" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
  pass_msg "missing hook name exits 2"
else
  fail_msg "missing hook name exits 2 (got $rc)"
fi

bash "$SCRIPT" not-a-hook >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
  pass_msg "non-.sh hook name exits 2"
else
  fail_msg "non-.sh hook name exits 2 (got $rc)"
fi

bash "$SCRIPT" ../echo-args.sh >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
  pass_msg "path traversal in hook name exits 2"
else
  fail_msg "path traversal in hook name exits 2 (got $rc)"
fi

printf '{}' | NASE_ROOT="$FIXTURE" bash "$SCRIPT" does-not-exist.sh >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  pass_msg "a missing hook file fails instead of silently succeeding"
else
  fail_msg "a missing hook file fails instead of silently succeeding"
fi

# Claude Code exports CLAUDE_PROJECT_DIR; it is the root when NASE_ROOT is unset.
out=$(env -u NASE_ROOT CLAUDE_PROJECT_DIR="$FIXTURE" bash "$SCRIPT" echo-args.sh 2>&1)
if [[ "$out" == root="$FIXTURE"* ]]; then
  pass_msg "dispatch falls back to CLAUDE_PROJECT_DIR"
else
  fail_msg "dispatch falls back to CLAUDE_PROJECT_DIR (out=$out)"
fi

# Outside a repo with neither variable set there is no safe tree, so the hook is
# skipped rather than run against the wrong one.
no_root_out=$(cd "$FIXTURE" && env -u NASE_ROOT -u CLAUDE_PROJECT_DIR bash "$SCRIPT" echo-args.sh 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [[ "$no_root_out" == *"cannot resolve the project root"* ]]; then
  pass_msg "dispatch skips the hook when no root resolves"
else
  fail_msg "dispatch skips the hook when no root resolves (rc=$rc out=$no_root_out)"
fi

printf '\n%d/%d assertions passed\n' "$pass" "$((pass + fail))"
[ "$fail" -eq 0 ]
