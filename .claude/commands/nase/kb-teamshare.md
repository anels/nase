---
name: nase:kb-teamshare
description: Export and share your knowledge base with teammates — sanitizes personal info, fixes internal links to be portable, and lets you pick exactly which KB files to include. Use when asked "share my KB", "export KB", "export knowledge base", "share knowledge", "给同事分享KB", "导出知识库", or when you want to package KB files for others to import with /nase:kb-merge.
---

Export selected KB files as a portable, sanitized directory ready to share with teammates.

**Input:** $ARGUMENTS
(Optional: target directory path. If not provided, will ask interactively.)

## Setup

Use `ToolSearch` to fetch `AskUserQuestion` before starting — it's a deferred tool used throughout Steps 1–4 for interactive prompts. Fetch it once here so it's available when needed.

## Step 0: Load Language Config

Read `workspace/config.md` and extract:
- `conversation:` → language for all AskUserQuestion prompts and responses to the user in this session
- `output:` → language for any text written into the exported files themselves (e.g., `.domain-map.md` comments, redaction placeholders)

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
question: "Which KB categories do you want to include?"
header: "KB scope"
multiSelect: true
options:
  - label: "general/ — tech knowledge"
    description: "dotnet, workflow, llm, debugging, etc. — usually the safest to share"
  - label: "projects/ — project-specific KB"
    description: "Repo architecture, constraints, patterns. Contains more personal details — will be sanitized."
  - label: "ops/ — operations knowledge"
    description: "Oncall, customer support, runbooks. May contain internal company info — will be sanitized."
```

### Step 3: Select Specific Files

Read `.domain-map.md` to get the list of files in each selected category. First **invoke `AskUserQuestion`**:

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

**projects/** (13 files)
8. insights-dashboarding.md — REST API + NuGet library
9. llm-observability.md — LLM observability platform
...
```

Then invoke `AskUserQuestion`:

```
question: "Type the numbers of the files to include (e.g. '1,3,8'). Use 'Other' to enter your selection."
header: "Pick files"
options:
  - label: "All from general/ only"
    description: "Include all general/ files, skip projects/ and ops/"
  - label: "All from projects/ only"
    description: "Include all projects/ files, skip others"
  - label: "All from ops/ only"
    description: "Include all ops/ files, skip others"
  - label: "Custom selection"
    description: "Use 'Other' to type the file numbers you want"
```

Parse the user's answer (whether a preset option or custom "Other" text with numbers) into the final file list.

Record the final list of files to export (absolute paths under `workspace/kb/`).

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
- **If the linked file is NOT in the export set:** remove the link and replace with a plain text note in brackets: `[not included in this export]`

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
- Placeholders inserted by earlier steps (`<REPO_PATH:...>`, `[internal link removed]`, `[customer]`)

**Why this matters**: the exported KB will be read by teammates whose working language may differ from yours. The `output:` language is the agreed team communication language — exporting content in a personal note-taking language makes it inaccessible.

Translate inline — produce the same file structure with translated prose, preserving all headings, sections, and code blocks in their original positions.

### Step 5: Write Export Directory

Create the export directory at the chosen path. Within it, mirror the KB structure:

```
{export-dir}/
├── general/
│   ├── dotnet.md
│   └── ...
├── projects/
│   └── ...
├── ops/
│   └── ...
└── .domain-map.md
```

Write each processed file to its corresponding location. Then generate a `.domain-map.md` for the export:

```markdown
# Domain Map (Exported KB)
<!-- Exported by /nase:kb-teamshare on {YYYY-MM-DD} -->
<!-- Import with /nase:kb-merge -->

## General
- dotnet → general/dotnet.md
...

## Projects
- foo → projects/foo.md
...

## Ops
- oncall → ops/oncall.md
...
```

Paths in the exported `.domain-map.md` use relative paths (no `workspace/kb/` prefix).

### Step 6: Summary

Display a summary:

```
## KB Export Complete — {YYYY-MM-DD}

**Exported to:** {export-dir}
**Files:** {N} files across {categories}

### Sanitization applied
- Local paths replaced: {N} occurrences
- Internal links rewritten: {N} (to relative paths)
- Internal links removed: {N} (linked files not in export)
- Content reviewed with user: {N} items

### How to share
Zip the folder or share the directory directly.
Your teammate can import it with: /nase:kb-merge {export-dir}
```

Append a one-line entry to `workspace/logs/{YYYY-MM-DD}.md`:
```
- KB export ({N} files, categories: {list}) → {export-dir}
```

## Notes

- Always process files in Step 4 before writing — never copy raw files directly to the export.
- The goal is portability and privacy, not perfect formatting. If a transformation is ambiguous, ask the user — a prompt is cheaper than accidentally sharing sensitive data.
- `workspace/tasks/lessons.md` and daily logs are intentionally excluded — they're personal records, not KB.
- The exported directory is self-contained: no references to `workspace/` should remain after Step 4.
