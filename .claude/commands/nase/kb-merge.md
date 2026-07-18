---
name: nase:kb-merge
description: "Import a teammate's shared KB with safe merge previews. Use for import KB, merge KB, merge shared KB, or after receiving a /nase:kb-teamshare export."
argument-hint: "<source-kb-path>"
pattern: pipeline
category: Knowledge base
---

Import untrusted shared KB content through reviewable, path-bounded writes. Run `.claude/docs/language-config.md` first and follow `.claude/docs/workspace-write-guard.md`.

## Import Path Hardening

- Resolve the source to a canonical path and verify the canonical path is inside the selected import root.
- Skip symlinks entirely, including symlinked parents and special files.
- Reject absolute paths, `..`, Unicode/case collisions, duplicate normalized targets, and files outside allowed KB/skill layouts.
- Never use an imported path string directly as a write target. Derive the local target from a validated relative path and re-check containment under `workspace/kb/` or `workspace/skills/`.
- Report each rejected item under `Skipped (unsafe path)`.

## Workflow

1. Require an existing readable directory from `$ARGUMENTS`; do not search the whole machine.
2. Inventory regular Markdown files, classify new/conflicting/unchanged/unsafe, and show a file-count preview.
3. For imported skills, run `/nase:skill-audit` before proposing a write. A failed or unavailable audit blocks that skill, not safe KB files.
4. Merge conflicts semantically: preserve local facts, add non-duplicate imported knowledge with provenance, surface contradictions, and never delete local content automatically.
5. Stage complete proposed files under `workspace/tmp/`, show per-file diffs, and batch the concrete write choices.
6. Immediately before apply, re-check each target mtime/hash and staged SHA through `workspace-write-guard.py`. Drift preserves the staged file and blocks only that target.
7. Sanitize generated wrapper metadata: derive descriptions from reviewed text, encode values as YAML double-quoted strings, Strip control characters, cap metadata length, and Never copy imported frontmatter blocks wholesale.
8. Update `workspace/kb/.domain-map.md` only for accepted KB files, through its own guarded diff.
9. Append a daily-log summary and report added, merged, unchanged, unsafe, audit-blocked, and drift-blocked counts.

Do not overwrite conflicts, copy hidden files, execute imported code, or write outside the validated targets.
