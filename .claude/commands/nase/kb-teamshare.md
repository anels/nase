---
name: nase:kb-teamshare
description: "Export sanitized KB files or skills for teammates, or import a teammate's export with safe merge previews. Use for share my KB, export KB, share skills, import KB, or merge KB."
argument-hint: "[export] <kb-path-or-skill> | import <source-kb-path>"
category: Knowledge base
model: sonnet
effort: medium
disable-model-invocation: true
---

Move KB content between workspaces through reviewable, sanitized, path-bounded steps.

The first word of `$ARGUMENTS` picks the mode. `export` (the default when the first word is neither) runs `## Export mode` on the rest. `import` runs `## Import mode` on the rest, which is `<source-kb-path>`. Both modes are manual-only.

## Export mode

Create a portable, sanitized export without changing source KB or skills.

1. Resolve the export target to explicit KB files/directories or workspace skill names. Canonicalize each resolved path first, then verify the canonical path is inside `workspace/kb/` or `workspace/skills/`; a prefix test on the raw string accepts `workspace/kb/../../etc`. Reject anything outside those two roots.
2. Follow `.claude/docs/kb-teamshare-file-processing.md` and apply its four transformations in order: Strip Local Absolute Paths, Fix Internal KB Links, Privacy Classification, Translate to Output Language. That doc does not cover frontmatter or archive layout; steps 5-8 below own those.
3. Exclude private/person-specific content, confidential markers, machine paths, tokens, secrets, internal-only identifiers, raw customer data, and ignored temporary files.
4. Preserve useful provenance without copying sensitive URLs or credentials. Replace local cross-links with portable relative links when the target is included; otherwise render a plain reference.
5. For skills, include only reviewed source Markdown and explicitly required docs/scripts. Never include generated wrappers, manifests, logs, caches, or runtime state.
6. Stage the export under `workspace/tmp/kb-teamshare-{slug}-{timestamp}/`. Write the full inventory and redaction summary to `{staging-dir}/MANIFEST.md`; chat gets the pointer and the counts, not the list.
7. Re-scan the staged tree for credential patterns, private keys, auth URLs, absolute home paths, and confidential markers. Any hit blocks packaging until reviewed.
8. Create the archive only after the staged tree passes, as `{staging-dir}.zip` via `zip -r`, with paths relative to the staging directory so no entry name escapes it on extract. Use `7z a` only when `zip` is absent, and name which one you used. Include an import note pointing to `/nase:kb-teamshare import`, which accepts the archive directly.
9. Return the archive path, the `MANIFEST.md` path, and up to five lines carrying file counts, excluded counts, and any content requiring manual review.

Never modify the original knowledge base, follow symlinks, or claim anonymization when a sensitive hit remains.

## Import mode

Import untrusted shared KB content through reviewable, path-bounded writes. Follow `.claude/docs/kb-write-routing.md -> Shared admission contract` and `.claude/docs/workspace-write-guard.md`.

### Import Path Hardening

- Resolve the source to a canonical path and verify the canonical path is inside the selected import root.
- Skip symlinks entirely, including symlinked parents and special files.
- Reject absolute paths, `..`, Unicode/case collisions, duplicate normalized targets, and files outside allowed KB/skill layouts.
- Never use an imported path string directly as a write target. Derive the local target from a validated relative path and re-check containment under `workspace/kb/` or `workspace/skills/`.
- An archive member name is an imported path string too. Apply every rule above to each entry before extracting it, reject entries whose extracted canonical path escapes the extraction root, and never rely on the archive tool's own traversal handling.
- Report each rejected item under `Skipped (unsafe path)`.

### Import workflow

1. Require an existing readable directory or `.zip`/`.7z` archive as `<source-kb-path>`; do not search the whole machine. Export mode hands over an archive, so extract it to a fresh `workspace/tmp/kb-teamshare-import-{slug}/` under the Import Path Hardening rules above and treat that directory as the source. Never extract in place, and never extract over an existing directory.
2. Inventory regular Markdown files, classify new/conflicting/unchanged/unsafe, and show a file-count preview. Decide each label by rule, never by a model. `unsafe` is any path the Import Path Hardening rules above reject. Otherwise `new` is no local file of that name, `unchanged` is a local file with the same SHA-256, and `conflicting` is a local file with a different SHA-256.
3. For imported skills, run `python3 .claude/scripts/skill-audit-scan.py {staged-skill-path} --format json` before proposing a write and branch on its exit status. Exit `1` is a failed audit. Exit `2` or higher, and a missing interpreter or script, are an unavailable one - the scanner never ran. Both block that skill; neither blocks safe KB files. Say which of the two happened, because "unavailable" is a gap in coverage and "failed" is a finding.
4. Treat each imported file as a staged proposal. Link rewriting and provenance on import are the inverse of the export transformations and are owned by `.claude/docs/kb-teamshare-file-processing.md`; follow it rather than restating them here. Merge conflicts semantically: preserve local facts, add non-duplicate imported knowledge, surface contradictions, and never delete local content automatically. Apply the verification triad in `.claude/docs/kb-template.md` to every imported claim before admission; unresolved or unverifiable claims remain in the import report and are not promoted.
5. Reconcile accepted current-state facts in place, then stage complete proposed files under `workspace/tmp/`, show per-file diffs, and batch the concrete write choices.
6. Immediately before apply, re-check each target mtime/hash and staged SHA through `workspace-write-guard.py`. Drift preserves the staged file and blocks only that target.
7. Sanitize generated wrapper metadata: derive descriptions from reviewed text, encode values as YAML double-quoted strings, Strip control characters, cap metadata length at the 240-character wrapper description cap `tests/scripts/test-command-skill-size-budget.sh` enforces, and Never copy imported frontmatter blocks wholesale. Stamp every imported skill's frontmatter with a non-empty `imported-from: team-share` line in the staged file. `sync-workspace-skills.py` then drops `allowed-tools`, `context`, and `agent` from its generated wrapper, so an imported skill cannot pre-approve tools or change where it runs.
8. Update `workspace/kb/.domain-map.md` only for accepted KB files, through its own guarded diff.
9. Append a daily-log summary and report added, merged, unchanged, unsafe, audit-blocked, and drift-blocked counts.

Do not overwrite conflicts, copy hidden files, execute imported code, or write outside the validated targets.
