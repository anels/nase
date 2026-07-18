---
name: nase:kb-review
description: "Audit and organize KB files for duplicates, links, staleness, and lesson promotion. Use for review KB, organize notes, clean up KB, or periodic KB hygiene."
argument-hint: "[domain/path]"
pattern: pipeline
category: Knowledge base
sub-patterns: [fan-out]
---

Audit KB health first, then apply only approved changes. Run `.claude/docs/language-config.md` first, follow `.claude/docs/skill-contract.md`, and route durable writes through `.claude/docs/workspace-write-guard.md`.

## Workflow

1. Resolve `$ARGUMENTS` to all KB, one domain, or one bounded path. Reject targets outside `workspace/kb/`.
2. Run `.claude/scripts/kb-hygiene-scan.py` and index headings, explicit links, domain-map entries, age, size, and lesson candidates.
3. For broad reviews, dispatch read-only `nase-context-kb-researcher` slices for disjoint domains. The main thread owns KB edits and report writes.
4. Classify findings as contradictions, duplicates, healthy overlaps, missing cross-references, stale content, orphans, sparse files, temporary artifacts, and lesson-promotion candidates.
5. Use `.claude/docs/kb-relationship-graph.md` for relationship checks and `.claude/docs/kb-staleness.md` for staleness. Do not treat age alone as proof that a fact is obsolete.
6. For full scope, audit explicit Markdown links, domain-map integrity, effort references, todo hygiene, and entry consistency. Separate broken links from inert code-span references.
7. Write the complete health report to `workspace/recaps/kb-review-{YYYY-MM-DD}.md`; chat gets the pointer and top findings.
8. Present quick fixes, consolidation, and deletion candidates with exact paths. No mutation occurs before the user approves the concrete set.
9. For approved changes, stage every full target, show diffs, and apply with mtime/hash/staged-hash drift checks. Never auto-delete a non-empty file.
10. Re-run the scanner and link/domain-map checks. Report applied, skipped, drifted, and still-open findings.

Missing evidence stays a finding, not a rewrite. Preserve provenance, project boundaries, and confidential markers.
