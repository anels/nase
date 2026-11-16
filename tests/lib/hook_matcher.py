"""Resolve which hook scripts a settings.json registers for one event and tool name.

  hook_matcher.py route SETTINGS EVENT TOOL    sorted, comma-joined script names ("" if none)
  hook_matcher.py scripts SETTINGS EVENT       every script registered under EVENT, one per line
  hook_matcher.py selftest                     PASS/FAIL lines for the matcher dialect itself

Matching follows the Claude Code docs: an empty or "*" matcher matches every tool, a matcher
made only of letters, digits, underscore, hyphen, space, comma and "|" is an exact name or
list of names, and anything else is an unanchored regular expression (re.search).
"""

import json
import re
import sys

EXACT_LIST = re.compile(r"[A-Za-z0-9_\- ,|]+")
SCRIPT = re.compile(r'hook-dispatch\.sh"?\s+([A-Za-z0-9_.-]+\.sh)')


def matches(matcher, tool):
    if not matcher or matcher == "*":
        return True
    if EXACT_LIST.fullmatch(matcher):
        return tool in [name.strip() for name in re.split(r"[|,]", matcher)]
    return re.search(matcher, tool) is not None


def registrations(settings, event):
    with open(settings, encoding="utf-8") as fh:
        groups = json.load(fh)["hooks"].get(event, [])
    for group in groups:
        for hook in group.get("hooks", []):
            found = SCRIPT.search(hook.get("command", ""))
            yield group.get("matcher", ""), (found.group(1) if found else hook.get("command", ""))


def selftest():
    checks = {
        "exact list does not match a longer name": not matches("Bash|Monitor", "BashOutput"),
        "exact list matches a member": matches("Bash|Monitor", "Monitor"),
        "regex is unanchored": matches("mcp__.*__slack_add_reaction", "x_mcp__a__slack_add_reaction"),
        "regex honours its end anchor": not matches(
            "mcp__.*__slack_send_message$", "mcp__a__slack_send_message_draft"
        ),
        "empty matcher matches everything": matches("", "Anything"),
    }
    for name, ok in checks.items():
        print(("PASS " if ok else "FAIL ") + name)


def main(argv):
    if len(argv) == 5 and argv[1] == "route":
        _, _, settings, event, tool = argv
        names = {s for m, s in registrations(settings, event) if matches(m, tool)}
        print(",".join(sorted(names)))
        return 0
    if len(argv) == 4 and argv[1] == "scripts":
        _, _, settings, event = argv
        for name in sorted({s for _, s in registrations(settings, event)}):
            print(name)
        return 0
    if len(argv) == 2 and argv[1] == "selftest":
        selftest()
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
