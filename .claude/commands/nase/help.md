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
3. Append this footer:

---
**KB layout**
```
workspace/kb/
  projects/   ← per-repo knowledge (architecture, constraints, patterns)
  general/    ← cross-project (stack patterns, workflow, debugging, tech-trends)
workspace/tasks/   ← lessons.md, todo.md
workspace/logs/    ← daily logs + .backup-status
```
**Local paths**: `.local-paths` at workspace root (backup target + repo paths). Set during `/nase:init`.

---

## Notes
- Do not hardcode the command list — always read from README.md so help stays in sync
- If README.md is missing, fall back to listing `.claude/commands/nase/` filenames
- If user specify conversation language in config.md, use the conversation to display help.
