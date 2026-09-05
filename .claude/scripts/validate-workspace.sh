#!/usr/bin/env bash
# Validate nase template wiring, command metadata, and hook backstops.
# Usage: bash .claude/scripts/validate-workspace.sh
set -euo pipefail

NASE_ROOT="${NASE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
if [ -z "$NASE_ROOT" ]; then
  echo "ERROR: cannot resolve workspace root" >&2
  exit 1
fi

cd "$NASE_ROOT"

ok() {
  echo "[validate] OK: $1"
}

python3 -m json.tool .claude/settings.json >/dev/null
ok "settings.json parses"

bash -n .claude/hooks/*.sh
bash -n .claude/scripts/*.sh
ok "hook and script bash syntax"

python3 -m py_compile .claude/scripts/*.py
[ -f .claude/scripts/external-write-action.py ]
ok "python helpers compile"

python3 - <<'PY'
import pathlib
import re
import sys

errors = []

for path in sorted(pathlib.Path(".claude/commands/nase").rglob("*.md")):
    text = path.read_text(encoding="utf-8")
    match = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not match:
        errors.append(f"{path}: missing YAML frontmatter")
        continue
    fields = {}
    for lineno, line in enumerate(match.group(1).splitlines(), 2):
        if not line.strip() or line.startswith("#"):
            continue
        if ":" not in line:
            errors.append(f"{path}:{lineno}: frontmatter line has no ':'")
            continue
        key, value = line.split(":", 1)
        fields[key.strip()] = value.strip()
    for required in ("name", "description"):
        if required not in fields:
            errors.append(f"{path}: missing frontmatter field: {required}")
    if path.parent.name != "workspace" and "category" not in fields:
        errors.append(f"{path}: missing frontmatter field: category")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
PY
ok "command frontmatter has required fields"

runtime_tmp=""

cleanup() {
  if [ -n "$runtime_tmp" ]; then
    rm -rf "$runtime_tmp"
  fi
}
trap cleanup EXIT

python3 .claude/scripts/command_catalog.py --root . --check-readme
ok "README command catalog matches command frontmatter"

python3 - <<'PY'
from pathlib import Path
import re
import sys

known = {path.stem for path in Path(".claude/commands/nase").glob("*.md")}
errors = []

paths = [Path("README.md"), Path("CLAUDE.md")]
paths.extend(sorted(Path(".claude/commands/nase").glob("*.md")))
paths.extend(sorted(Path(".claude/docs").glob("*.md")))

for path in paths:
    if not path.is_file():
        continue
    for lineno, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        for match in re.finditer(r"/nase:([a-z][a-z0-9-]*)(?::[a-z0-9-]+)?", line):
            command = match.group(1)
            if command == "workspace":
                continue
            if command not in known:
                errors.append(f"{path}:{lineno}: unknown command reference /nase:{command}")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
PY
ok "documented /nase command references resolve"

python3 - <<'PY'
import json
import pathlib
import re
import sys

settings = json.loads(pathlib.Path(".claude/settings.json").read_text(encoding="utf-8"))
hooks = settings.get("hooks", {})
errors = []

def matchers_for(event, script):
    return [
        group.get("matcher", "")
        for group in hooks.get(event, [])
        for hook in group.get("hooks", [])
        if script in hook.get("command", "")
    ]

def has_command(event, script, matcher_fragment=None):
    matchers = matchers_for(event, script)
    if matcher_fragment is None:
        return bool(matchers)
    return any(matcher_fragment in matcher for matcher in matchers)

requirements = [
    ("SessionStart", "session-start.sh", None),
    ("Stop", "stop-backup.sh", None),
    ("Stop", "stop-todos.sh", None),
    ("StopFailure", "track-session-failure.sh", None),
    ("PreCompact", "pre-compact-archive.sh", None),
    ("WorktreeRemove", "worktree-log.sh", None),
    ("UserPromptSubmit", "track-skill-prompt.sh", None),
    ("UserPromptExpansion", "track-skill-prompt.sh", "nase:"),
    ("UserPromptSubmit", "style-edit-detect.sh", None),
    ("PreToolUse", "block-dangerous-git.sh", "Bash"),
    ("PreToolUse", "external-cli-write-guard.sh", "Bash"),
    ("PreToolUse", "slack-send-guard.sh", "slack_"),
    ("PreToolUse", "atlassian-generic-write-guard.sh", "execute"),
    ("PreToolUse", "jira-write-guard.sh", "JiraIssue"),
    ("PreToolUse", "confluence-size-guard.sh", "Confluence"),
    ("PostToolUse", "track-kb-read.sh", "Read"),
    ("PostToolUse", "track-skill.sh", "Skill"),
    ("PostToolUse", "post-edit-shellcheck.sh", "Edit|Write"),
    ("PostToolUseFailure", "track-tool-failure.sh", None),
    ("SubagentStop", "track-subagent.sh", None),
]

for event, script, matcher in requirements:
    if not has_command(event, script, matcher):
        detail = f"{event} {matcher or ''}".strip()
        errors.append(f"{detail} missing {script}")

# A guarded MCP write path that gets renamed upstream silently stops matching, and
# the guard then exits 0 on every call. Pin the tool names each guard must still
# see so a rename shows up here instead of in an ungated mutation.
guarded_tool_names = [
    ("confluence-size-guard.sh", ("updateConfluencePage", "updateConfluenceContent",
                                  "createConfluencePage", "createConfluenceContent")),
    ("jira-write-guard.sh", ("addCommentToJiraIssue", "addOrEditJiraIssueComment",
                             "transitionJiraIssue", "editJiraIssue", "createJiraIssue")),
    ("slack-send-guard.sh", ("slack_send_message", "slack_schedule_message")),
    ("atlassian-generic-write-guard.sh", ("executeWrite", "executeDestructive")),
]
for script, tool_names in guarded_tool_names:
    patterns = [re.compile(matcher) for matcher in matchers_for("PreToolUse", script)]
    guard_body = pathlib.Path(".claude/hooks", script).read_text(encoding="utf-8")
    for tool_name in tool_names:
        probe = f"mcp__server__{tool_name}"
        if not any(pattern.search(probe) for pattern in patterns):
            errors.append(f"{script} matcher no longer selects {tool_name}")
        if tool_name not in guard_body:
            errors.append(f"{script} body no longer recognizes {tool_name}")

worktree_create = json.dumps(hooks.get("WorktreeCreate", []))
if "worktree-log.sh" in worktree_create:
    errors.append("worktree-log.sh must not be wired to WorktreeCreate")

docs = pathlib.Path("docs/architecture.md").read_text(encoding="utf-8")
pretool_scripts = []
for group in hooks.get("PreToolUse", []):
    for hook in group.get("hooks", []):
        pretool_scripts.extend(re.findall(r"([A-Za-z0-9_.-]+\.sh)", hook.get("command", "")))
for script in sorted(set(pretool_scripts)):
    if script not in docs:
        errors.append(f"docs/architecture.md missing PreToolUse guard: {script}")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
PY
ok "hook lifecycle and guard wiring"

runtime_tmp=$(mktemp -d)
mkdir -p "$runtime_tmp/workspace/stats"
printf '{"prompt":"/nase:today"}' \
  | NASE_ROOT="$runtime_tmp" bash .claude/hooks/track-skill-prompt.sh
grep -q '"skill":"today".*"event_type":"requested"' "$runtime_tmp/workspace/stats/skill-usage.jsonl"
before_lines=$(wc -l < "$runtime_tmp/workspace/stats/skill-usage.jsonl" | tr -d ' ')
printf '{"prompt":"what does /nase:today do?"}' \
  | NASE_ROOT="$runtime_tmp" bash .claude/hooks/track-skill-prompt.sh
after_lines=$(wc -l < "$runtime_tmp/workspace/stats/skill-usage.jsonl" | tr -d ' ')
[ "$before_lines" = "$after_lines" ]
printf '{"command_name":"nase:stats"}' \
  | NASE_ROOT="$runtime_tmp" HOOK_EVENT_NAME=UserPromptExpansion bash .claude/hooks/track-skill-prompt.sh
grep -q '"skill":"stats".*"source":"prompt-expansion".*"event_type":"activated"' "$runtime_tmp/workspace/stats/skill-usage.jsonl"
ok "slash command prompt tracking smoke check"

mkdir -p "$runtime_tmp/workspace/kb/general"
printf '# telemetry fixture\n' > "$runtime_tmp/workspace/kb/general/telemetry.md"
printf '{"prompt":"/nase:today"}' \
  | NASE_ROOT="$runtime_tmp" CLAUDE_SESSION_ID="validate-kb-usage" bash .claude/hooks/track-skill-prompt.sh
printf '{"tool_input":{"file_path":"workspace/kb/general/telemetry.md"}}' \
  | NASE_ROOT="$runtime_tmp" CLAUDE_SESSION_ID="validate-kb-usage" bash .claude/hooks/track-kb-read.sh
grep -q '"skill":"today"' "$runtime_tmp/workspace/stats/kb-usage.jsonl"
grep -q '"file":"workspace/kb/general/telemetry.md"' "$runtime_tmp/workspace/stats/kb-usage.jsonl"
ok "KB read telemetry smoke check"

python3 .claude/scripts/workspace-quality-scan.py --root . --days 30
ok "workspace quality scan completed (warn-only)"

echo "[validate] all checks passed"
