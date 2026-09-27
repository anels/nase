---
name: nase:help
description: "Show the nase command and hook guide. Use for help, show commands, what can you do, what skills are available, or how does nase work."
argument-hint: "[--verbose]"
category: Setup & health
model: haiku
effort: low
---

Runs `.claude/scripts/help-summary.py` so command catalog rendering, command capping, KB layout scanning, and workspace-skill listing stay deterministic. The command list comes from `.claude/commands/nase/*.md` frontmatter via `.claude/scripts/command_catalog.py`; README supplies intro and hook prose. Default output is compact; pass `--verbose` for the generated command table plus full hook section.

## Language

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Translate every user-facing prose string in the helper output to `conversation:`; command names, paths, and hook labels are protocol-fixed identifiers and stay verbatim.

## Steps

1. Read `$ARGUMENTS`. Empty runs the compact helper; exactly `--verbose` runs the verbose helper; anything else is an error - reply `Usage: /nase:help [--verbose]` and stop without running the helper. Decide this before the Bash call: a shell `exit 1` only ends that subshell and does not stop the workflow.
2. Run the helper in **one** Bash call - shell variables do not survive between calls, so the root must be resolved and consumed in the same fence. Append ` --verbose` to the command only for the verbose branch:
   ```bash
   ROOT=$(git rev-parse --show-toplevel) && python3 "$ROOT/.claude/scripts/help-summary.py" --root "$ROOT"
   ```
3. Render the helper output in the configured conversation language. Do not re-read `README.md` unless the helper fails.

---

## Notes
- Do not hardcode the command list - always read it through `command_catalog.py` so help stays in sync with command frontmatter
- Do not hardcode the KB layout - helper scans `workspace/kb/` so it reflects current structure
- Keep default help to a screenful; `--verbose` preserves the old full-section behavior
- If README.md is missing, the helper still renders commands from `.claude/commands/nase/` filenames
