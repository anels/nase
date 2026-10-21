#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

PYTHON_BIN=$(command -v python3)
ROLES=".claude/roles.yaml"
ARCH="docs/architecture.md"

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; failures=$((failures + 1)); }
assert_cmd() {
  local name="$1"; shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

# Each role must carry model + effort + tools; effort in {low,medium,high};
# lookup=low and architect=high anchor the ladder. Line-based parse — no yaml dep.
assert_cmd "roles.yaml schema: model+effort per role, valid tiers" "$PYTHON_BIN" - "$ROLES" <<'PY'
import re, sys

text = open(sys.argv[1], encoding="utf-8").read()
# Drop comment lines so '#'-prefixed examples don't pollute the parse.
body = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))

# Roles are 2-space-indented keys under `roles:`; fields are 4-space-indented.
blocks = dict(re.findall(r"\n  (\w+):\n((?:    .*\n?)+)", body))
expected = {"lookup", "worker", "verifier", "checker", "architect"}
assert set(blocks) == expected, f"role set drift: {set(blocks)} != {expected}"

valid = {"low", "medium", "high"}
efforts = {}
models = {}
for role, block in blocks.items():
    mm = re.search(r"^    model:\s*(\S+)", block, re.M)
    assert mm, f"{role} missing model"
    models[role] = mm.group(1)
    assert re.search(r"^    tools:\s*\[", block, re.M), f"{role} missing tools"
    m = re.search(r"^    effort:\s*(\w+)", block, re.M)
    assert m, f"{role} missing effort"
    assert m.group(1) in valid, f"{role} effort '{m.group(1)}' not in {valid}"
    efforts[role] = m.group(1)

assert efforts["lookup"] == "low", efforts
assert efforts["architect"] == "high", efforts

# Gates that must not be skipped stay on sonnet. Moving verifier or worker to haiku
# needs its own eval, so a silent change here fails the test.
assert models["verifier"] == "sonnet", models
assert models["worker"] == "sonnet", models
assert models["checker"] == "haiku", models
PY

assert_cmd "roles.yaml documents Effort scaling rule" grep -q "Effort scaling" "$ROLES"
assert_cmd "roles.yaml gates automated downgrade on eval" grep -qi "eval gate" "$ROLES"
assert_cmd "architecture.md role table has Effort column" grep -q "| Role | Model | Effort |" "$ARCH"
assert_cmd "architecture.md documents verifier role" grep -q '| `verifier` | `sonnet` | `medium` |' "$ARCH"
assert_cmd "architecture.md documents checker role" grep -q '| `checker` | `haiku` | `medium` |' "$ARCH"
assert_cmd "bot-comment batch-verify routes to checker" grep -q 'role `checker` per `.claude/roles.yaml`' .claude/docs/pr-review-verification.md

if [[ "$failures" -eq 0 ]]; then
  printf '\nroles-schema tests passed.\n'
  exit 0
fi
printf '\n%d roles-schema assertion(s) failed.\n' "$failures" >&2
exit 1
