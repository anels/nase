---
name: nase:kb-merge
description: "Import a teammate's shared KB with safe merge previews. Use for import KB, merge KB, merge shared KB, or after receiving a /nase:kb-teamshare export."
argument-hint: "<source-kb-path>"
category: Knowledge base
---

Import untrusted shared KB content through reviewable, path-bounded writes. Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Then follow `.claude/docs/kb-write-routing.md -> Shared admission contract` and `.claude/docs/workspace-write-guard.md`.

## Import Path Hardening

- Resolve the source to a canonical path and verify the canonical path is inside the selected import root.
- Skip symlinks entirely, including symlinked parents and special files.
- Reject absolute paths, `..`, Unicode/case collisions, duplicate normalized targets, and files outside allowed KB/skill layouts.
- Never use an imported path string directly as a write target. Derive the local target from a validated relative path and re-check containment under `workspace/kb/` or `workspace/skills/`.
- An archive member name is an imported path string too. Apply every rule above to each entry before extracting it, reject entries whose extracted canonical path escapes the extraction root, and never rely on the archive tool's own traversal handling.
- Report each rejected item under `Skipped (unsafe path)`.

## Workflow

1. Require an existing readable directory or `.zip`/`.7z` archive from `$ARGUMENTS`; do not search the whole machine. `/nase:kb-teamshare` hands over an archive, so extract it to a fresh `workspace/tmp/kb-merge-{slug}/` under the Import Path Hardening rules above and treat that directory as the source. Never extract in place, and never extract over an existing directory.
2. Inventory regular Markdown files, classify new/conflicting/unchanged/unsafe, and show a file-count preview. Try jev first for that classification (`jev-judgment-points.md` point `kb-merge.classify-file`, `--type Choice`, options `new` / `conflicting` / `unchanged` / `unsafe`; state = the relative path, its validation verdict, and whether a local file of that name exists with a different hash); confidence < 0.9 or unavailable → classify it yourself with the same four labels.
3. For imported skills, run `python3 .claude/scripts/skill-audit-scan.py {staged-skill-path} --format json` before proposing a write and branch on its exit status. Exit `1` is a failed audit. Exit `2` or higher, and a missing interpreter or script, are an unavailable one - the scanner never ran. Both block that skill; neither blocks safe KB files. Say which of the two happened, because "unavailable" is a gap in coverage and "failed" is a finding.
4. Treat each imported file as a staged proposal. Link rewriting and provenance on import are the inverse of the export transformations and are owned by `.claude/docs/kb-teamshare-file-processing.md`; follow it rather than restating them here. Merge conflicts semantically: preserve local facts, add non-duplicate imported knowledge, surface contradictions, and never delete local content automatically. Apply the verification triad in `.claude/docs/kb-template.md` to every imported claim before admission; unresolved or unverifiable claims remain in the import report and are not promoted.
5. Reconcile accepted current-state facts in place, then stage complete proposed files under `workspace/tmp/`, show per-file diffs, and batch the concrete write choices.
6. Immediately before apply, re-check each target mtime/hash and staged SHA through `workspace-write-guard.py`. Drift preserves the staged file and blocks only that target.
7. Sanitize generated wrapper metadata: derive descriptions from reviewed text, encode values as YAML double-quoted strings, Strip control characters, cap metadata length at the 240-character wrapper description cap `tests/check-skill-doctrine.sh` D14 enforces, and Never copy imported frontmatter blocks wholesale.
8. Update `workspace/kb/.domain-map.md` only for accepted KB files, through its own guarded diff.
9. Append a daily-log summary and report added, merged, unchanged, unsafe, audit-blocked, and drift-blocked counts.

Do not overwrite conflicts, copy hidden files, execute imported code, or write outside the validated targets.
