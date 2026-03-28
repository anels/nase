---
name: nase:kb-teamshare
description: Export and share your knowledge base with teammates — sanitizes personal info, fixes internal links to be portable, and lets you pick exactly which KB files to include. Also supports sharing learned workspace skills. Use when asked "share my KB", "export KB", "export knowledge base", "share knowledge", "share skills", "给同事分享KB", "导出知识库", or when you want to package KB files or skills for others to import with /nase:kb-merge.
---

Export selected KB files and workspace skills as a portable, sanitized directory ready to share with teammates.

**Input:** $ARGUMENTS
(Optional: target directory path. If not provided, will ask interactively.)

## Setup

Use `ToolSearch` to fetch `AskUserQuestion` before starting — it's a deferred tool used throughout Steps 1–4 for interactive prompts. Fetch it once here so it's available when needed.

## Step 0: Load Language Config

Read `workspace/config.md` and extract:
- `conversation:` → language for all AskUserQuestion prompts and responses to the user in this session
- `output:` → language for any text written into the exported files themselves

If `workspace/config.md` is missing or has no `## Language` section, default both to English.

Use these settings consistently throughout every step below.

## Why This Matters

Your KB contains machine-specific paths, usernames, and internal details that make no sense to others — or that you shouldn't share. This skill strips the machine-specific details, rewires internal cross-links to stay valid in the exported directory, and gives you control over exactly what gets shared. The result is a clean directory your teammates can drop into their own workspace with `/nase:kb-merge`.

## Steps

### Step 1: Determine Export Target

If $ARGUMENTS contains a directory path, use it as the export target. Otherwise, **invoke `AskUserQuestion`**:

```
question: "Where should I export the KB files?"
header: "Export path"
options:
  - label: "~/Desktop/nase-kb-export"
    description: "Desktop — easy to find and share"
  - label: "~/Downloads/nase-kb-export"
    description: "Downloads folder"
  - label: "Custom path"
    description: "I'll specify the path myself"
```

If "Custom path" is chosen, invoke `AskUserQuestion` again to collect the actual path.

### Step 2: Select Categories

**Invoke `AskUserQuestion`** (multiSelect):

```
question: "Which content do you want to include?"
header: "Export scope"
multiSelect: true
options:
  - label: "general/ — tech knowledge"
    description: "dotnet, workflow, llm, debugging, etc. — usually the safest to share"
  - label: "projects/ — project-specific KB"
    description: "Repo architecture, constraints, patterns. Contains more personal details — will be sanitized."
  - label: "ops/ — operations knowledge"
    description: "Oncall, customer support, runbooks. May contain internal company info — will be sanitized."
  - label: "skills/ — workspace skills"
    description: "Custom learned skills from workspace/skills/ (e.g. investigate-sre-jira.md). Shared as standalone skill files."
```

### Step 3: Select Specific Files

Read `workspace/kb/.domain-map.md` to get the list of KB files in each selected KB category. For `skills/`, list all `.md` files found in `workspace/skills/`.

First **invoke `AskUserQuestion`**:

```
question: "Which files to include?"
header: "File selection"
options:
  - label: "All files in selected categories"
    description: "Include everything from the categories you chose"
  - label: "Let me pick individually"
    description: "I'll review the file list and choose"
```

If "All files": record all files from the selected categories and proceed to Step 4.

