---
name: nase:kb-review
description: Review, organize, and consolidate knowledge base files — find duplicates, build cross-references, surface stale content, promote lessons into KB, and clean up temporary/outdated files. Use when asked "review KB", "organize notes", "clean up knowledge base", "clean up workspace", "what's in my KB", "整理笔记", "复习", or periodically (weekly/monthly) as knowledge hygiene. Also use when the KB feels messy, when you notice overlapping notes across files, or after a burst of /nase:learn entries that might belong in structured KB files.
---

Review and organize the knowledge base — deduplicate, cross-reference, consolidate, and surface stale content.

**Input:** $ARGUMENTS
(Optional scope: `projects`, `general`, `ops`, `lessons`, or `all`. Default: `all`.)

## Setup

Use `ToolSearch` to fetch `AskUserQuestion` before starting — it's a deferred tool used in Step 6 for execution confirmation. Fetch it once here so it's available when needed.

## Why This Matters

Knowledge bases grow organically — notes get added in the moment without checking what already exists. Over time, the same insight appears in multiple files, related items live in isolation, and old entries become misleading. This skill is the periodic cleanup that keeps the KB useful: it connects what's scattered, removes what's redundant, and surfaces what's forgotten.

## Steps

### Step 0: Determine Scope

Parse $ARGUMENTS to decide what to review:
- `all` or empty → scan everything: `workspace/kb/general/`, `workspace/kb/projects/`, `workspace/kb/ops/`, `workspace/tasks/lessons.md`, `workspace/kb/.domain-map.md`
- `general` → only `workspace/kb/general/*.md`
- `projects` → only `workspace/kb/projects/*.md`
- `ops` → only `workspace/kb/ops/*.md`
- `lessons` → only `workspace/tasks/lessons.md` (review for promotion to KB)
- A specific filename → review that single file in depth

### Step 1: Scan and Index

Read all KB files in parallel for efficiency. For each file, build a mental index of:
- **Topics covered** (1-line per major section or entry)
- **Key entities** mentioned (repos, tickets, dates, tools, services)
- **Last updated** (most recent date found in the content)
- **Entry count** (number of dated entries or sections)

Present a **KB Overview Table**:

```
## KB Overview — {scope}

| File | Topics | Entries | Last Updated | Health |
|------|--------|---------|-------------|--------|
| general/debugging.md | Synthetic alerts, ADF diagnostics | 3 | 2026-03-17 | 🟢 |
| projects/orchestrator.md | Architecture, migrations, CI | 5 | 2026-03-18 | 🟢 |
| ... | ... | ... | ... | ... |

Legend: 🟢 Active (updated <14d) | 🟡 Aging (14-30d) | 🔴 Stale (>30d) | ⚪ Empty
```

### Step 2: Detect Duplicates and Overlaps

Compare content across files looking for:

**Exact duplicates:** Same fact recorded in multiple places (e.g., a debugging tip in both `general/debugging.md` AND a project file AND `lessons.md`).

**Near-duplicates:** Same topic covered from slightly different angles without cross-referencing each other. These aren't necessarily bad — sometimes a pattern belongs in both the general file and the project file — but they should reference each other.

**Contradictions:** Conflicting information across files (e.g., a workflow step that differs between `general/workflow.md` and a project KB).

Present findings:

```
## Duplicates & Overlaps

### 🔴 Contradictions (fix immediately)
1. **{topic}** — `{file1}` says X, `{file2}` says Y. Which is current?

### 🟡 Duplicates (consolidate)
1. **{topic}** — appears in `{file1}` (detailed) and `{file2}` (brief). Suggest: keep in `{file1}`, add cross-ref in `{file2}`.

### 🟢 Healthy overlaps (just add cross-refs)
1. **{topic}** — related content in `{file1}` and `{file2}`, complementary perspectives. Suggest: add "See also" links.
```

### Step 3: Build Cross-References

Identify related items across files that should link to each other but don't:

- A **project KB** mentions a general pattern but doesn't link to the general KB file
- A **lesson** in `lessons.md` is about a topic that has a dedicated KB file but isn't referenced there
- A **project KB** mentions ops procedures also documented in `workspace/kb/ops/`
- An **ops runbook** references a project but doesn't link to that project's KB file
- The **domain map** is missing entries for existing KB files

Present as a **Connection Map**:

```
## Missing Cross-References

| From | To | Connection |
|------|----|-----------:|
| projects/orchestrator.md | general/dotnet.md | Orchestrator uses .NET patterns documented in general |
| lessons.md (ADF diagnostic) | general/debugging.md | Lesson should be promoted to debugging KB |
| ops/dedicated.md | projects/insights.md | Dedicated ops affect Insights deployment |
```

### Step 4: Surface Stale and Orphaned Content

**Stale entries:** Content with dates >30 days old that references ongoing work (not historical records). Historical entries (e.g., "2026-03-02 — Migration patterns") are fine to keep as-is.

**Orphaned files:** KB files not referenced by `.domain-map.md`.

**Empty or near-empty files:** Files with only headers and no substantive content.

**Domain map gaps:** Files in `workspace/kb/` that exist but have no entry in `.domain-map.md`.

