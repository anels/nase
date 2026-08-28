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

# --- reaper: activate must bound workspace/tmp, not just append to it ----------
# Before this, `activate` was write-only and every session left its context file
# behind for good (149 files, 70 past the TTL, on a live workspace).
reap_fixture="$TMPROOT/reap"
mkdir -p "$reap_fixture/workspace/kb/projects" "$reap_fixture/workspace/stats" \
  "$reap_fixture/workspace/tmp"
printf '# notes\n' > "$reap_fixture/workspace/kb/projects/example.md"

python3 - "$reap_fixture/workspace/tmp" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timedelta, timezone

tmp = pathlib.Path(sys.argv[1])
now = datetime.now(timezone.utc)


def write(name, age_hours):
    ts = (now - timedelta(hours=age_hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
    payload = {"ts": ts, "skill": "fsd", "source": "prompt",
               "session": name, "sessionless": False}
    (tmp / name).write_text(json.dumps(payload, separators=(",", ":")) + "\n")


write("kb-active-skill-aaaaaaaaaaaaaaaa.json", 13)   # past the 12h TTL
write("kb-active-skill-bbbbbbbbbbbbbbbb.json", 99)   # long past it
write("kb-active-skill-cccccccccccccccc.json", 1)    # still live
(tmp / "kb-active-skill-dddddddddddddddd.json").write_text("{not json\n")  # unparseable
PY

CLAUDE_SESSION_ID="reaper-session" python3 "$LOGGER" activate \
  --root "$reap_fixture" --skill "/nase:fsd" --source prompt >/dev/null 2>&1

assert_cmd "reaper removes a context past the TTL" \
  test ! -f "$reap_fixture/workspace/tmp/kb-active-skill-aaaaaaaaaaaaaaaa.json"
assert_cmd "reaper removes a long-expired context" \
  test ! -f "$reap_fixture/workspace/tmp/kb-active-skill-bbbbbbbbbbbbbbbb.json"
assert_cmd "reaper keeps a context inside the TTL" \
  test -f "$reap_fixture/workspace/tmp/kb-active-skill-cccccccccccccccc.json"
assert_cmd "reaper removes an unparseable context" \
  test ! -f "$reap_fixture/workspace/tmp/kb-active-skill-dddddddddddddddd.json"
assert_cmd "reaper never removes the shared fallback" \
  test -f "$reap_fixture/workspace/tmp/kb-active-skill-current.json"
assert_cmd "reaper never removes the context this activation just wrote" \
  bash -c 'ls "$1"/workspace/tmp/kb-active-skill-[0-9a-f]*.json >/dev/null 2>&1' _ "$reap_fixture"

if [[ "$failures" -eq 0 ]]; then
  printf '\nkb-usage-attribution tests passed.\n'
  exit 0
fi

printf '\n%d kb-usage-attribution assertion(s) failed.\n' "$failures" >&2
exit 1
