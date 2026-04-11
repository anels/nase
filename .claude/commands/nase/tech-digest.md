---
name: nase:tech-digest
description: Fetch and summarize the latest tech news from configured sources, filtered to workspace topics. Auto-skips if today's entry exists. Use at the start of each day or when asked for "tech news", "what's new", or "tech digest".
---

Auto-skips if today's digest already exists (deduplication enforced in Step 0). Safe to invoke multiple times.

## Steps

<workflow>

0. **Deduplication check (run first — fast exit)**:
   - If `workspace/kb/general/tech-trends.md` does not exist, proceed to Step 1 (first-ever digest).
   - If it exists, search for a header matching `## Tech Digest — {today's date}`. Prefer using the Read tool over raw grep — the file may have CRLF line endings on Windows, which cause `grep` to miss matches even when the header visually appears present.
   - If the header is found, stop immediately and report: "Today's digest already recorded. Skipping."
   - Only proceed to Step 1 if today's entry is absent.

1. **Load personal config**:
   - Read `workspace/tech-digest-config.md`.
   - Extract: **Sources** list, **Filter Topics**, and **Output Sections**.
   - Use these for all subsequent steps — do not use any hardcoded sources or topics.

2. Fetch all sources (from config) in parallel using WebFetch/WebSearch. If WebFetch/WebSearch tools are unavailable, report "Tech digest skipped — web tools not available" and stop. If a source is unreachable, note the failure and continue with available sources. Do not fail the entire digest.

   **Content-hash cache**: before analyzing each fetched source, compute its content hash and check against `workspace/tmp/.content-hashes` (key = source URL). If the hash matches the cached entry and the cached date is today, skip re-analysis of that source — its content hasn't changed since the last fetch. Update the cache with new hashes for sources that changed or were fetched for the first time. This saves token cost on sources that publish infrequently (e.g., blog posts that update weekly). Implementation: read/write `workspace/tmp/.content-hashes` as a simple `URL HASH DATE` text file (one line per source).

3. Filter for content published in the last 7 days; discard anything unrelated to the filter topics (from config).

4. Summarize findings using the output sections from config:
```
## Tech Digest — {YYYY-MM-DD}

### {Section 1}
- ...

### {Section 2}
- ...

(one ### block per section defined in config)
```

If the user specifies a conversation language in config.md, use it for the output summary.

5. Ensure `workspace/kb/general/tech-trends.md` exists (create with `# Tech Trends\n` header if missing; use an absolute path resolved from the workspace root, not a relative path). Then prepend the digest (newest-first ordering): read the full file → insert the new digest block immediately after the `# Tech Trends` header line → write the entire file back. This keeps newest entries at the top.

6. Lifecycle management — keep tech-trends.md focused (run after appending):
   - Count digest entries (headers matching `## Tech Digest — YYYY-MM-DD`) older than 30 days.
   - If any exist, move them to `workspace/kb/general/tech-trends-archive-{YYYY}.md` (create with `# Tech Trends Archive — {YYYY}\n` header if missing).
   - Use `python3` for date parsing here. If `python3` is unavailable, skip archival and note: "Archival skipped — python3 not available. Run manually when python3 is installed."
   - Report: "Archived N entries older than 30 days to tech-trends-archive-{YYYY}.md."

7. If any item is directly actionable (e.g., new Claude Code feature we should adopt, .NET API change), flag it explicitly.

</workflow>

## Notes
- Skip items already recorded in the last 7 days
- Focus on signal over noise — only record items with direct relevance to the filter topics in config
- If a Claude Code feature changes how I should operate, also update `CLAUDE.md` or `workspace/kb/general/workflow.md`
- To add/remove sources or topics, edit `workspace/tech-digest-config.md` directly
