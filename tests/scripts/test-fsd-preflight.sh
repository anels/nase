#!/usr/bin/env bash
# Regression tests for .claude/scripts/fsd-preflight.py.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/fsd-preflight.py"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

pass=0
fail=0

assert_cmd() {
  local desc="$1"
  shift
  if "$@"; then
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n' "$desc" >&2
  fi
}

repo="$FIXTURE/repo"
mkdir -p "$repo/src" "$FIXTURE/workspace/kb/projects"

(
  cd "$repo" || exit 1
  git init -q
  current_branch=$(git branch --show-current)
  if [ "$current_branch" != "main" ]; then
    git checkout -q -b main
  fi
  git config user.email test@example.com
  git config user.name Test
  cat > README.md <<'EOF'
# Fixture
EOF
  cat > src/Service.cs <<'EOF'
namespace Fixture;
public sealed class Service {}
EOF
  cat > src/Helper.cs <<'EOF'
namespace Fixture;
public static class Helper {}
EOF
  git add .
  git commit -q -m "fixture"
  git remote add origin https://github.com/acme/fixture.git
  git update-ref refs/remotes/origin/main HEAD
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  printf '%s\n' "// dirty" >> src/Service.cs
)

cat > "$FIXTURE/workspace/kb/projects/fixture.md" <<'EOF'
# Fixture KB

- Service retry behavior lives in `src/Service.cs`.
EOF

out="$FIXTURE/preflight.json"
python3 "$SCRIPT" --repo "$repo" --task "change Service retry" --kb-file "$FIXTURE/workspace/kb/projects/fixture.md" --json > "$out"

assert_cmd "preflight emits expected deterministic JSON" python3 - "$out" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["task"] == "change Service retry"
assert data["repo"]["branch"] == "main"
assert data["repo"]["dirty"] is True
assert data["repo"]["defaultBranch"]["branch"] == "main"
assert any(item == "dir:src" for item in data["moduleInventory"])
assert any("Service" in item or "Helper" in item for item in data["moduleInventory"])
assert data["kbMentionCandidates"]
assert isinstance(data["toolAvailability"], list)
PY

total=$((pass + fail))
printf '\n%d/%d assertions passed\n' "$pass" "$total"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
