#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

PYTHON_BIN=$(command -v python3)
SCRIPT=".claude/scripts/skill-eval-run.py"
CORE_EVAL="evals/core-workflows/evals.json"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT
mkdir -p "$TMPDIR_TEST/bin" "$TMPDIR_TEST/runs" "$TMPDIR_TEST/outputs"

cat > "$TMPDIR_TEST/bin/claude" <<'PY'
#!/usr/bin/env python3
import json
import os
import re
import sys
import time
from pathlib import Path


def emit(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)


args = sys.argv[1:]
credential = os.environ.get("ANTHROPIC_API_KEY", "")
if args == ["auth", "status"]:
    child = bool(os.environ.get("CLAUDE_CONFIG_DIR"))
    source = "FILE" if credential == "unsupported" or (child and credential == "child-mismatch") else "ANTHROPIC_API_KEY"
    emit({"loggedIn": True, "apiProvider": "firstParty", "apiKeySource": source})
    raise SystemExit(0)
if args == ["--version"]:
    print("fake-claude 1.0")
    raise SystemExit(0)
if any(os.environ.get(name) for name in ("TEST_SECRET_SHOULD_NOT_PASS", "AWS_SECRET_ACCESS_KEY", "HTTPS_PROXY")):
    raise SystemExit(11)

model = args[args.index("--model") + 1]
prompt = args[-1]
if model == "fake-timeout":
    time.sleep(3)
if model == "fake-error":
    raise SystemExit(7)

skills = []
for path in Path(".claude/commands/nase").rglob("*.md"):
    match = re.search(r"(?m)^name:\s*(nase:[^\s]+)", path.read_text())
    if match:
        skills.append(match.group(1))
emit({"type": "system", "subtype": "init", "model": model, "skills": sorted(skills)})

if "fixture/" not in prompt:
    target = None
    if model == "fake-auto":
        if "decision-complete" in prompt:
            target = "nase:design"
        elif "Estimate how long" in prompt:
            target = "nase:estimate-eta"
    elif model == "fake-hit":
        target = "nase:design"
    elif model == "fake-adjacent":
        target = "nase:estimate-eta"
    elif model == "fake-over-budget":
        target = "nase:design"
    elif model == "fake-flip":
        counter = Path(os.environ["TMPDIR"]) / "skill-eval-flip-counter"
        value = int(counter.read_text()) + 1 if counter.exists() else 1
        counter.write_text(str(value))
        target = "nase:design" if value % 2 else None
    if target:
        emit({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "skill-1", "name": "Skill", "input": {"skill": target}}]}})
    emit({"type": "result", "model": model, "result": "routing complete", "duration_ms": 3, "total_cost_usd": 0.02 if model == "fake-over-budget" else 0})
    raise SystemExit(0)

emit({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "skill-1", "name": "Skill", "input": {"skill": skills[0]}}]}})
emit({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "forbidden", "name": "Read", "input": {"file_path": "../forbidden-read/sentinel.txt"}}]}})
emit({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "forbidden", "is_error": True, "content": "permission denied"}]}})

