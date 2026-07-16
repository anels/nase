#!/usr/bin/env bash
# Regression tests for the payload-bound external write action helper.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/external-write-action.py"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

mkdir -p "$TMPDIR_TEST/bin" "$TMPDIR_TEST/workspace/tmp"
cat > "$TMPDIR_TEST/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$NASE_FAKE_OUTPUT"
if [[ -n "${NASE_FAKE_WAIT:-}" ]]; then
  sleep "$NASE_FAKE_WAIT"
fi
exit "${NASE_FAKE_EXIT:-0}"
SH
chmod +x "$TMPDIR_TEST/bin/gh"

pass=0
fail=0

report() {
  local ok="$1" name="$2" detail="${3:-}"
  if [[ "$ok" -eq 0 ]]; then
    printf 'PASS  %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s%s\n' "$name" "${detail:+: $detail}" >&2
    fail=$((fail + 1))
  fi
}

expect_rc() {
  local name="$1" expected="$2"
  shift 2
  set +e
  "$@" > "$TMPDIR_TEST/out" 2> "$TMPDIR_TEST/err"
  local rc=$?
  set -e
  if [[ "$rc" -eq "$expected" ]]; then
    report 0 "$name"
  else
    report 1 "$name" "expected $expected, got $rc: $(cat "$TMPDIR_TEST/err")"
  fi
}

prepare_action() {
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --summary "create draft PR" -- \
    gh pr create --draft --title "Example" --body "payload" -R owner/example > "$TMPDIR_TEST/prepared.json"
  jq -r '.manifest' "$TMPDIR_TEST/prepared.json"
}

manifest=$(prepare_action)
if [[ -f "$manifest" ]] && jq -e '.action.argv[0] == "gh" and .action.payload_sha256' "$manifest" >/dev/null; then
  report 0 "prepare writes a payload-bound manifest"
else
  report 1 "prepare writes a payload-bound manifest"
fi

expect_rc "authorization rejects an invalid TTL" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" --ttl-seconds 301

expect_rc "execute without token is blocked" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"

python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
NASE_FAKE_OUTPUT="$TMPDIR_TEST/gh-args" PATH="$TMPDIR_TEST/bin:$PATH" \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"
if grep -q -- 'pr create --draft' "$TMPDIR_TEST/gh-args" && [[ ! -e "$TMPDIR_TEST/workspace/.external-write-token" ]]; then
  report 0 "authorized action runs once and consumes token"
else
  report 1 "authorized action runs once and consumes token"
fi

manifest=$(prepare_action)
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
python3 - "$manifest" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["action"]["summary"] = "tampered"
path.write_text(json.dumps(data))
PY
expect_rc "tampered manifest is blocked" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"
if [[ ! -e "$TMPDIR_TEST/workspace/.external-write-token" ]]; then
  report 0 "tamper failure consumes token"
else
  report 1 "tamper failure consumes token"
fi

expect_rc "read-only command cannot become an external write action" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system github --summary "read" -- gh pr view 7

manifest=$(prepare_action)
printf '{not valid json\n' > "$TMPDIR_TEST/workspace/.external-write-token"
expect_rc "malformed token is blocked" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"
if [[ ! -e "$TMPDIR_TEST/workspace/.external-write-token" ]]; then
  report 0 "malformed-token failure consumes token"
else
  report 1 "malformed-token failure consumes token"
fi

manifest=$(prepare_action)
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" --ttl 1 >/dev/null
python3 - "$TMPDIR_TEST/workspace/.external-write-token" <<'PY'
import json
import pathlib

path = pathlib.Path(__import__('sys').argv[1])
token = json.loads(path.read_text())
token['created_at'] = '2000-01-01T00:00:00Z'
path.write_text(json.dumps(token))
PY
expect_rc "expired token is blocked" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"
if [[ ! -e "$TMPDIR_TEST/workspace/.external-write-token" ]]; then
  report 0 "expired-token failure consumes token"
else
  report 1 "expired-token failure consumes token"
fi

PAYLOAD_FILE="$TMPDIR_TEST/pr-body.md"
printf 'approved body\n' > "$PAYLOAD_FILE"
python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
  --system github --summary "edit PR body" -- \
  gh pr edit 7 --body-file "$PAYLOAD_FILE" > "$TMPDIR_TEST/payload-prepared.json"
