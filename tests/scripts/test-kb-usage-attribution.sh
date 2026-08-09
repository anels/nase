#!/usr/bin/env bash
# Regression tests for KB usage skill attribution.
#
# Run from repo root:  bash tests/scripts/test-kb-usage-attribution.sh
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1
LOGGER="$ROOT/.claude/scripts/kb-usage-log.py"

failures=0
source "$ROOT/tests/lib/assert.sh"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

fixture="$TMPROOT/ws"
mkdir -p "$fixture/workspace/kb/projects" "$fixture/workspace/stats"
printf '# notes\n' > "$fixture/workspace/kb/projects/example.md"

skill_of_last_event() {
  python3 - "$fixture/workspace/stats/kb-usage.jsonl" <<'PY'
import json
import pathlib
import sys

lines = [l for l in pathlib.Path(sys.argv[1]).read_text().splitlines() if l.strip()]
print(json.loads(lines[-1])["skill"] if lines else "NO-EVENTS")
PY
}

# A skill activates inside a session that HAS a stable id, exactly as
# track-skill-prompt.sh does from a real Claude Code session.
CLAUDE_SESSION_ID="stable-session-abc" python3 "$LOGGER" activate \
  --root "$fixture" --skill "/nase:kb-review" --source prompt >/dev/null 2>&1

assert_cmd "activation writes the session-keyed context" \
  bash -c 'ls "$1"/workspace/tmp/kb-active-skill-*.json >/dev/null 2>&1' _ "$fixture"
assert_cmd "activation also writes the shared fallback context" \
  test -f "$fixture/workspace/tmp/kb-active-skill-current.json"

# kb-search.sh and kb-domain-resolve.sh run as plain subprocesses with no
# CLAUDE_SESSION_ID, so they resolve a `local-{ppid}` session that no activation
# ever keyed. Before the fallback was written unconditionally, every one of these
# events logged as `unknown` — 385 of 429 unknown events in a 30-day sample.
env -u CLAUDE_SESSION_ID -u CLAUDE_SESSIONID python3 "$LOGGER" record \
  --root "$fixture" \
  --file "workspace/kb/projects/example.md" \
  --access search-result --source kb-search >/dev/null 2>&1
assert_cmd "a session-less kb-search event resolves the active skill" \
  test "$(skill_of_last_event)" = "kb-review"

# An explicit --session still wins over the shared fallback.
CLAUDE_SESSION_ID="stable-session-abc" python3 "$LOGGER" activate \
  --root "$fixture" --skill "/nase:onboard" --source prompt >/dev/null 2>&1
python3 "$LOGGER" record \
  --root "$fixture" --session "stable-session-abc" \
  --file "workspace/kb/projects/example.md" \
  --access read --source read-hook >/dev/null 2>&1
assert_cmd "an explicit session resolves its own activation" \
  test "$(skill_of_last_event)" = "onboard"

# An expired context must not keep attributing events to a stale skill.
stale="$fixture/workspace/tmp/kb-active-skill-current.json"
python3 - "$stale" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timedelta, timezone

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text())
old = datetime.now(timezone.utc) - timedelta(hours=13)
payload["ts"] = old.strftime("%Y-%m-%dT%H:%M:%SZ")
path.write_text(json.dumps(payload, separators=(",", ":")) + "\n")
PY
rm -f "$fixture"/workspace/tmp/kb-active-skill-[0-9a-f]*.json
env -u CLAUDE_SESSION_ID -u CLAUDE_SESSIONID python3 "$LOGGER" record \
  --root "$fixture" \
  --file "workspace/kb/projects/example.md" \
  --access resolve --source kb-domain-resolve >/dev/null 2>&1
assert_cmd "an expired context falls back to unknown" \
  test "$(skill_of_last_event)" = "unknown"

if [[ "$failures" -eq 0 ]]; then
  printf '\nkb-usage-attribution tests passed.\n'
  exit 0
fi

printf '\n%d kb-usage-attribution assertion(s) failed.\n' "$failures" >&2
exit 1