canaries = []
fixture_files = sorted(path for path in Path("fixture").rglob("*") if path.is_file())
for index, path in enumerate(fixture_files):
    emit({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": f"read-{index}", "name": "Read", "input": {"file_path": str(path)}}]}})
    content = path.read_text()
    denied = model == "fake-denied-read"
    emit({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": f"read-{index}", "is_error": denied, "content": "permission denied" if denied else content}]}})
    canaries.extend(re.findall(r"[A-Z][A-Z0-9_]+_CANARY_[0-9]+", content))

joined = " ".join(sorted(set(canaries)))
if any(path.name == "request.md" for path in fixture_files):
    result = f"Target PR count: 1\nValidation command: pytest tests/test_invoice_retry.py\n{joined}"
elif any(path.name == "pr.diff" for path in fixture_files):
    result = f"Problem: tenant cache isolation regressed.\nConfirmed findings\nissue: `src/cache.ts:42` uses a global key.\n{joined}"
else:
    result = f"test_quality: FAIL\nRequire an observable behavioral contract and plausible mutation failure power.\n{joined}"
if model == "fake-secret":
    result += "\n" + "ghp_" + ("A" * 24)
if model == "fake-bad-output":
    result = joined
emit({"type": "result", "model": model, "result": result, "duration_ms": 4, "total_cost_usd": 0})
PY
chmod +x "$TMPDIR_TEST/bin/claude"

export PATH="$TMPDIR_TEST/bin:$PATH"
export TMPDIR="$TMPDIR_TEST"
export ANTHROPIC_API_KEY="test-only"
export TEST_SECRET_SHOULD_NOT_PASS="must-be-stripped"
export AWS_SECRET_ACCESS_KEY="must-be-stripped"
export HTTPS_PROXY="must-be-stripped"

failures=0
source "$ROOT/tests/lib/assert.sh"

run_routing() {
  "$PYTHON_BIN" "$SCRIPT" run-routing \
    --eval-set "$CORE_EVAL" \
    --routing-case "$1" \
    --model "$2" \
    --repetitions "${3:-1}" \
    --max-budget-usd 0.01 \
    --timeout-seconds "${4:-2}" \
    --manifest-dir "${5:-$TMPDIR_TEST/runs}"
}

expect_fail() {
  if "$@"; then
    return 1
  fi
  return 0
}

assert_cmd "exact positive Skill tool use passes" run_routing routing-design-positive fake-hit
assert_cmd "target absence fails positive routing" expect_fail run_routing routing-design-positive fake-adjacent
assert_cmd "adjacent invocation passes target near miss" run_routing routing-design-near-miss fake-adjacent 3
assert_cmd "three agreeing repetitions pass" run_routing routing-design-positive fake-auto 3
assert_cmd "timeout is an error" expect_fail run_routing routing-design-positive fake-timeout 1 1
assert_cmd "nonzero exit is an error" expect_fail run_routing routing-design-positive fake-error
assert_cmd "reported cost above the per-call budget is an error" expect_fail run_routing routing-design-positive fake-over-budget
assert_cmd "non-finite budget is rejected" expect_fail \
  "$PYTHON_BIN" "$SCRIPT" run-routing \
  --eval-set "$CORE_EVAL" --routing-case routing-design-positive --model fake-hit \
  --repetitions 1 --max-budget-usd NaN --timeout-seconds 2 --manifest-dir "$TMPDIR_TEST/runs"

assert_cmd "output fixture run passes" "$PYTHON_BIN" "$SCRIPT" run-output \
  --eval-set "$CORE_EVAL" \
  --runtime-case runtime-design-grounding \
  --model fake-output \
  --max-budget-usd 0.01 \
  --timeout-seconds 2 \
  --manifest-dir "$TMPDIR_TEST/runs" \
  --output-dir "$TMPDIR_TEST/outputs"

assert_cmd "denied required reads fail output controls" expect_fail \
  "$PYTHON_BIN" "$SCRIPT" run-output \
  --eval-set "$CORE_EVAL" --runtime-case runtime-design-grounding --model fake-denied-read \
  --max-budget-usd 0.01 --timeout-seconds 2 \
  --manifest-dir "$TMPDIR_TEST/runs" --output-dir "$TMPDIR_TEST/outputs"

assert_cmd "one failing assertion prevents outcome pass" expect_fail \
  "$PYTHON_BIN" "$SCRIPT" run-output \
  --eval-set "$CORE_EVAL" --runtime-case runtime-design-grounding --model fake-bad-output \
  --max-budget-usd 0.01 --timeout-seconds 2 \
  --manifest-dir "$TMPDIR_TEST/runs" --output-dir "$TMPDIR_TEST/outputs"

output_receipt=$("$PYTHON_BIN" - "$TMPDIR_TEST/runs" <<'PY'
import json
import pathlib
import sys
for path in pathlib.Path(sys.argv[1]).glob("*.json"):
    data = json.loads(path.read_text())
    if data.get("lane") == "output" and data.get("result", {}).get("status") == "pass":
        print(path)
        break
PY
)
assert_cmd "human review updates current passing receipt" "$PYTHON_BIN" "$SCRIPT" review \
  --receipt "$output_receipt" --status accepted --note "Fixture evidence checked"
assert_cmd "review status is accepted" "$PYTHON_BIN" - "$output_receipt" <<'PY'
import json
import sys
assert json.load(open(sys.argv[1], encoding="utf-8"))["human_review"]["status"] == "accepted"
PY

output_artifact=$("$PYTHON_BIN" - "$output_receipt" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["output"]["path"])
PY
)
cp "$output_artifact" "$TMPDIR_TEST/output.original"
printf 'drift\n' >> "$output_artifact"
assert_cmd "review rejects output artifact hash drift" expect_fail \
  "$PYTHON_BIN" "$SCRIPT" review --receipt "$output_receipt" \
  --status accepted --note "drifted output must not pass"
cp "$TMPDIR_TEST/output.original" "$output_artifact"

cp "$output_receipt" "$TMPDIR_TEST/tampered-receipt.json"
"$PYTHON_BIN" - "$TMPDIR_TEST/tampered-receipt.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["output"]["score"]["ok"] = False
json.dump(data, open(path, "w", encoding="utf-8"))
PY
assert_cmd "review rejects a receipt with failed controls" expect_fail \
  "$PYTHON_BIN" "$SCRIPT" review --receipt "$TMPDIR_TEST/tampered-receipt.json" \
  --status accepted --note "must not be accepted"

assert_cmd "manual-only output case is rejected" expect_fail \
  "$PYTHON_BIN" "$SCRIPT" run-output \
  --eval-set "$CORE_EVAL" --runtime-case today-live-evidence --model fake-output \
  --max-budget-usd 0.01 --timeout-seconds 2 \
  --manifest-dir "$TMPDIR_TEST/runs" --output-dir "$TMPDIR_TEST/outputs"

secret_outputs="$TMPDIR_TEST/secret-outputs"
mkdir "$secret_outputs"
assert_cmd "sensitive output is rejected" expect_fail \
  "$PYTHON_BIN" "$SCRIPT" run-output \
  --eval-set "$CORE_EVAL" --runtime-case runtime-design-grounding --model fake-secret \
  --max-budget-usd 0.01 --timeout-seconds 2 \
  --manifest-dir "$TMPDIR_TEST/runs" --output-dir "$secret_outputs"
assert_cmd "sensitive raw output is discarded" bash -c '[[ -z "$(find "$1" -type f -print -quit)" ]]' _ "$secret_outputs"

assert_cmd "coverage keeps evidence dimensions separate" bash -c '
  "$1" "$2" coverage --eval-set "$3" --manifest-dir "$4" > "$5"
  "$1" - "$5" <<"PY"
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
row = next(item for item in data["rows"] if item["skill"] == "nase:design")
assert row == {"skill": "nase:design", "structural": "complete", "invocation": "stable-pass", "outcome": "fixture-backed-pass", "human": "accepted"}
assert all(not item["skill"].startswith("nase:workspace:") for item in data["rows"])
assert "percentage" not in data
PY
' _ "$PYTHON_BIN" "$SCRIPT" "$CORE_EVAL" "$TMPDIR_TEST/runs" "$TMPDIR_TEST/coverage.json"

FLIP_RUNS="$TMPDIR_TEST/flip-runs"
mkdir "$FLIP_RUNS"
assert_cmd "one routing flip fails the run" expect_fail run_routing routing-design-positive fake-flip 3 2 "$FLIP_RUNS"
assert_cmd "one routing flip reports unstable" bash -c '
  "$1" "$2" coverage --eval-set "$3" --manifest-dir "$4" > "$5"
  "$1" - "$5" <<"PY"
import json
import sys
row = next(item for item in json.load(open(sys.argv[1], encoding="utf-8"))["rows"] if item["skill"] == "nase:design")
assert row["invocation"] == "unstable"
PY
' _ "$PYTHON_BIN" "$SCRIPT" "$CORE_EVAL" "$FLIP_RUNS" "$TMPDIR_TEST/flip-coverage.json"

STALE_RUNS="$TMPDIR_TEST/stale-runs"
mkdir "$STALE_RUNS"
assert_cmd "stale fixture starts from a passing routing batch" run_routing routing-design-positive fake-hit 3 2 "$STALE_RUNS"
"$PYTHON_BIN" - "$STALE_RUNS" <<'PY'
import json
import pathlib
import sys
for path in pathlib.Path(sys.argv[1]).glob("*.json"):
    data = json.loads(path.read_text())
    data["eval_set"]["sha256"] = "0" * 64
    path.write_text(json.dumps(data))
PY
assert_cmd "stale routing receipts report stale" bash -c '
  "$1" "$2" coverage --eval-set "$3" --manifest-dir "$4" > "$5"
  "$1" - "$5" <<"PY"
import json
import sys
row = next(item for item in json.load(open(sys.argv[1], encoding="utf-8"))["rows"] if item["skill"] == "nase:design")
assert row["invocation"] == "stale"
PY
' _ "$PYTHON_BIN" "$SCRIPT" "$CORE_EVAL" "$STALE_RUNS" "$TMPDIR_TEST/stale-coverage.json"

assert_cmd "manifest traversal is rejected" expect_fail \
  "$PYTHON_BIN" "$SCRIPT" run-routing \
  --eval-set "$CORE_EVAL" --routing-case routing-design-positive --model fake-hit \
  --repetitions 1 --max-budget-usd 0.01 --timeout-seconds 2 --manifest-dir "$TMPDIR_TEST/../escape"

ANTHROPIC_API_KEY="unsupported" assert_cmd "unsupported auth source fails before invocation" expect_fail \
  "$PYTHON_BIN" "$SCRIPT" run-routing \
  --eval-set "$CORE_EVAL" --routing-case routing-design-positive --model fake-hit \
  --repetitions 1 --max-budget-usd 0.01 --timeout-seconds 2 --manifest-dir "$TMPDIR_TEST/runs"

ANTHROPIC_API_KEY="child-mismatch" assert_cmd "child auth mismatch fails before invocation" expect_fail \
  "$PYTHON_BIN" "$SCRIPT" run-routing \
  --eval-set "$CORE_EVAL" --routing-case routing-design-positive --model fake-hit \
  --repetitions 1 --max-budget-usd 0.01 --timeout-seconds 2 --manifest-dir "$TMPDIR_TEST/runs"

if [[ "$failures" -eq 0 ]]; then
  printf '\nskill-eval-run tests passed.\n'
  exit 0
fi

printf '\n%d skill-eval-run assertion(s) failed.\n' "$failures" >&2
exit 1