**Lessons ready for promotion:** Entries in `workspace/tasks/lessons.md` that are mature enough to be distilled into a KB file. Lessons use `## {category} — {date}` headers (not tags); match by the category word in the header:
- Lessons with `## workflow —` header → candidates for `general/workflow.md`
- Lessons with `## debugging —` header → candidates for `general/debugging.md`
- Lessons with `## code —` header → candidates for `general/dotnet.md` or relevant project KB
- Lessons with `## architecture —` header → candidates for `general/system-design.md` or relevant project KB
- Lessons with `## ops —` header → candidates for `workspace/kb/ops/` files
- Lessons with `## project —` header or about a specific project → candidates for that project's KB file

```
## Stale & Orphaned

### Stale (review for accuracy)
- `{file}`: last entry {date}, {N} days ago — still relevant?

### Orphaned (not in domain map)
- `{file}`: not listed in `.domain-map.md`

### Empty/Sparse
- `{file}`: only has headers, no content

### Lessons → KB Promotion Candidates
- lessons.md "{tip}" → promote to `{target-kb-file}`
```

### Step 4b: Scan for Temporary and Outdated Files

Scan `workspace/` for files that are not part of the KB structure but accumulated during daily work. These waste space, clutter search results, and can confuse future context loading.

**Temporary artifacts** — match by extension or naming pattern:
- Extensions: `.diff`, `.patch`, `.tmp`, `.bak`, `.orig`, `.log` (exclude `workspace/logs/` — those are intentional)
- Patterns: `*-pre-restore-*`, `*-snapshot-*`, `*.backup`

**Outdated one-off files** — files in `workspace/` root (not in standard subdirectories like `kb/`, `logs/`, `tasks/`, `journals/`, `stats/`, `recaps/`, `skills/`, `scripts/`) that haven't been modified in >14 days. These are often ad-hoc files created for a specific task and forgotten.

**Old reports** — files in `workspace/stats/report-*.md` older than 30 days (the latest report supersedes older ones).

```
## Temporary & Outdated Files

### 🗑️ Temp artifacts (safe to delete)
- `{file}` ({size}, {age} days old) — {reason: e.g., "PR diff from review session"}

### 📦 Stale one-off files (review before deleting)
- `{file}` ({size}, last modified {date}) — not in any standard directory

### 📊 Old reports (superseded)
- `{file}` — superseded by `{newer-file}`
```

If no temp/outdated files found, skip this section.

### Step 5: Propose Actions

Based on Steps 2-4, propose concrete actions grouped by effort:

```
## Recommended Actions

### Quick Fixes (do now)
- [ ] Add cross-ref: `{file1}` → `{file2}` ("See also: ...")
- [ ] Fix contradiction: update {file} with correct {fact}
- [ ] Remove duplicate entry from {file} (canonical version in {other-file})
- [ ] Add missing `.domain-map.md` entry for {file}

### Consolidation (review first)
- [ ] Merge `{file1}` and `{file2}` — overlapping scope, suggest single file
- [ ] Promote {N} lessons from lessons.md → {target KB files}
- [ ] Move section "{section}" from {file1} to {file2} (better fit)

### Cleanup (low priority)
- [ ] Archive or populate empty file: {file}
- [ ] Update stale entry in {file} — verify if still accurate
- [ ] Delete temp artifacts: {list of files from Step 4b}
- [ ] Review/delete stale one-off files: {list from Step 4b}
- [ ] Delete superseded reports: {list from Step 4b}
```

### Step 6: Execute (with approval)

**Invoke the `AskUserQuestion` tool** (do not present as plain text):

```
question: "Review complete. What should I apply?"
header: "KB Review — Execute"
options:
  - label: "Apply quick fixes"  , description: "Cross-refs, dedup, contradiction fixes, domain map updates"
  - label: "Apply all"           , description: "Everything including consolidation and cleanup"
  - label: "Just the report"     , description: "Save report to workspace/logs/{YYYY-MM-DD}.md and stop"
```

For each change applied:
- Read the target file first
- Make the edit (add cross-ref, remove duplicate, promote lesson)
- Track what was changed

### Step 7: Summary

Display what was done:

```
## KB Review Complete — {YYYY-MM-DD}

**Scanned:** {N} files across {directories}
**Found:** {N} duplicates, {N} missing cross-refs, {N} stale entries, {N} promotion candidates
**Applied:** {N} quick fixes, {N} consolidations, {N} cleanups
**Skipped:** {N} items (user chose not to apply)

Next review suggested: {date + 7 days}
```

Append a one-line entry to `workspace/logs/{YYYY-MM-DD}.md`:
```
- KB review ({scope}) — {N} files scanned, {N} issues found, {N} fixes applied
```

## Notes

- This skill is read-heavy by design — it needs to load many files to find cross-file patterns. For large KBs, scope to one directory at a time.
- Historical entries (past decisions, old architecture notes) should NOT be flagged as "stale" — they are records. Only flag entries that describe ongoing/future work with old dates.
- When promoting lessons to KB, distill the lesson into the KB file's format (not copy-paste). The lesson stays in lessons.md as the original record; the KB gets a cleaner, integrated version.
- Cross-references use the format: `> See also: [{topic}]({relative-path})` at the end of the relevant section.
