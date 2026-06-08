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

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
PY
ok "command frontmatter has required fields"

disk_tmp=$(mktemp)
readme_tmp=$(mktemp)
runtime_tmp=""

cleanup() {
  rm -f "$disk_tmp" "$readme_tmp"
  if [ -n "$runtime_tmp" ]; then
    rm -rf "$runtime_tmp"
  fi
}
trap cleanup EXIT

find .claude/commands/nase -maxdepth 1 -type f -name '*.md' \
  | sed 's#.*/##; s#\.md$##' \
  | sort > "$disk_tmp"

grep -oE '/nase:[a-z-]+' README.md | sed 's|/nase:||' | sort -u > "$readme_tmp"

if ! cmp -s "$disk_tmp" "$readme_tmp"; then
  echo "[validate] README command drift:" >&2
  comm -23 "$disk_tmp" "$readme_tmp" | sed 's/^/  disk-only: /' >&2
  comm -13 "$disk_tmp" "$readme_tmp" | sed 's/^/  readme-only: /' >&2
  exit 1
fi
ok "README command list matches core command files"

python3 - <<'PY'
import json
import pathlib
import re
import sys

settings = json.loads(pathlib.Path(".claude/settings.json").read_text(encoding="utf-8"))
hooks = settings.get("hooks", {})
errors = []

def has_command(event, script, matcher_fragment=None):
    for group in hooks.get(event, []):
        matcher = group.get("matcher", "")
        if matcher_fragment is not None and matcher_fragment not in matcher:
            continue
        for hook in group.get("hooks", []):
            if script in hook.get("command", ""):
                return True
    return False

requirements = [
    ("SessionStart", "session-start.sh", None),
    ("Stop", "stop-backup.sh", None),
    ("Stop", "stop-todos.sh", None),
    ("PreCompact", "pre-compact-archive.sh", None),
    ("WorktreeRemove", "worktree-log.sh", None),
    ("UserPromptSubmit", "track-skill-prompt.sh", None),
    ("UserPromptSubmit", "style-edit-detect.sh", None),
    ("PreToolUse", "block-dangerous-git.sh", "Bash"),
    ("PreToolUse", "slack-send-guard.sh", "slack_send_message"),
    ("PreToolUse", "jira-write-guard.sh", "JiraIssue"),
    ("PreToolUse", "confluence-size-guard.sh", "ConfluencePage"),
    ("PostToolUse", "track-skill.sh", "Skill"),
    ("PostToolUse", "post-edit-shellcheck.sh", "Edit|Write"),
]

for event, script, matcher in requirements:
    if not has_command(event, script, matcher):
        detail = f"{event} {matcher or ''}".strip()
        errors.append(f"{detail} missing {script}")

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
grep -q '"skill":"today"' "$runtime_tmp/workspace/stats/skill-usage.jsonl"
before_lines=$(wc -l < "$runtime_tmp/workspace/stats/skill-usage.jsonl" | tr -d ' ')
printf '{"prompt":"what does /nase:today do?"}' \
  | NASE_ROOT="$runtime_tmp" bash .claude/hooks/track-skill-prompt.sh
after_lines=$(wc -l < "$runtime_tmp/workspace/stats/skill-usage.jsonl" | tr -d ' ')
[ "$before_lines" = "$after_lines" ]
ok "slash command prompt tracking smoke check"

echo "[validate] all checks passed"
