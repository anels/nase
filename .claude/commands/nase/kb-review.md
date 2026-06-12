---
name: nase:kb-review
description: "Review, organize, consolidate KB files — dedup, cross-ref, surface stale content, promote lessons. Use weekly/monthly as KB hygiene, when KB feels messy, or after several /nase:learn entries. Triggers: 'review KB', 'organize notes', 'clean up KB', 'what's in my KB', '整理笔记'."
pattern: pipeline
sub-patterns: [fan-out]
---

Review and organize the knowledge base — deduplicate, cross-reference, consolidate, and surface stale content.

**Input:** $ARGUMENTS
(Optional scope: `projects`, `general`, `ops`, `lessons`, or `all`. Default: `all`. Optional flag: `--verbose` — also dump all sections inline.)

Follows `.claude/docs/workspace-write-guard.md` for quick fixes, consolidation, lesson promotion, todo archival, and domain-map repairs.

## Output Discipline

The displayed sections in Steps 1–4b ("KB Overview", "Duplicates", "Connection Map", "Relationship Graph", "Stale & Orphaned", "Temp/Outdated") are the **file content** written by Step 7. By default DO NOT print them in chat — they are large and the file is the canonical record.

**Default (no `--verbose`):** chat receives ONLY:
- The Step 7 summary line ("KB Review Complete — counts ...")
- The Step 6 AskUserQuestion (if there are findings to apply)
- `Report saved → workspace/tmp/kb-health-report.md`

**With `--verbose`:** also dump all sections from Steps 1–4b inline (legacy behavior).

This applies whether or not the user passes `--verbose`; build the data internally either way and write it to the report file in Step 7.

## Steps

### Preflight — Language (MUST run before Step 0, non-negotiable)

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. The `kb-health-report.md` written in Step 7 follows `conversation:`; existing KB entry content stays in its source language.

### Step 0: Determine Scope

Parse $ARGUMENTS to decide what to review:
- `all` or empty → scan everything: `workspace/kb/general/`, `workspace/kb/projects/`, `workspace/kb/cross-project/`, `workspace/kb/ops/`, `workspace/tasks/lessons.md`, `workspace/tasks/todo.md`, `workspace/efforts/**/*.md`, `workspace/kb/.domain-map.md`
- `general` → only `workspace/kb/general/*.md`
- `projects` → only `workspace/kb/projects/**/*.md`
- `cross-project` → only `workspace/kb/cross-project/*.md`
- `ops` → only `workspace/kb/ops/*.md`
- `lessons` → only `workspace/tasks/lessons.md` (review for promotion to KB)
- A specific filename → review that single file in depth

### Step 1: Scan and Index

Read all KB files in parallel for efficiency. For each file, build an index of:
- **Topics covered** (1-line per major section or entry)
- **Key entities** mentioned (repos, tickets, dates, tools, services)
- **Entry count** (number of dated entries or sections)
- **Last active date** — follow `.claude/docs/kb-staleness.md` Step A (dual-track entry date + mtime, including the >80%/60-second mtime poison detection that protects against `/nase:restore` resetting timestamps).

For `all` or broad scopes, dispatch `nase-context-kb-researcher` over independent KB domains (`general`, `projects`, `ops`, `cross-project`, `lessons`) in the same turn.
The main thread owns KB edits and report writes: merge indexes, de-duplicate overlap findings, ask before applying fixes, and write through the workspace write guard.

Present a **KB Overview Table**:

```
## KB Overview — {scope}

| File | Topics | Entries | Last Active | Source | Health |
|------|--------|---------|------------|--------|--------|
| general/debugging.md | Synthetic alerts, ADF diagnostics | 3 | 2026-03-17 | entry | 🟢 |
| projects/orchestrator.md | Architecture, migrations, CI | 5 | 2026-04-20 | mtime | 🟢 |
| ... | ... | ... | ... | ... | ... |

Legend: 🟢 Active (<14d) | 🟡 Aging (14-30d) | 🔴 Stale (>30d) | ⚪ Empty
Source: "entry" = date from ### header, "mtime" = date from file modification time
```

