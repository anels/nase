#!/usr/bin/env bash
# Read .claude/extensions.yml and emit hook directives matching an event.
#
# Inspired by GitHub Spec Kit's extension model:
# https://github.github.com/spec-kit/reference/extensions.html
#
# Usage:
#   bash .claude/scripts/extensions-check.sh <event>
#   <event> = before_fsd | after_design | etc. (kebab-case skill name)
#
# Output (to stdout, agent reads it):
#   - For optional hook:  OPTIONAL_HOOK: <command> — <description>
#   - For mandatory hook: EXECUTE_COMMAND: <command> — <description>
#   - If no hooks for the event: emits a single line `NO_HOOKS` and exits 0.
#   - If extensions.yml missing or unparseable: emits `NO_HOOKS` silently
#     and exits 0 (do not block the calling skill).
#
# Exit 0 for all valid event checks; missing event is a usage error.

set -euo pipefail

EVENT="${1:-}"
if [[ -z "$EVENT" ]]; then
  echo "usage: $0 <event-name>" >&2
  exit 2
fi

WORKSPACE="${WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
EXTENSIONS_FILE="$WORKSPACE/.claude/extensions.yml"

if [[ ! -f "$EXTENSIONS_FILE" ]]; then
  echo "NO_HOOKS"
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "NO_HOOKS"
  exit 0
fi

python3 - "$EXTENSIONS_FILE" "$EVENT" <<'PY'
import sys

path, event = sys.argv[1], sys.argv[2]

def no_hooks():
    print("NO_HOOKS")
    sys.exit(0)

def strip_value(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    lowered = value.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    return value

def fallback_parse_extensions(path):
    hooks = {}
    inside_hooks = False
    current_event = None
    current_entry = None

    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.split("#", 1)[0].rstrip()
            if not line.strip():
                continue
            indent = len(line) - len(line.lstrip(" "))
            text = line.strip()

            if indent == 0:
                if text == "hooks:":
                    inside_hooks = True
                    current_event = None
                    current_entry = None
                    continue
                if text == "hooks: {}":
                    return {"hooks": {}}
                if inside_hooks:
                    break
                continue

            if not inside_hooks:
                continue

            if indent == 2 and text.endswith(":"):
                current_event = text[:-1]
                hooks.setdefault(current_event, [])
                current_entry = None
                continue

            if indent == 4 and text.startswith("- "):
                if current_event is None:
                    continue
                current_entry = {}
                hooks[current_event].append(current_entry)
                rest = text[2:].strip()
                if ":" in rest:
                    key, value = rest.split(":", 1)
                    current_entry[key.strip()] = strip_value(value)
                continue

            if indent >= 6 and current_entry is not None and ":" in text:
                key, value = text.split(":", 1)
                current_entry[key.strip()] = strip_value(value)

    return {"hooks": hooks}

try:
    try:
        import yaml
        with open(path, encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
    except ImportError:
        data = fallback_parse_extensions(path)
except Exception:
    no_hooks()

if not isinstance(data, dict):
    no_hooks()

hooks_root = data.get("hooks") or {}
if not isinstance(hooks_root, dict):
    no_hooks()

hooks = hooks_root.get(event)
if not isinstance(hooks, list) or not hooks:
    no_hooks()

emitted = 0
for entry in hooks:
    if not isinstance(entry, dict):
        continue
    if entry.get("enabled") is False:
        continue
    cmd = entry.get("command")
    desc = entry.get("description", "")
    if not cmd:
        continue
    optional = bool(entry.get("optional", False))
    label = "OPTIONAL_HOOK" if optional else "EXECUTE_COMMAND"
    if desc:
        print(f"{label}: {cmd} — {desc}")
    else:
        print(f"{label}: {cmd}")
    emitted += 1

if emitted == 0:
    no_hooks()
PY
