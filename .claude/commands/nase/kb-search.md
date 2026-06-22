---
name: nase:kb-search
description: "Search all KB files for a topic, keyword, or pattern. Use to find documented context, verify whether something is already in the KB, or discover related entries. Triggers: search KB, find in KB, or is X in the KB. Read-only; use /nase:kb-update or /nase:learn to add entries."
pattern: utility
category: Knowledge base
---

Search the knowledge base for relevant entries — read-only, never writes.

**Input:** $ARGUMENTS — search query with optional filters:
- `{query}` — plain text search across all KB files
- `{query} in:general` / `in:projects` / `in:ops` / `in:cross-project` — restrict to one domain
- `{query} tag:{tag}` — filter by tag (e.g. `tag:gotcha`, `tag:api-contract`)
- `{query} since:{YYYY-MM-DD}` — entries dated on or after this date
- `{query} confidence:low` / `confidence:medium` / `confidence:high` — filter by confidence level
- `mentions:{path}` — entries that literally reference this file or folder path (e.g. `mentions:src/auth/handler.ts`, `mentions:src/checkout/`). Works without a query — answers "which KB entries reference this code path before I edit it?"
- `--full` — show complete matching entries instead of capped previews
- `--max-entry-lines N` — preview up to N lines per entry (default 24)

## Steps

### Step 0: Language preflight (MUST run first, non-negotiable)

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. KB content displayed verbatim from KB files keeps its original language.

### Step 1: Parse query and filters

From $ARGUMENTS, extract:
- **Search terms**: the main query (everything that isn't a filter flag)
- **Domain filter** (`in:`): restrict to `workspace/kb/{domain}/`; if absent, search all
- **Tag filter** (`tag:`): only entries whose `**Tags:**` line contains this value
- **Date filter** (`since:`): only entries with `### YYYY-MM-DD` header ≥ this date
- **Confidence filter** (`confidence:`): only entries with matching `**Confidence:**` value

If $ARGUMENTS is empty, print usage and stop:
```
Usage: /nase:kb-search <query> [in:general|projects|ops|cross-project] [tag:<tag>] [since:YYYY-MM-DD] [confidence:low|medium|high] [mentions:<path>] [--full] [--max-entry-lines N]
```

If $ARGUMENTS contains only `mentions:<path>` (no other query terms), the path itself is used as the search query — typical "before-touch" workflow before editing the code path.

### Steps 2–3: Search using script

Run the search script, which handles scope, filtering, relevance weighting, fuzzy fallback, and ranking:

```bash
bash .claude/scripts/kb-search.sh "<query>" [in:<domain>] [tag:<tag>] [since:<YYYY-MM-DD>] [confidence:<level>] [mentions:<path>] [--full] [--max-entry-lines N]
```

Pass through the filters parsed in Step 1. The script:
- Restricts scope by domain (`in:` flag → `workspace/kb/{domain}/`)
- Applies tag / date / confidence / mentions filters per entry
- Scores: header matches 2×, body matches 1×; sorts by relevance desc, freshness desc
- Fuzzy fallback: activates automatically when exact search returns 0 results
- Prints up to 10 results with file paths and capped entry previews, or a no-results message with suggestions
- Preserves full-entry behavior with `--full`

Capture stdout. If the script exits 2 (no results), proceed to Step 4 with empty results.

### Step 4: Present results

The script already ranks (relevance desc, freshness desc, file asc) and emits each match. Default output is capped per entry; keep the cap marker if present so the user knows to rerun with `--full` for complete text. Re-format each result for display:

Present up to 10 results. If the script's header line says "partial match(es)", use the alternate header:

```
## KB Search — "{original query}" · {N} partial match(es)
⚠️ No exact match found. Showing partial matches for: {split terms joined by ", "}
```

Otherwise use the standard header:

```
## KB Search — "{query}" · {N} result(s) [{filters applied}]

### 1. {topic} — {date}
**File:** `{relative path from workspace/}`
**Tags:** {tags if present} | **Confidence:** {confidence if present, else "high (default)"}
> {**What:** line}
> {first line of **Details:** if present}

---

### 2. ...
```

If no results found:
```
No KB entries found for "{query}" [{filters if any}].

Suggestions:
- Try broader terms: {suggest 1-2 alternate keywords from the query}
- Check related domains: {suggest which domain might have relevant content based on the topic}
- Add to KB: run `/nase:learn {query}` to research and document this topic
```

### Step 4b: Related entries via cross-references

After presenting primary results, collect related KB files from **two sources** for each matched file:

1. **Frontmatter `related:` list** — read the YAML block at the top of the file; extract domain keys from `related:`; resolve each to a file path via `workspace/kb/.domain-map.md`
2. **Body `> See also:` links** — scan the file body for `> See also:` lines; extract linked paths

Merge both source lists, deduplicate, and remove any files already in the primary results.

If any remain, append a "Related" section after the last result:

```
---
### Related (via cross-references)
- [{linked file topic}]({path}) — linked from {source file basename}
- ...
(showing up to 3 related files)
```

Limit to 3 related files. If multiple matched files point to the same target, show it once and note all source files. Skip this section entirely if no related files are found.

### Step 5: Offer next actions

After displaying results (when results exist), print:

```
Actions: open a file to read in full, or run /nase:kb-update / /nase:learn to add related knowledge.
```

No interactive prompt — keep this skill fast and non-blocking.

## Notes

- This skill is **read-only** — it never writes to the KB
- **Fuzzy fallback** splits on hyphens, spaces, underscores. Activates only when exact search returns 0 results — never mixes with exact results
- For fuzzy matching, use multiple short keywords rather than long phrases
- Entries without `**Tags:**` or `**Confidence:**` fields are included in all unfiltered searches; the metadata fields are optional
- The `in:` filter is fastest — use it when you know the domain
- For full-text discovery across lessons (not just KB), search `workspace/tasks/lessons.md` directly with Grep
