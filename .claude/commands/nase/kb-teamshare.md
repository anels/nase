---
name: nase:kb-teamshare
description: "Export sanitized KB files or workspace skills for teammates. Use for share my KB, export knowledge base, share skills, or package content for /nase:kb-merge."
argument-hint: "<kb-path-or-skill>"
category: Knowledge base
---

Create a portable, sanitized export without changing source KB or skills. Follow `.claude/docs/language-config.md` → Minimum Step 0 block.

## Workflow

1. Resolve `$ARGUMENTS` to explicit KB files/directories or workspace skill names. Canonicalize each resolved path first, then verify the canonical path is inside `workspace/kb/` or `workspace/skills/`; a prefix test on the raw string accepts `workspace/kb/../../etc`. Reject anything outside those two roots.
2. Follow `.claude/docs/kb-teamshare-file-processing.md` and apply its four transformations in order: Strip Local Absolute Paths, Fix Internal KB Links, Privacy Classification, Translate to Output Language. That doc does not cover frontmatter or archive layout; steps 5-8 below own those.
3. Exclude private/person-specific content, confidential markers, machine paths, tokens, secrets, internal-only identifiers, raw customer data, and ignored temporary files.
4. Preserve useful provenance without copying sensitive URLs or credentials. Replace local cross-links with portable relative links when the target is included; otherwise render a plain reference.
5. For skills, include only reviewed source Markdown and explicitly required docs/scripts. Never include generated wrappers, manifests, logs, caches, or runtime state.
6. Stage the export under `workspace/tmp/kb-teamshare-{slug}-{timestamp}/`. Write the full inventory and redaction summary to `{staging-dir}/MANIFEST.md`; chat gets the pointer and the counts, not the list.
7. Re-scan the staged tree for credential patterns, private keys, auth URLs, absolute home paths, and confidential markers. Any hit blocks packaging until reviewed.
8. Create the archive only after the staged tree passes, as `{staging-dir}.zip` via `zip -r`, with paths relative to the staging directory so no entry name escapes it on extract. Use `7z a` only when `zip` is absent, and name which one you used. Include an import note pointing to `/nase:kb-merge`, which accepts the archive directly.
9. Return the archive path, the `MANIFEST.md` path, and up to five lines carrying file counts, excluded counts, and any content requiring manual review.

Never modify the original knowledge base, follow symlinks, or claim anonymization when a sensitive hit remains.
