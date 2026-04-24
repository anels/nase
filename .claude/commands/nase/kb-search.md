---
name: nase:kb-search
description: Search across all KB files for a topic, keyword, or pattern. Supports filtering by domain (general/projects/ops), tag, date, and confidence. Use when you want to find what's documented about a specific topic, verify if something is already in the KB before adding, or discover related entries. Triggers on "search KB", "find in KB", "is X in the KB?", "搜索KB", "查找".
---

Search the knowledge base for relevant entries — read-only, never writes.

**Input:** $ARGUMENTS — search query with optional filters:
- `{query}` — plain text search across all KB files
- `{query} in:general` / `in:projects` / `in:ops` — restrict to one domain
- `{query} tag:{tag}` — filter by tag (e.g. `tag:gotcha`, `tag:api-contract`)
- `{query} since:{YYYY-MM-DD}` — entries dated on or after this date
- `{query} confidence:low` or `confidence:medium` — filter by confidence level

## Steps

### Step 1: Parse query and filters

From $ARGUMENTS, extract:
- **Search terms**: the main query (everything that isn't a filter flag)
- **Domain filter** (`in:`): restrict to `workspace/kb/{domain}/`; if absent, search all
- **Tag filter** (`tag:`): only entries whose `**Tags:**` line contains this value
- **Date filter** (`since:`): only entries with `### YYYY-MM-DD` header ≥ this date
- **Confidence filter** (`confidence:`): only entries with matching `**Confidence:**` value

If $ARGUMENTS is empty, print usage and stop:
```
Usage: /nase:kb-search <query> [in:general|projects|ops] [tag:<tag>] [since:YYYY-MM-DD] [confidence:low|medium]
```

### Step 2: Determine search scope

Based on domain filter:
- No filter → search all `workspace/kb/**/*.md`, excluding `.domain-map.md`
- `in:general` → `workspace/kb/general/*.md`
- `in:projects` → `workspace/kb/projects/**/*.md`
- `in:cross-project` → `workspace/kb/cross-project/*.md`
- `in:ops` → `workspace/kb/ops/*.md`

### Step 3: Search and collect matches

Grep each in-scope file for the search terms (case-insensitive). For each match, extract the full dated entry block:
- Start: the `### YYYY-MM-DD — {topic}` line at or before the match
- End: the next `###` heading, `##` heading, or end of file

**Apply filters to each candidate entry:**
- **Tag filter**: entry must contain `**Tags:**` with the requested tag (substring match, case-insensitive)
- **Date filter**: the `### YYYY-MM-DD` date in the entry header must be ≥ `since:` date
- **Confidence filter**: entry must contain `**Confidence:** {value}` (substring match); entries without a `**Confidence:**` field are treated as `high` — include them only when filtering for `high` or when no confidence filter is set

Collect all passing entries with their source file paths.

**Header-aware relevance scoring:** When counting search term occurrences for ranking, apply a **2x weight multiplier** for matches found in `### YYYY-MM-DD — {topic}` header lines. Headers are topically focused, so a match there is a stronger relevance signal than a match in the body. Specifically:
- Count occurrences in the entry's header line → multiply by 2
- Count occurrences in the body (everything after the header) → multiply by 1
- Sum = **weighted relevance score** (used in Step 4 ranking)

**Fuzzy fallback** — if the grep returns zero matches across all in-scope files:
1. Split the search query on hyphens, spaces, underscores, and camelCase boundaries (e.g., `insightsMonitoring` → `insights`, `monitoring`; `oncall-alert-patterns` → `oncall`, `alert`, `patterns`)
2. Re-search with each individual term (still case-insensitive)
3. Only keep entries that match **≥2 terms** (if the split produced 3+ terms) or **≥1 term** (if the split produced 1-2 terms)
4. Set a flag `fuzzy_fallback = true` so Step 4 can adjust the output header

Fuzzy fallback never mixes with exact results — it activates only when exact search returns 0 results.

### Step 4: Rank and present results

For each matched entry, compute:
- **Relevance score**: weighted occurrence count from Step 3 (header at 2x, body at 1x)
- **Freshness date**: the MORE RECENT of (a) the entry's `### YYYY-MM-DD` date and (b) the file's mtime via `stat -f %m` (converted to YYYY-MM-DD). If stat fails for a file, use entry date only. Performance optimization: if `workspace/tmp/kb-health-report.md` exists and was generated today, prefer its freshness data over running stat on every file.

Sort by:
1. **Relevance** (descending): weighted occurrence count
2. **Freshness** (descending): more recent "last active" date wins ties
3. **Alphabetical** (ascending): file path as final tiebreaker

Present up to 10 results. If `fuzzy_fallback` is true, use the alternate header:

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

After presenting primary results, check each matched file for `> See also:` links. Collect the unique link targets (other KB files) that are NOT already in the primary results.

If any exist, append a "Related" section after the last result:

```
---
### Related (via cross-references)
- [{linked file topic}]({path}) — linked from {source file basename}
- ...
(showing up to 3 related files)
```

Limit to 3 related files. If multiple matched files link to the same target, show it once and note all source files. If no `> See also:` links exist in matched files, skip this section entirely.

### Step 5: Offer next actions

After displaying results (when results exist), print:

```
Actions: open a file to read in full, or run /nase:kb-update / /nase:learn to add related knowledge.
```

No interactive prompt — keep this skill fast and non-blocking.

## Notes

- This skill is **read-only** — it never writes to the KB
- **Fuzzy fallback** splits on hyphens, spaces, underscores, and camelCase boundaries. Activates only when exact search returns 0 results — never mixes with exact results
- **File mtime** uses macOS `stat -f %m` syntax. If `workspace/tmp/kb-health-report.md` exists and was generated today, use its freshness data instead of running stat on every file (performance optimization)
- For fuzzy matching, use multiple short keywords rather than long phrases
- Entries without `**Tags:**` or `**Confidence:**` fields are included in all unfiltered searches; the metadata fields are optional
- The `in:` filter is fastest — use it when you know the domain
- For full-text discovery across lessons (not just KB), search `workspace/tasks/lessons.md` directly with Grep
