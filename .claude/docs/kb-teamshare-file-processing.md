# KB Teamshare — File Processing Pipeline (Step 4)

## Contents

- 4a: Strip Local Absolute Paths
- 4b: Fix Internal KB Links
- 4c: Privacy Classification
- Privacy Review: {filename}
- 4d: Translate to Output Language

Apply these four transformations in order to every selected file.

---

## 4a — Strip Local Absolute Paths

Replace any absolute path patterns that are machine-specific.

**Note:** These are conceptual regex patterns applied by Claude during content processing — not raw sed/grep commands. Claude reads the file content, identifies matches using these patterns, and rewrites them. Do not pass these directly to `sed` or `grep` (BSD sed on macOS doesn't support `\s` or capture groups in the same way).

| Pattern | Replacement |
|---------|------------|
| `/Users/{username}/repos/{RepoName}` | `<REPO_PATH:{RepoName}>` — e.g. `/Users/alice/repos/example-repo` → `<REPO_PATH:example-repo>` |
| `/Users/{username}/` | `<HOME>/` |
| `/home/{username}/` | `<HOME>/` |

Apply by scanning each line for these path prefixes and substituting. If a path appears in a context that isn't a local machine path (e.g., a URL or a quoted string with a different meaning), use your judgment — when unsure, **invoke `AskUserQuestion`** to confirm with the user before removing it.

---

## 4b — Fix Internal KB Links

Internal KB cross-references use the form `workspace/kb/category/file.md`. These break when the files are exported to a different directory. Fix them as follows:

After Step 3.5 cascade, almost every reference should resolve to a file in the export. The remaining cases are edge cases (cycles broken by the depth cap, or files the user chose to exclude in cascade).

- **If the linked file IS in the export set:** rewrite the link to a relative path within the export directory.
  - `workspace/kb/general/dotnet.md` → `general/dotnet.md`
  - `workspace/kb/projects/foo.md` → `projects/foo.md`
  - `workspace/skills/investigate-sre-jira.md` → `skills/investigate-sre-jira.md`
  - `workspace/skills/docs/sre-cli-tools.md` → `skills/docs/sre-cli-tools.md`
  - Markdown link format: `[text](workspace/kb/X/Y.md)` → `[text](X/Y.md)`
  - Plain text references: replace the path string directly
- **If the linked file is NOT in the export set:** remove the entire line containing the link. A dangling reference with no destination is worse than nothing — it just confuses the reader.

---

## 4c — Privacy Classification

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
- Line 12: Jira link → https://your-org.atlassian.net/browse/PROJ-4521
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

---

## 4d — Translate to Output Language

After privacy decisions are applied, check whether the file's content language matches the `output:` language loaded in Step 0.

**How to detect**: scan the content — if a significant portion (>20% of non-code lines) is in a language other than the configured output language, the file needs translation.

**What to translate**: all prose text — headings, descriptions, notes, comments. Do NOT translate:
- Code blocks (shell commands, SQL, YAML, config snippets)
- Technical identifiers (class names, field names, env var names)
- Proper nouns that are product/service names (e.g. "Looker", "ArgoCD", "Snowflake")
- Placeholders inserted by earlier steps (`<REPO_PATH:...>`)

**Why this matters**: the exported KB will be read by teammates whose working language may differ from yours. The `output:` language is the agreed team communication language — exporting content in a personal note-taking language makes it inaccessible.

Translate inline — produce the same file structure with translated prose, preserving all headings, sections, and code blocks in their original positions.