If "Let me pick individually": **print the full file list in your response first** (since AskUserQuestion options are limited to 4, don't try to enumerate files there). Format it as a numbered list grouped by category, e.g.:

```
**general/** (8 files)
1. dotnet.md — .NET patterns, EF Core, DI
2. workflow.md — dev workflow, PR rules
...

**ops/** (3 files)
8. oncall.md — alert patterns and runbooks
...

**skills/** (3 files)
11. investigate-sre-jira.md — end-to-end SRE ticket investigation
12. handle-support-question.md — customer support workflow
...
```

Then invoke `AskUserQuestion`:

```
question: "Type the numbers of the files to include (e.g. '1,3,8'). Use 'Other' to enter your selection."
header: "Pick files"
options:
  - label: "All from general/ only"
    description: "Include all general/ files, skip others"
  - label: "All from skills/ only"
    description: "Include all workspace skills, skip KB files"
  - label: "All KB files (no skills)"
    description: "general/, projects/, ops/ — exclude skills"
  - label: "Custom selection"
    description: "Use 'Other' to type the file numbers you want"
```

Parse the user's answer (whether a preset option or custom "Other" text with numbers) into the final file list.

Record the final list of files to export, separated by type:
- KB files: absolute paths under `workspace/kb/`
- Skill files: absolute paths under `workspace/skills/`

### Step 4: Process Each File

For each selected file, read the content and apply these transformations in order:

#### 4a — Strip Local Absolute Paths

Replace any absolute path patterns that are machine-specific:

| Pattern | Replacement |
|---------|------------|
| `/Users/[^/\s"'\)]+/repos/([^/\s"'\)]+)` | `<REPO_PATH:\1>` — e.g. `/Users/ruilin.liu/repos/Insights-Dashboarding` → `<REPO_PATH:Insights-Dashboarding>` |
| `/Users/[^/\s"'\)]+/` | `<HOME>/` |
| `/home/[^/\s"'\)]+/` | `<HOME>/` |

Apply via regex substitution. If a path appears in a context that isn't a local machine path (e.g., a URL or a quoted string with a different meaning), use your judgment — when unsure, **invoke `AskUserQuestion`** to confirm with the user before removing it.

#### 4b — Fix Internal KB Links

Internal KB cross-references use the form `workspace/kb/category/file.md`. These break when the files are exported to a different directory. Fix them as follows:

- **If the linked file IS in the export set:** rewrite the link to a relative path within the export directory.
  - `workspace/kb/general/dotnet.md` → `general/dotnet.md`
  - `workspace/kb/projects/foo.md` → `projects/foo.md`
  - Markdown link format: `[text](workspace/kb/X/Y.md)` → `[text](X/Y.md)`
  - Plain text references: replace the path string directly
- **If the linked file is NOT in the export set:** remove the entire line containing the link. A dangling reference with no destination is worse than nothing — it just confuses the reader.

Similarly, for skill file references (e.g. `workspace/skills/investigate-sre-jira.md`):
- If the referenced skill IS in the export set: rewrite to `skills/investigate-sre-jira.md`
- If NOT in the export set: remove the entire line

#### 4c — Privacy Classification

After path-stripping, do a structured pass across all selected files together. Classify every potentially sensitive item into one of three buckets:

| Bucket | Examples | Default action |
|--------|----------|----------------|
| **Safe to share** | Tech patterns, architectural decisions, stack choices, generic debugging techniques, public URLs | Include as-is |
| **Needs confirmation** | Internal Jira/Confluence URLs, team/person names, internal project codenames, customer-facing issue descriptions, oncall runbook steps | Ask user |
| **Should not share** | Credentials or secrets (even redacted forms), customer PII, internal SLA/revenue figures, anything explicitly marked private | Remove automatically |

Present the full classification before asking anything — show one consolidated table per file, grouped by bucket:

```
## Privacy Review — {filename}

### ✅ Safe to share
- Architecture overview, .NET patterns, retry logic docs

### ⚠️ Needs your confirmation
- Line 12: Jira link → https://uipath.atlassian.net/browse/INS-4521
- Line 34: Internal codename "Project Helios"
- Line 67: Team member name "Haowen Zhang (@HaowenZhang)"

### 🚫 Will be removed automatically
- (none found)
```

Then for each file that has "Needs confirmation" items, **invoke `AskUserQuestion`** with the specific items listed in the description — one question per file, not per item:

```
question: "general/dotnet.md — how to handle the flagged items above?"
header: "Privacy: dotnet.md"
options:
  - label: "Include all flagged items"
    description: "Jira link, codename, team name — all go in as-is"
  - label: "Remove all flagged items"
    description: "Strip everything in the ⚠️ list"
  - label: "Replace flagged items with [redacted]"
    description: "Keep the structure, mask the specifics"
  - label: "Decide item by item"
    description: "I'll review each flagged item individually"
```

If "Decide item by item" is chosen, loop through each flagged item in that file with a focused AskUserQuestion showing the exact snippet.

Apply the user's decisions before writing the file in Step 5.

#### 4d — Translate to Output Language

After privacy decisions are applied, check whether the file's content language matches the `output:` language loaded in Step 0.

**How to detect**: scan the content — if a significant portion (>20% of non-code lines) is in a language other than the configured output language, the file needs translation.

**What to translate**: all prose text — headings, descriptions, notes, comments. Do NOT translate:
- Code blocks (shell commands, SQL, YAML, config snippets)
- Technical identifiers (class names, field names, env var names)
- Proper nouns that are product/service names (e.g. "Looker", "ArgoCD", "Snowflake")
- Placeholders inserted by earlier steps (`<REPO_PATH:...>`)

**Why this matters**: the exported KB will be read by teammates whose working language may differ from yours. The `output:` language is the agreed team communication language — exporting content in a personal note-taking language makes it inaccessible.

Translate inline — produce the same file structure with translated prose, preserving all headings, sections, and code blocks in their original positions.

### Step 5: Write Export Directory

Create the export directory at the chosen path. Within it, mirror the source structure:

```
{export-dir}/
├── general/
│   ├── dotnet.md
│   └── ...
├── projects/
│   └── ...
├── ops/
│   └── ...
├── skills/
│   ├── investigate-sre-jira.md
│   └── ...
└── .domain-map.md
```

Write each processed file to its corresponding location.

Then generate a `.domain-map.md` for the export:

```markdown
# Domain Map (Exported KB)
<!-- Exported by /nase:kb-teamshare on {YYYY-MM-DD} -->
<!-- Import KB files with /nase:kb-merge -->
<!-- Install skill files by copying skills/ contents to your workspace/skills/ -->

## General
- dotnet → general/dotnet.md
...

## Projects
- foo → projects/foo.md
...

## Ops
- oncall → ops/oncall.md
...

## Skills
- investigate-sre-jira → skills/investigate-sre-jira.md
...
```

Paths in the exported `.domain-map.md` use relative paths (no `workspace/kb/` or `workspace/skills/` prefix).

### Step 6: Summary

Display a summary:

```
## KB Export Complete — {YYYY-MM-DD}

**Exported to:** {export-dir}
**KB files:** {N} files across {categories}
**Skill files:** {N} skills

### Sanitization applied
- Local paths replaced: {N} occurrences
- Internal links rewritten: {N} (to relative paths)
- Internal links removed: {N} (referenced files not in export — lines deleted)
- Content reviewed with user: {N} items

### How to share
Zip the folder or share the directory directly.
Your teammate can import KB files with: /nase:kb-merge {export-dir}
Skill files: copy the skills/ directory contents to their workspace/skills/
```

Append a one-line entry to `workspace/logs/{YYYY-MM-DD}.md`:
```
- KB export ({N} KB files + {N} skills, categories: {list}) → {export-dir}
```

## Notes

- Always process files in Step 4 before writing — never copy raw files directly to the export.
- The goal is portability and privacy, not perfect formatting. If a transformation is ambiguous, ask the user — a prompt is cheaper than accidentally sharing sensitive data.
- `workspace/tasks/lessons.md` and daily logs are intentionally excluded — they're personal records, not KB.
- The exported directory is self-contained: no references to `workspace/` should remain after Step 4.
- Skill files in `workspace/skills/` are treated as plain markdown — apply the same path-stripping, privacy review, and translation pipeline as KB files.
