---
name: nase:help
description: Display a usage guide for this AI engineer workspace. Use when asked "what commands are available?", "how does nase work?", "help", "show commands", "what can you do?", "what skills do you have?", or for an overview of skills and hooks.
pattern: utility
category: Setup & health
model: haiku
effort: low
---

Runs `.claude/scripts/help-summary.py` so command catalog rendering, command capping, KB layout scanning, and workspace-skill listing stay deterministic. The command list comes from `.claude/commands/nase/*.md` frontmatter via `.claude/scripts/command_catalog.py`; README supplies intro and hook prose. Default output is compact; pass `--verbose` for the generated command table plus full hook section.

## Steps

1. Locate the workspace root:
   ```bash
   ROOT=$(git rev-parse --show-toplevel)
   ```
2. Parse the supported flags and run the helper:
   ```bash
   ARGS=()
   case "${ARGUMENTS:-}" in
     "") ;;
     "--verbose") ARGS+=(--verbose) ;;
     *) echo "Usage: /nase:help [--verbose]" >&2; exit 1 ;;
   esac
   python3 "$ROOT/.claude/scripts/help-summary.py" --root "$ROOT" "${ARGS[@]}"
   ```
3. Return the helper output as-is. Do not re-read `README.md` unless the helper fails.

---

## Notes
- Do not hardcode the command list — always read it through `command_catalog.py` so help stays in sync with command frontmatter
- Do not hardcode the KB layout — helper scans `workspace/kb/` so it reflects current structure
- Keep default help to a screenful; `--verbose` preserves the old full-section behavior
- If README.md is missing, the helper still renders commands from `.claude/commands/nase/` filenames
- Follow .claude/docs/language-config.md for conversation vs output language.
