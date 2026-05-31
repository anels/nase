#!/usr/bin/env bash
# Regression tests for .claude/scripts/kb-hygiene-scan.py.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/kb-hygiene-scan.py"
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

mkdir -p "$FIXTURE/repo/.github/workflows" "$FIXTURE/repo/.pipelines" "$FIXTURE/repo/src/alpha" "$FIXTURE/repo/src/beta" "$FIXTURE/repo/api" "$FIXTURE/repo/db" "$FIXTURE/workspace/kb/projects"

cat > "$FIXTURE/repo/src/Service.cs" <<'EOF'
namespace Fixture;
public sealed class Service {}
EOF
cat > "$FIXTURE/repo/src/Moved.cs" <<'EOF'
namespace Fixture;
public sealed class Moved {}
EOF
cat > "$FIXTURE/repo/src/alpha/Startup.cs" <<'EOF'
namespace Fixture.Alpha;
public sealed class Startup {}
EOF
cat > "$FIXTURE/repo/src/beta/Startup.cs" <<'EOF'
namespace Fixture.Beta;
public sealed class Startup {}
EOF
cat > "$FIXTURE/repo/api/AuthController.cs" <<'EOF'
namespace Fixture;
public sealed class AuthController {}
EOF
cat > "$FIXTURE/repo/db/schema.sql" <<'EOF'
create table example(id int);
EOF
cat > "$FIXTURE/repo/.github/workflows/validate.yml" <<'EOF'
name: validate
EOF
cat > "$FIXTURE/repo/.pipelines/build.yml" <<'EOF'
trigger: none
EOF

(
  cd "$FIXTURE/repo" || exit 1
  git init -q
  git config user.email test@example.com
  git config user.name Test
  git add .
  git commit -q -m "fixture"
)

cat > "$FIXTURE/workspace/kb/projects/fixture.md" <<'EOF'
# Knowledge Base - Fixture

## Overview
<!-- Last updated: 2026-04-01 -->
- Valid source ref: `src/Service.cs:1`
- Valid dotdir refs: `.github/workflows/validate.yml`, `.pipelines/build.yml`, and `./src/Service.cs:1`.
- Out-of-range source ref: `src/Service.cs:99`
- Moved source ref: `src/old/Moved.cs:1`
- Missing source ref: `src/Missing.cs:10`
- Ambiguous source ref: `Startup.cs`
- Workspace note: `workspace/tasks/lessons.md`
- Placeholder: `FILL_IN`

## API Surface
- Auth claim is stale and may be outdated. Check `api/AuthController.cs:1`.

## Data Layer
- Schema semantics are stale after the migration. Check `db/schema.sql:1`.

## Ownership Map
- Owner claim is stale after team move.

## Change History
### 2026-04-01
- Old local claim was stale but kept for learning.
- Correction 2026-04-02: first correction.
- Superseded by: second correction.
- Correction 2026-04-03: third correction.
EOF

out=$(python3 "$SCRIPT" \
  --repo-root "$FIXTURE/repo" \
  --kb-file "$FIXTURE/workspace/kb/projects/fixture.md" \
  --today 2026-05-29 \
  --max-corrections 2 2>&1)
rc=$?

if [ "$rc" = 0 ]; then
  pass=$((pass + 1))
  printf 'PASS  scanner exits 0\n'
else
  fail=$((fail + 1))
  printf 'FAIL  scanner exits 0 (got %s)\n%s\n' "$rc" "$out" >&2
fi

assert_contains "unambiguous broken refs are auto-fix candidates" "$out" "[AUTO-FIX]"
assert_contains "unambiguous replacement is suggested" "$out" "suggestions: src/Moved.cs"
assert_contains "missing broken ref path is reported" "$out" "src/Missing.cs"
assert_contains "missing broken refs need humans" "$out" "no replacement path was found"
assert_contains "ambiguous broken refs need humans" "$out" "multiple possible replacements"
assert_not_contains "workspace-local refs are ignored" "$out" "workspace/tasks/lessons.md"
assert_contains "unresolved placeholders are reported" "$out" "unresolved_placeholder"
assert_contains "stale timestamps are reported" "$out" "stale_timestamp"
assert_contains "risky API/schema/ownership claims need humans" "$out" "stale_risky_claim"
assert_contains "historical stale notes are marked, not deleted" "$out" "mark-not-delete"
assert_contains "sections with many corrections are compact candidates" "$out" "compact_section"
assert_contains "line ranges beyond file length are reported" "$out" "line_out_of_range"
assert_contains "line ranges beyond file length need humans" "$out" "[NEEDS_HUMAN]"
assert_not_contains "valid source ref is not flagged" "$out" "src/Service.cs:1"
assert_not_contains "leading-dot refs are not stripped" "$out" "github/workflows/validate.yml"
assert_not_contains "dot pipeline refs are not stripped" "$out" "pipelines/build.yml"

json_out=$(python3 "$SCRIPT" \
  --repo-root "$FIXTURE/repo" \
  --kb-file "$FIXTURE/workspace/kb/projects/fixture.md" \
  --today 2026-05-29 \
  --max-corrections 2 \
  --json 2>&1)
json_rc=$?

if [ "$json_rc" = 0 ] && printf '%s' "$json_out" | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["summary"]["total"] >= 6; assert any(i["action"] == "auto-fix" for i in data["issues"]); assert any(i["action"] == "needs_human" for i in data["issues"]); assert any(i["category"] == "line_out_of_range" and i["action"] == "needs_human" for i in data["issues"])'; then
  pass=$((pass + 1))
  printf 'PASS  json output is parseable and classified\n'
else
  fail=$((fail + 1))
  printf 'FAIL  json output is parseable and classified\n%s\n' "$json_out" >&2
fi

total=$((pass + fail))
printf '\n%d/%d assertions passed\n' "$pass" "$total"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
