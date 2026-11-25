---
name: nase:tech-digest
description: "Fetch a sourced tech-news digest filtered to workspace topics. Use for tech news, what's new, or morning digest."
argument-hint: "[--refresh] [--dry-run] [--since DATE] [--section NAME] [--sources IDS]"
category: Knowledge base
model: sonnet
effort: medium
---

Build a current, source-linked digest only when requested. Follow `.claude/docs/skill-contract.md` and `.claude/docs/content-hash-cache.md`.

## Arguments

Support `--force`/`--refresh` (synonyms), `--dry-run`, `--since <date>`, `--section <name>` (restrict the report to one of the section headings the previous digest used), and `--sources <comma-list>` (restrict fetching to those configured source ids). Reject invalid dates or unknown sections without changing cache state.

## Workflow

1. Load sources (`## Sources`), filter topics (`## Filter Topics`), and output sections (`## Output Sections`) from `workspace/tech-digest-config.md`; if the file is missing, fall back to the topics the previous `workspace/recaps/tech-digest-*.md` filtered on, say so, and suggest `/nase:init` to create the stub. Never embed credentials or private feed tokens in the report.
2. Fetch current primary/official sources first, then reputable secondary sources where they add context. Record publication date and canonical URL.
3. De-duplicate by canonical URL/content hash and skip cached items unless forced. A failed source reduces coverage; it does not reuse stale text as current news.
4. Filter by direct workspace relevance into exactly one of these labels:
   - `adopt` - names a tool, service, or language version this workspace already uses, and something about it changed.
   - `watch` - adjacent to a workspace topic but not yet actionable here.
   - `drop` - no workspace topic matches.

   Keep `adopt` and `watch`; drop the rest. Summarize what changed, why it matters, applicable versions, and one concrete adoption/check action when evidence supports it.
5. For any proposed nase workflow change, identify the exact affected command/doc/script and verify current behavior before recommending a delta. No verified delta means no skill-edit suggestion.
6. Write `workspace/recaps/tech-digest-{YYYY-MM-DD}.md` and update cache only after the report succeeds. `--dry-run` writes neither.
7. If the user chooses a follow-up KB or skill write, treat it as a separate guarded action under `.claude/docs/workspace-write-guard.md`, `.claude/docs/skill-authoring-contract.md`, and `.claude/docs/external-mutation-policy.md`.
8. Return the artifact pointer and up to five highlights.

Do not invent freshness, source dates, product behavior, or adoption value. `/nase:tech-digest` is optional and must not run automatically from `/nase:today`.