### Step 2: Detect Duplicates and Overlaps

Compare content across files looking for:

**Exact duplicates:** Same fact recorded in multiple places (e.g., a debugging tip in both `general/debugging.md` AND a project file AND `lessons.md`).

**Near-duplicates:** Same topic covered from slightly different angles without cross-referencing each other. These aren't necessarily bad — sometimes a pattern belongs in both the general file and the project file — but they should reference each other.

**Contradictions:** Conflicting information across files (e.g., a workflow step that differs between `general/workflow.md` and a project KB).

**Duplicate dated headings:** Same `### YYYY-MM-DD — {topic}` title repeated in one file or across files. Prefer one canonical detailed entry and replace the duplicate with a short pointer.

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
| projects/{repo}.md | general/{stack}.md | Project uses stack patterns documented in general |
| lessons.md ({topic} diagnostic) | general/debugging.md | Lesson should be promoted to debugging KB |
| ops/{env}.md | projects/{repo}.md | Ops procedures affect project deployment |
```

### Step 3b: Relationship Graph

Follow `.claude/docs/kb-relationship-graph.md` for the full algorithm: explicit `> See also:` link counting + implicit basename-mention scanning (with the 5-char minimum to suppress short-name false positives), per-file inbound/outbound records, and the four-subsection Relationship Summary output shape (hubs / orphans / clusters / missing reciprocal links, each capped unless `--verbose`).

**Feed into Step 5:** missing reciprocal links → "Quick Fix" backlink candidates; orphans → "Cleanup" candidates; clusters with overlapping content → Step 2 consolidation suggestions.

### Step 4: Surface Stale and Orphaned Content

Run **`.claude/docs/kb-staleness.md` Steps B, C, D, D2** to derive:

- Stale entries (tier `🔴`) — content dated >30 days old that still describes ongoing work. Historical records are exempt.
- Orphaned files — not referenced by `.domain-map.md`.
- Empty/sparse files.
- Domain map gaps (entries pointing at missing files).
- Lesson promotion candidates — entries in `lessons.md` that clear the maturity threshold, routed to their target KB files.
- Low-value accretion candidates from Step D2 — fold any durable fact into the current-state section it belongs to, then mark the git-recoverable heartbeat for deletion.

Render the findings in the output sections below.

```
## Stale & Orphaned

### Stale (review for accuracy)
- `{file}`: last entry {date}, {N} days ago — still relevant?

### Orphaned (not in domain map)
- `{file}`: not listed in `.domain-map.md`

### Empty/Sparse
- `{file}`: only has headers, no content

### Low-Value Accretion (compaction candidates)
- `{file}`: {N} dated blocks of git-recoverable facts (commit counts, HEAD sha, "no new commits", "no action needed") — fold {durable fact if any} into current-state sections, delete the rest