manifest=$(jq -r '.manifest' "$TMPDIR_TEST/payload-prepared.json")
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
printf 'changed after approval\n' > "$PAYLOAD_FILE"
expect_rc "payload drift is blocked" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"
if [[ ! -e "$TMPDIR_TEST/workspace/.external-write-token" ]]; then
  report 0 "payload-drift failure consumes token"
else
  report 1 "payload-drift failure consumes token"
fi

EQUALS_PAYLOAD="$TMPDIR_TEST/equals-body.json"
printf '{"approved":true}\n' > "$EQUALS_PAYLOAD"
python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
  --system azure --summary "patch pipeline payload" -- \
  az rest --method patch --uri https://example.invalid --body="@$EQUALS_PAYLOAD" > "$TMPDIR_TEST/equals-prepared.json"
manifest=$(jq -r '.manifest' "$TMPDIR_TEST/equals-prepared.json")
if jq -e '.action.payload_files | any(.arg_index == 6 and (.sha256 | type == "string"))' "$manifest" >/dev/null; then
  report 0 "equals-form payload is hash-bound"
else
  report 1 "equals-form payload is hash-bound"
fi
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
printf '{"changed":true}\n' > "$EQUALS_PAYLOAD"
expect_rc "equals-form payload drift is blocked" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"

# `az acr build` builds + pushes an image — a mutation that must route through the gate.
python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
  --system azure --summary "acr build" -- \
  az acr build --registry example --image app:tag . > "$TMPDIR_TEST/acr-build-prepared.json"
if jq -e '.action.system == "azure"' "$(jq -r '.manifest' "$TMPDIR_TEST/acr-build-prepared.json")" >/dev/null; then
  report 0 "az acr build is gated as an azure mutation"
else
  report 1 "az acr build is gated as an azure mutation"
fi

expect_rc "az acr show stays read-only (not a mutation)" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system azure --summary "read" -- az acr show --name example

manifest=$(prepare_action)
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
python3 - "$manifest" <<'PY'
import hashlib
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data['action']['argv'][data['action']['argv'].index('owner/example')] = 'owner/other-target'
data['action']['payload_sha256'] = hashlib.sha256(json.dumps(
    {'argv': data['action']['argv'], 'payload_files': data['action']['payload_files']},
    sort_keys=True, separators=(',', ':')).encode()).hexdigest()
data['action_sha256'] = hashlib.sha256(json.dumps(
    data['action'], sort_keys=True, separators=(',', ':')).encode()).hexdigest()
path.write_text(json.dumps(data))
PY
expect_rc "changed action target is blocked by token binding" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"

manifest=$(prepare_action)
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
NASE_FAKE_OUTPUT="$TMPDIR_TEST/gh-failure-args" NASE_FAKE_EXIT=7 PATH="$TMPDIR_TEST/bin:$PATH" \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest" || failure_rc=$?
if [[ "${failure_rc:-0}" -eq 7 ]] && [[ ! -e "$TMPDIR_TEST/workspace/.external-write-token" ]]; then
  report 0 "command failure consumes token"
else
  report 1 "command failure consumes token"
fi

expect_rc "successful action cannot be repeated" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"

manifest=$(prepare_action)
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
NASE_FAKE_OUTPUT="$TMPDIR_TEST/gh-concurrent-args" NASE_FAKE_WAIT=2 PATH="$TMPDIR_TEST/bin:$PATH" \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest" > "$TMPDIR_TEST/concurrent.out" 2> "$TMPDIR_TEST/concurrent.err" &
execute_pid=$!
for _ in $(seq 1 20); do
  compgen -G "$TMPDIR_TEST/workspace/.external-write-token.executing-*" >/dev/null && break
  sleep 0.1
done
expect_rc "claimed token blocks concurrent execute" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"
expect_rc "claimed token blocks new authorization" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest"
wait "$execute_pid"
if [[ ! -e "$TMPDIR_TEST/workspace/.external-write-token" ]] \
  && ! compgen -G "$TMPDIR_TEST/workspace/.external-write-token.executing-*" >/dev/null; then
  report 0 "claimed token is consumed after execution"
else
  report 1 "claimed token is consumed after execution"
fi

printf '\n--- %d pass, %d fail ---\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
