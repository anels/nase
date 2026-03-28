---
name: nase:kb-merge
description: Import and merge a teammate's shared knowledge base into your own workspace KB — intelligently merges overlapping files, shows a diff preview before writing, and updates the domain map. Use when asked "import KB", "merge KB", "import knowledge base", "merge shared KB", "导入KB", "合并知识库", or after receiving a KB export from /nase:kb-teamshare.
---

Merge an externally shared KB directory into your local `workspace/kb/`, with AI-assisted conflict resolution and a diff preview before any changes are written.

**Input:** $ARGUMENTS
(Optional: path to the imported KB directory. If not provided, will ask interactively.)

## Setup

Use `ToolSearch` to fetch `AskUserQuestion` before starting — it's a deferred tool used in Steps 1 and 4 for interactive prompts. Fetch it once here so it's available when needed.

## Why This Matters

Knowledge bases diverge across teammates: you've solved problems they haven't seen, they've learned patterns you don't have. This skill lets you absorb a teammate's KB without losing your own — it adds what's new, intelligently merges what overlaps, and gives you a clear preview of every change before writing anything.

## Steps

### Step 1: Locate the Imported KB

If $ARGUMENTS contains a directory path, use it. Otherwise, **invoke `AskUserQuestion`**:

```
question: "Where is the KB directory to import?"
header: "Import path"
options:
  - label: "~/Desktop/nase-kb-export"
    description: "Check the Desktop"
  - label: "~/Downloads/nase-kb-export"
    description: "Check Downloads"
  - label: "Custom path"
    description: "I'll specify the path myself"
```

If "Custom path" is chosen, invoke `AskUserQuestion` again to collect the path.

Verify the directory exists and contains a `.domain-map.md` (or at minimum a recognizable KB structure with `general/`, `projects/`, or `ops/` subdirectories). If neither is found, report the issue and stop.

### Step 2: Scan and Categorize

Read the imported `.domain-map.md` (if present) and scan the directory structure. For each file found in the imported KB, check whether a corresponding file exists locally in `workspace/kb/`:

Build two lists:

**New files** — exist in the import but not locally:
- These can be added directly (no merge needed)

**Conflicting files** — exist in both the import and locally:
- These require AI-assisted merge

Present the categorization:

```
## Import Preview — {imported-dir}

### New files (will be added)
- general/spark-scala.md
- projects/some-project.md

### Conflicting files (will be merged)
- general/dotnet.md  — both local and imported versions exist
- ops/oncall.md      — both local and imported versions exist

### Skipped (in import but empty or unrecognizable)
- (none)
```

### Step 3: AI Merge for Conflicting Files

For each conflicting file, read both the local version and the imported version. Produce a merged version that:

- **Preserves all unique content from both sides** — do not discard anything
- **Deduplicates** exact or near-identical facts (keep the most complete/accurate version)
- **Resolves contradictions** by flagging them with a comment: `<!-- MERGE CONFLICT: local says X, imported says Y — verify which is current -->`
- **Maintains the local file's structure and section order** as the base; insert imported-only sections at the end under a `## From teammate` heading if they don't fit naturally elsewhere

For each merged file, produce a diff summary in this format:

```
### general/dotnet.md
+ Added: "EF Core retry-on-deadlock pattern" (from imported)
+ Added: "Nullable reference types — project-level setting" (from imported)
~ Merged: "Connection string config" — both versions combined
✗ Flagged: "Target framework" — local says net8.0, imported says net9.0 (verify)
= Unchanged: everything else
```

### Step 4: Diff Preview

Present the complete diff preview for all files before writing anything:

```
## Merge Plan — {N} files

### Files to add ({N})
{list of new files with one-line description of their content}

### Files to merge ({N})
{per-file diff summary from Step 3}

### Files unchanged / skipped ({N})
{list}
```

**Invoke `AskUserQuestion`**:

```
question: "Review the merge plan above. How should I proceed?"
header: "Confirm merge"
options:
  - label: "Apply all"
    description: "Write all new files and all merged files as shown"
  - label: "Apply new files only"
    description: "Add new files only — skip conflicting files for now"
  - label: "Let me pick file by file"
    description: "I'll decide for each conflicting file individually"
  - label: "Cancel"
    description: "Don't write anything"
```

If "Let me pick file by file": for each conflicting file, **invoke `AskUserQuestion`**:

```
question: "How to handle general/dotnet.md?"
header: "File: dotnet.md"
options:
  - label: "Apply AI merge"
    description: "Use the merged version produced in Step 3"
  - label: "Keep local"
    description: "Skip this file — keep my current version"
  - label: "Replace with imported"
    description: "Overwrite my local version with the imported one"
```

### Step 5: Write Changes

For each file approved in Step 4:

**New files:** Write directly to `workspace/kb/{category}/{filename}`. Create the category directory if it doesn't exist.

**Merged files:** Write the AI-merged content (from Step 3) to `workspace/kb/{category}/{filename}`, overwriting the local version.

### Step 6: Update Domain Map

Read `workspace/kb/.domain-map.md`. For each newly added file that doesn't yet have an entry in the domain map, add it under the correct section:

```markdown
## General
- spark-scala → workspace/kb/general/spark-scala.md   ← added

## Projects
- some-project → workspace/kb/projects/some-project.md  ← added
```

Write the updated `.domain-map.md`.

### Step 7: Summary

Display what was done:

```
## KB Merge Complete — {YYYY-MM-DD}

**Source:** {imported-dir}

### Applied
- Added: {N} new files
- Merged: {N} conflicting files
- Skipped: {N} files (user chose to keep local)

### Flagged for manual review
- general/dotnet.md: "Target framework" conflict (line 12) — verify net8 vs net9
- (any MERGE CONFLICT comments inserted)

### Domain map
- {N} new entries added
```

If any `MERGE CONFLICT` comments were inserted, remind the user:

```
⚠ {N} conflicts were flagged inline with <!-- MERGE CONFLICT --> comments.
Run /nase:kb-review to find and resolve them.
```

Append a one-line entry to `workspace/logs/{YYYY-MM-DD}.md`:
```
- KB merge from {source} — {N} added, {N} merged, {N} skipped
```

## Notes

- Never write files without showing the diff preview in Step 4 first — the user must confirm before any changes are persisted.
- Merge conflicts flagged with `<!-- MERGE CONFLICT -->` are intentional — they surface genuine disagreements between two sources of truth that a human should resolve.
- If the imported KB has no `.domain-map.md`, infer categories from directory structure (`general/`, `projects/`, `ops/`). Files in unknown subdirectories go into `general/` with a note.
- The imported KB may have been sanitized (e.g., `<REPO_PATH:Foo>` placeholders). Leave these as-is in the merged file — they're informative even without the actual path.
- `workspace/tasks/lessons.md` and logs are local-only records — never import them.