### Lessons → KB Promotion Candidates
- lessons.md "{tip}" → promote to `{target-kb-file}`
```

### Step 4b: Scan for Temporary and Outdated Files

Run **`.claude/docs/kb-staleness.md` Step E** to derive the three artifact buckets (temp / stale one-off / old reports). The doc owns the extension list, the path exclusion list, and the age thresholds — kb-review just renders the results.

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

### Step 4c: GFM Checkbox Render Audit (one-time, post Claude Code 2.1.149)

Claude Code 2.1.149 renders GFM task-list checkboxes (`- [ ]` / `- [x]`) natively. On the **first review after 2.1.149**, confirm the highest-traffic checkbox files still scan well:

- `workspace/tasks/lessons.md`
- `workspace/efforts/**/*.md`
- `workspace/recaps/*.md`
- `workspace/kb/general/workflow.md` (recommended-actions templates)

**Skip marker** — before running, grep `workspace/stats/kb-review-*.md` for the literal phrase `GFM checkbox render verified`. If any prior report contains it, skip this step silently — the audit ran already.

If any file mixes `[x]` and `[X]`, flag normalization. Otherwise write the literal phrase `GFM checkbox render verified — no action needed` into the current review report so future runs auto-skip.

### Step 4d: Workspace Integrity Audit (all scope only)

For `all` scope, treat the KB as the whole `workspace/` knowledge system, not only files under `workspace/kb/`. Run these deterministic checks and include findings in the report.

**1. Explicit Markdown link integrity**

- Scan Markdown files under `workspace/kb/`, `workspace/tasks/`, `workspace/efforts/`, `workspace/journals/`, and high-signal drafts under `workspace/tmp/*.md`.
- Only parse explicit Markdown links/images (`[text](target)` / `![alt](target)`). Do not flag plain prose path mentions; broad path-reference checks are too noisy.
- Ignore external URLs, `mailto:`, pure anchors, and missing heading anchors when the target file exists. Flag only links whose target file path does not exist.

**2. Domain map schema and path integrity**

- Every `.domain-map.md` entry must have both `[last-updated:YYYY-MM-DD]` and `[last-loaded:YYYY-MM-DD]`.
- Every target path must exist.
- A target under `workspace/kb/projects/` belongs in `## Projects`; `workspace/kb/general/` in `## General`; `workspace/kb/ops/` in `## Ops`; `workspace/kb/cross-project/` in `## Cross-Project`.
- Flag duplicate keys or duplicate target paths unless the duplicate is explicitly documented as an alias.

**3. Effort status taxonomy**

- Active effort files under `workspace/efforts/*.md` must use one of: `in-progress`, `planned`, `ready`, `tracked`.
- Done effort files under `workspace/efforts/done/*.md` must use one of: `completed`, `wontfix`.
- Flag missing frontmatter, `status: closed`, `status: done`, and active efforts whose lifecycle shows everything completed but the status remains active.

**4. Active todo hygiene**

- `workspace/tasks/todo.md` should contain open work only. Flag any `- [x]` line outside archive files.
- Completed items should move to `workspace/tasks/archive/todo-cleanup-{YYYY-MM-DD}.md` or an existing dated archive, with the active file keeping a pointer under `## Archived This Cleanup`.

**5. Workspace entry consistency**

- `workspace/context.md` should have a `last reviewed` comment no older than 30 days.
- If `workspace/config.md` contains legacy `gh_account:`, it should also define explicit `work_gh_account:` and `personal_gh_account:` so the Git Push Policy is unambiguous.

Render the findings:

```
## Workspace Integrity

### Broken explicit Markdown links
- `{file}:{line}` → `{target}` (target file missing)

### Domain map issues
- `{key}` → `{path}` — missing `last-loaded`

### Effort status issues
- `{file}` — `status: done`; use `completed` in `efforts/done/`

### Todo hygiene
- `{file}:{line}` — completed item in active todo; archive it

### Entry consistency
- `{file}` — last reviewed {N} days ago
```

### Step 5: Propose Actions

Based on Steps 2-4, propose concrete actions grouped by effort:

```
## Recommended Actions

### Quick Fixes (do now)
- [ ] Add cross-ref: `{file1}` → `{file2}` ("See also: ...")
- [ ] Fix contradiction: update {file} with correct {fact}
- [ ] Remove duplicate entry from {file} (canonical version in {other-file})
- [ ] Add missing `.domain-map.md` entry for {file}
- [ ] Fix broken explicit Markdown link: `{file}:{line}` → `{target}`
- [ ] Normalize effort status/frontmatter: `{file}`
- [ ] Backfill `.domain-map.md` metadata fields for `{key}`
- [ ] Archive completed todo item from `workspace/tasks/todo.md`

### Consolidation (review first)
- [ ] Merge `{file1}` and `{file2}` — overlapping scope, suggest single file
- [ ] Promote {N} lessons from lessons.md → {target KB files}
- [ ] Move section "{section}" from {file1} to {file2} (better fit)
- [ ] Compact low-value accretion in `{file}` — fold durable facts into current-state, delete git-recoverable heartbeat blocks

### Cleanup (low priority)
- [ ] Archive or populate empty file: {file}
- [ ] Update stale entry in {file} — verify if still accurate
- [ ] Delete temp artifacts: {list of files from Step 4b}
- [ ] Review/delete stale one-off files: {list from Step 4b}
- [ ] Delete superseded reports: {list from Step 4b}
```

### Step 6: Execute (with approval)

Append to daily log following `.claude/docs/daily-log-format.md` (tag: `kb-review`) **before** prompting (ensures the log is written regardless of the user's next choice).
Log: `({scope}) — {N} files scanned, {N} issues found`

**Invoke the `AskUserQuestion` tool** (do not present as plain text):

```
question: "Review complete. What should I apply?"
header: "KB Review — Execute"
options:
  - label: "Apply quick fixes"  , description: "Cross-refs, dedup, broken links, status fixes, domain map updates"
  - label: "Apply all"           , description: "Everything including consolidation and cleanup"
  - label: "Just the report"     , description: "Stop here — the review scan is already logged"
```

For each change applied:
- Read the target file first
- Stage the edited target under `workspace/tmp/`, show the diff, re-check mtime/hash, then make the edit (add cross-ref, remove duplicate, promote lesson)
- Track what was changed

**Lesson promotion procedure** (when promoting from `lessons.md`):
1. Read the lesson entry from `lessons.md`
2. Distill into KB entry format — do NOT copy-paste; rewrite as a clean `### YYYY-MM-DD — {topic}` entry using the standard `kb-update` format (What / Why it matters / Details / Links / Tags)
3. Append to the target KB file in the appropriate section
4. Mark the lesson as promoted by appending to its entry in `lessons.md`:
   ```
   > Promoted → [{KB file basename}](../kb/{relative-path}) on {YYYY-MM-DD}
   ```
5. Do NOT delete the lesson — it stays as the original record; the KB gets the clean, distilled version

### Step 7: Summary

**Write report to file:** Concatenate all output from Steps 1, 2, 3, 3b, 4, 4b, 4c, and 4d into `workspace/tmp/kb-health-report.md` (create `workspace/tmp/` if missing). Overwrite any existing file. Add a header:
```
# KB Health Report — {YYYY-MM-DD}
Generated by `/nase:kb-review {scope}` on {YYYY-MM-DD HH:MM}
```
This file is referenced by `/nase:kb-search` for cached freshness and relationship data.

After writing, print only `Report saved → workspace/tmp/kb-health-report.md`.

Display the summary line below in chat:

```
## KB Review Complete — {YYYY-MM-DD}

**Scanned:** {N} files across {directories}
**Found:** {N} duplicates, {N} missing cross-refs, {N} stale entries, {N} promotion candidates, {N} workspace integrity issues
**Applied:** {N} quick fixes, {N} consolidations, {N} cleanups
**Skipped:** {N} items (user chose not to apply)

Next review suggested: {date + 14 days}
```

Update the log entry written in Step 6 to include the apply count (append `, {N} fixes applied` to the existing line).

### Step 8: Schedule Next Run

Write the next recommended execution date to `workspace/tasks/todo.md` so `/nase:today` can surface it. Stage the todo edit and run the final drift check before applying:

1. Read `workspace/tasks/todo.md`
2. Find the `## Scheduled Maintenance` section — if missing, create it just before `## On Hold` (or at the end if `## On Hold` doesn't exist)
3. Look for an existing line containing `/nase:kb-review` in that section
   - Found → replace the entire line with the updated date
   - Not found → append a new line
4. Format: `- [ ] 📅 {today + 14 days} — \`/nase:kb-review\` — Weekly KB hygiene`

## Notes

- This skill is read-heavy by design — it needs to load many files to find cross-file patterns. For large KBs, scope to one directory at a time.
- Historical entries (past decisions, old architecture notes) should NOT be flagged as "stale" — they are records. Only flag entries that describe ongoing/future work with old dates.
- Lesson promotion follows the procedure in Step 6 — distill (not copy-paste), write to KB using standard entry format, mark as promoted in `lessons.md` with a `> Promoted →` line.
- Cross-references use the format: `> See also: [{topic}]({relative-path})` at the end of the relevant section.
- Workspace integrity checks must stay conservative. Prefer missing fewer issues over flagging conceptual path mentions or historical archive text as broken current state.
