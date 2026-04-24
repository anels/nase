---
name: nase:kb-review
description: Review, organize, and consolidate knowledge base files — find duplicates, build cross-references, surface stale content, promote lessons into KB, and clean up temporary/outdated files. Use when asked "review KB", "organize notes", "clean up knowledge base", "clean up workspace", "what's in my KB", "整理笔记", "复习", or periodically (weekly/monthly) as knowledge hygiene. Also use when the KB feels messy, when you notice overlapping notes across files, or after a burst of /nase:learn entries that might belong in structured KB files.
---

Review and organize the knowledge base — deduplicate, cross-reference, consolidate, and surface stale content.

**Input:** $ARGUMENTS
(Optional scope: `projects`, `general`, `ops`, `lessons`, or `all`. Default: `all`.)

## Setup

Needs: `AskUserQuestion` (fetch via ToolSearch).

## Steps

### Step 0: Determine Scope

Parse $ARGUMENTS to decide what to review:
- `all` or empty → scan everything: `workspace/kb/general/`, `workspace/kb/projects/`, `workspace/kb/cross-project/`, `workspace/kb/ops/`, `workspace/tasks/lessons.md`, `workspace/kb/.domain-map.md`
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
- **Last active date** — use dual-track detection:
  - **Track 1 (entry date):** most recent `### YYYY-MM-DD` date found in the content
  - **Track 2 (file mtime):** run `stat -f %m {file}` (macOS) to get Unix epoch, convert to YYYY-MM-DD. If `stat` fails for any file (broken symlink, permission denied), skip Track 2 for that file.
  - **Last active = the MORE RECENT of Track 1 and Track 2**
  - ⚠️ mtime is a "best effort" signal — `/nase:restore` resets all mtimes to restore-time. **Detection:** if >80% of scanned files share the same mtime (within 60 seconds of each other), ignore Track 2 entirely and rely solely on entry dates.

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

Build a relationship graph across all in-scope KB files using two signal types:

**Explicit links:** Count existing `> See also:` lines in each file. Parse the markdown link target to identify which KB file is referenced. Record inbound and outbound counts per file.

**Implicit mentions:** For each KB file, extract its basename without extension (e.g., `insights-monitoring` from `insights-monitoring.md`). Then scan every OTHER file's content for that basename string (case-insensitive). A match means the other file implicitly references this one. Exclude:
- Self-references (file mentioning its own basename)
- Matches inside `> See also:` lines (already counted as explicit)
- **Basenames shorter than 5 characters** (e.g., `cli`, `sre`) — these produce too many false positives. Short-named files are tracked via explicit `> See also:` links only.

For each file, record:
- **Outbound explicit** — count of `> See also:` links FROM this file
- **Outbound implicit** — count of other-file basenames mentioned in this file's body
- **Inbound explicit** — count of `> See also:` links in OTHER files pointing TO this file
- **Inbound implicit** — count of other files whose body mentions THIS file's basename

Present a **Relationship Summary** (each subsection is capped to prevent output bloat — parse `--verbose` from $ARGUMENTS in Step 0 to remove caps):

```
## Relationship Graph

### 🔗 Hub files (top 5 by total connections)
| File | In (explicit) | In (implicit) | Out (explicit) | Out (implicit) | Total |
|------|--------------|--------------|----------------|----------------|-------|
| projects/insights.md | 5 | 12 | 9 | 3 | 29 |
| ... | ... | ... | ... | ... | ... |

### 🏝️ Orphans (zero inbound references — max 10)
- `general/spark-scala.md` — 0 inbound links, 2 outbound. Consider: is this file discoverable?
- ...

### 🔄 Clusters (groups of 3+ mutually-referencing files — max 5)
- **insights-* family:** insights.md ↔ insights-monitoring.md ↔ insights-containerimages.md ↔ insights-dashboarding.md ↔ insights-ops.md
- ...

### ➡️ Missing reciprocal links (A links to B, but B doesn't link back — max 10)
| From | Links to | But missing backlink |
|------|----------|---------------------|
| general/debugging.md | ops/oncall.md | ops/oncall.md → general/debugging.md |
| ... | ... | ... |
```

