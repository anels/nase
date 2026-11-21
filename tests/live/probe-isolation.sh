#!/usr/bin/env bash
# Live isolation probe for persisted review agents. Opt-in and paid.
#
# check-subagent-dispatch.sh only proves the word "fresh" sits near a dispatch
# site. It cannot show that a spawned reviewer lacks the parent's context. This
# probe does. It plants a random marker that only the parent session holds, asks
# the parent to spawn a persisted agent, and checks from the stream-json
# transcript that the agent answers UNKNOWN for the marker.
#
# It proves the reviewer cannot see the parent's context. It does not prove the
# reader stays on its one document, because a tools list cannot limit which file
# Read opens.
#
# Needs an authenticated `claude` CLI and spends tokens (about 0.2 USD for one
# probed agent, capped at 1 USD per agent). Not part of check-all.sh or CI. If the
# shell exports an invalid ANTHROPIC_API_KEY, `claude -p` fails with a 401. Run it
# as `env -u ANTHROPIC_API_KEY NASE_LIVE=1 bash tests/live/probe-isolation.sh`.
# NASE_PROBE_KEEP=1 keeps the stream-json transcripts for debugging.
#
# Run from repo root:
#   NASE_LIVE=1 bash tests/live/probe-isolation.sh [agent ...]
# Default agents: nase-verifier nase-comprehension-reader
# Exit 0 = every probed agent answered UNKNOWN, 1 = a leak or a malformed run,
# 0 with a SKIP line = NASE_LIVE is not 1.

set -euo pipefail

if [ "${NASE_LIVE:-}" != "1" ]; then
  echo "SKIP  set NASE_LIVE=1 to run the live isolation probe (needs claude CLI, spends tokens)"
  exit 0
fi

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

for tool in claude python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL  $tool is not on PATH" >&2
    exit 1
  fi
done

if [ "$#" -gt 0 ]; then
  agents=("$@")
else
  agents=(nase-verifier nase-comprehension-reader)
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/nase-probe.XXXXXX")
if [ "${NASE_PROBE_KEEP:-}" = "1" ]; then
  echo "NOTE  keeping transcripts in $work"
else
  trap 'rm -rf "$work"' EXIT
fi

doc="$work/probe-doc.md"
cat >"$doc" <<'EOF'
# Probe design

## Goal

Rename the `--fast` flag of the sample tool to `--quick`.

## Plan

Edit the flag table in the sample tool's README, then update its one test.
EOF

failures=0

for agent in "${agents[@]}"; do
  if [ ! -f ".claude/agents/${agent}.md" ]; then
    echo "FAIL  ${agent}: .claude/agents/${agent}.md is missing" >&2
    failures=$((failures + 1))
    continue
  fi

  marker="MARKER_$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
  out="$work/${agent}.stream.jsonl"

  prompt="Parent-only context marker: ${marker}. Do not repeat it, write it, or pass it on to anyone.

Make exactly one Agent call with subagent_type \"${agent}\". Use this as that call's prompt, word for word, and add nothing else:

The artifact is the file ${doc}. Do your normal job on it. Start your reply with one line of the form \`MARKER: <value>\`. If a string that starts with MARKER_ and then has exactly 32 lowercase hexadecimal digits is visible anywhere in your own context, give it exactly. Otherwise write \`MARKER: UNKNOWN\`. Do not guess.

After the Agent call returns, reply with the single word DONE."

  if ! printf '%s' "$prompt" | claude -p \
      --output-format stream-json --verbose \
      --allowedTools "Agent,Read" \
      --max-turns 8 --max-budget-usd 1 \
      --no-session-persistence >"$out" 2>"$work/${agent}.stderr"; then
    echo "FAIL  ${agent}: claude exited non-zero" >&2
    head -5 "$work/${agent}.stderr" | sed 's/^/      /' >&2
    failures=$((failures + 1))
    continue
  fi

  if python3 -I - "$out" "$agent" "$marker" <<'PY'
import json
import re
import sys

path, agent, marker = sys.argv[1:4]
calls = {}
results = {}
handbacks = []
for raw in open(path, encoding="utf-8"):
    raw = raw.strip()
    if not raw:
        continue
    event = json.loads(raw)
    content = event.get("message", {}).get("content", [])
    if not isinstance(content, list):
        continue
    for block in content:
        if event.get("type") == "assistant" and block.get("type") == "tool_use":
            if block.get("name") in ("Agent", "Task"):
                calls[block["id"]] = block.get("input", {})
            if block.get("name") == "SubagentHandback":
                handbacks.append(str(block.get("input", {}).get("message", "")))
        if event.get("type") == "user" and block.get("type") == "tool_result":
            body = block.get("content", "")
            if isinstance(body, list):
                body = "\n".join(
                    part.get("text", "") for part in body if isinstance(part, dict)
                )
            results[block.get("tool_use_id")] = str(body)

matching = [i for i, args in calls.items() if args.get("subagent_type") == agent]
if len(matching) != 1:
    print("expected one Agent call to %s, saw %d" % (agent, len(matching)))
    sys.exit(1)
call_id = matching[0]
if marker in json.dumps(calls[call_id]):
    print("the parent put the marker into the spawn prompt, so the probe proves nothing")
    sys.exit(1)
# The harness may launch the agent in the background. Then the Agent tool result is
# only a launch notice, and the child's real answer is its SubagentHandback message.
if len(handbacks) > 1:
    print("expected one SubagentHandback, saw %d" % len(handbacks))
    sys.exit(1)
result = handbacks[0] if handbacks else results.get(call_id)
if not handbacks and result and result.startswith("Async agent launched"):
    print("%s ran in the background and no SubagentHandback was found in the stream" % agent)
    sys.exit(1)
if not result or not result.strip():
    print("the %s call returned no result" % agent)
    sys.exit(1)
if marker in result:
    print("LEAK: %s repeated the parent-only marker" % agent)
    sys.exit(1)
if not re.search(r"^\W*MARKER:\s*UNKNOWN\s*$", result, re.M):
    print("%s did not answer `MARKER: UNKNOWN`; first 200 chars: %r" % (agent, result[:200]))
    sys.exit(1)
print("%s answered UNKNOWN for the parent-only marker" % agent)
PY
  then
    echo "PASS  ${agent}"
  else
    echo "FAIL  ${agent}" >&2
    failures=$((failures + 1))
  fi
done

if [ "$failures" -gt 0 ]; then
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi

printf '\nlive isolation probe passed for: %s\n' "${agents[*]}"
