---
name: nase:kb-teamshare
description: "Export sanitized KB files or workspace skills for teammates. Use for share my KB, export knowledge base, share skills, or package content for /nase:kb-merge."
argument-hint: "<kb-path-or-skill>"
pattern: pipeline
category: Knowledge base
---

Create a portable, sanitized export without changing source KB or skills. Run `.claude/docs/language-config.md` first.

## Workflow

1. Resolve `$ARGUMENTS` to explicit KB files/directories or workspace skill names. Reject paths outside `workspace/kb/` and `workspace/skills/`.
2. Follow `.claude/docs/kb-teamshare-file-processing.md` for path handling, portable links, frontmatter, and archive layout.
3. Exclude private/person-specific content, confidential markers, machine paths, tokens, secrets, internal-only identifiers, raw customer data, and ignored temporary files.
4. Preserve useful provenance without copying sensitive URLs or credentials. Replace local cross-links with portable relative links when the target is included; otherwise render a plain reference.
5. For skills, include only reviewed source Markdown and explicitly required docs/scripts. Never include generated wrappers, manifests, logs, caches, or runtime state.
6. Stage the export under `workspace/tmp/kb-teamshare-{slug}-{timestamp}/`. Show the inventory and redaction summary before packaging.
7. Re-scan the staged tree for credential patterns, private keys, auth URLs, absolute home paths, and confidential markers. Any hit blocks packaging until reviewed.
8. Create the archive only after the staged tree passes. Include an import note pointing to `/nase:kb-merge`.
9. Return archive path, file counts, excluded counts, and any content requiring manual review.

Never modify the original knowledge base, follow symlinks, or claim anonymization when a sensitive hit remains.