If any section exceeds its cap, append: `({N} more — run /nase:kb-review --verbose for full list)`.

**Feed into Step 5:** Missing reciprocal links become "Quick Fix" candidates (add `> See also:` backlinks). Orphans become "Cleanup" candidates (review for relevance). Clusters with overlapping content feed into Step 2 consolidation suggestions.

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

**Maturity threshold** — a lesson is ready for promotion when ANY of:
- Added >14 days ago (time validates the pattern)
- Same pattern appears in 2+ separate lesson entries (frequency = importance)
- Lesson explicitly notes "add to KB" or describes a recurring mistake

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

**Outdated one-off files** — files in `workspace/` root (not in standard subdirectories like `kb/`, `logs/`, `tasks/`, `journals/`, `stats/`, `recaps/`, `skills/`, `scripts/`, `tmp/`) that haven't been modified in >14 days. These are often ad-hoc files created for a specific task and forgotten.

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

Append a one-line entry to `workspace/logs/{YYYY-MM-DD}.md` **before** prompting (ensures the log is written regardless of the user's next choice):
```
- KB review ({scope}) — {N} files scanned, {N} issues found
```

**Invoke the `AskUserQuestion` tool** (do not present as plain text):

```
question: "Review complete. What should I apply?"
header: "KB Review — Execute"
options:
  - label: "Apply quick fixes"  , description: "Cross-refs, dedup, contradiction fixes, domain map updates"
  - label: "Apply all"           , description: "Everything including consolidation and cleanup"
  - label: "Just the report"     , description: "Stop here — the review scan is already logged"
```

For each change applied:
- Read the target file first
- Make the edit (add cross-ref, remove duplicate, promote lesson)
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

**Write report to file:** Before displaying the summary, concatenate all output from Steps 1, 2, 3, 3b, 4, and 4b into `workspace/tmp/kb-health-report.md` (create `workspace/tmp/` if missing). Overwrite any existing file. Add a header:
```
# KB Health Report — {YYYY-MM-DD}
Generated by `/nase:kb-review {scope}` on {YYYY-MM-DD HH:MM}
```
This file is referenced by `/nase:kb-search` for cached freshness and relationship data.

Display what was done:

```
## KB Review Complete — {YYYY-MM-DD}

**Scanned:** {N} files across {directories}
**Found:** {N} duplicates, {N} missing cross-refs, {N} stale entries, {N} promotion candidates
**Applied:** {N} quick fixes, {N} consolidations, {N} cleanups
**Skipped:** {N} items (user chose not to apply)

Next review suggested: {date + 7 days}
```

Update the log entry written in Step 6 to include the apply count (append `, {N} fixes applied` to the existing line).

### Step 8: Schedule Next Run

Write the next recommended execution date to `workspace/tasks/todo.md` so `/nase:today` can surface it:

1. Read `workspace/tasks/todo.md`
2. Find the `## Scheduled Maintenance` section — if missing, create it just before `## On Hold` (or at the end if `## On Hold` doesn't exist)
3. Look for an existing line containing `/nase:kb-review` in that section
   - Found → replace the entire line with the updated date
   - Not found → append a new line
4. Format: `- [ ] 📅 {today + 7 days} — \`/nase:kb-review\` — Weekly KB hygiene`

## Notes

- This skill is read-heavy by design — it needs to load many files to find cross-file patterns. For large KBs, scope to one directory at a time.
- Historical entries (past decisions, old architecture notes) should NOT be flagged as "stale" — they are records. Only flag entries that describe ongoing/future work with old dates.
- Lesson promotion follows the procedure in Step 6 — distill (not copy-paste), write to KB using standard entry format, mark as promoted in `lessons.md` with a `> Promoted →` line.
- Cross-references use the format: `> See also: [{topic}]({relative-path})` at the end of the relevant section.
