---
name: nase:help
description: Display a usage guide for this AI engineer workspace. Use when asked "what commands are available?", "how does nase work?", "help", "show commands", "what can you do?", "what skills do you have?", or for an overview of skills and hooks.
---

Pulls from README.md dynamically so the help output always matches the actual available commands.

## Steps

1. Read `README.md` at the workspace root (use `git rev-parse --show-toplevel` to locate it)
2. Extract and display:
   - The intro paragraph (what nase is and what it does)
   - The **Available commands** section (all command tables)
   - The **Automatic hooks** section
3. Append a **KB layout** footer — generate it dynamically by scanning `workspace/kb/` subdirectories and `workspace/tasks/`, `workspace/logs/`. Show each directory with a one-line description of its contents. Do not hardcode the layout — the actual directory structure is the source of truth.
4. Also list workspace-specific skills by scanning `workspace/skills/*.md` filenames.

---

## Notes
- Do not hardcode the command list — always read from README.md so help stays in sync
- Do not hardcode the KB layout — always scan `workspace/kb/` so it reflects current structure
- If README.md is missing, fall back to listing `.claude/commands/nase/` filenames
- If the user specifies a conversation language in config.md, use it for the help output.
