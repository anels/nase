Display a usage guide for this AI engineer workspace.

## Steps

1. Read `README.md` at the workspace root (use `git rev-parse --show-toplevel` to locate it)
2. Extract and display:
   - The intro paragraph ("What's in this template" or equivalent)
   - The **Available commands** section (all command tables)
   - The **Automatic hooks** section
3. Append this footer:

---
**KB layout**
```
work/kb/
  projects/   ← per-repo knowledge (architecture, constraints, patterns)
  general/    ← cross-project (stack patterns, workflow, debugging, tech-trends)
work/tasks/   ← lessons.md, todo.md
work/logs/    ← daily logs + .backup-status
```
**Backup config**: `.backup-target` at workspace root. Set during `/nase:init`.

---

## Notes
- Do not hardcode the command list — always read from README.md so help stays in sync
- If README.md is missing, fall back to listing `.claude/commands/nase/` filenames
