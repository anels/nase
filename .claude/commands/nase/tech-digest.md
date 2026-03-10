Fetch and summarize the latest tech news from configured sources, filtered to workspace topics. Auto-skips if today's digest already exists — safe to invoke multiple times. Use at the start of each day or whenever you want a quick check on relevant tech developments.
Deduplication is enforced in Step 0: if today's entry already exists in tech-trends.md, the skill exits immediately.

## Steps

<workflow>

0. **Deduplication check (run first — fast exit)**:
   - Search `work/kb/general/tech-trends.md` for a header matching `## Tech Digest — {today's date}` (create the file if it doesn't exist). Prefer using the Read tool over raw grep — the file may have CRLF line endings on Windows, which cause `grep` to miss matches even when the header visually appears present.
   - If the header is found, stop immediately and report: "Today's digest already recorded. Skipping."
   - Only proceed to Step 1 if today's entry is absent.

1. **Load personal config**:
   - Read `{WORKSPACE}/work/tech-digest-config.md`.
   - Extract: **Sources** list, **Filter Topics**, and **Output Sections**.
   - Use these for all subsequent steps — do not use any hardcoded sources or topics.

2. Fetch all sources (from config) in parallel using WebFetch/WebSearch.

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

5. Proceed directly to Step 6 — no user confirmation needed before writing.

6. Ensure `{WORKSPACE}/work/kb/general/tech-trends.md` exists (create with `# Tech Trends\n` header if missing; use an absolute path resolved from the workspace root, not a relative path). Then prepend the digest (newest-first ordering).

7. Lifecycle management — keep tech-trends.md focused (run after appending):
   - Count digest entries (headers matching `## Tech Digest — YYYY-MM-DD`) older than 30 days.
   - If any exist, move them to `{WORKSPACE}/work/kb/general/tech-trends-archive-{YYYY}.md` (create with `# Tech Trends Archive — {YYYY}\n` header if missing).
   - Report: "Archived N entries older than 30 days to tech-trends-archive-{YYYY}.md."

8. If any item is directly actionable (e.g., new Claude Code feature we should adopt, .NET API change), flag it explicitly.

</workflow>

## Notes
- Skip items already recorded in the last 7 days
- Focus on signal over noise — only record items with direct relevance to the filter topics in config
- If a Claude Code feature changes how I should operate, also update `CLAUDE.md` or `work/kb/general/workflow.md`
- To add/remove sources or topics, edit `work/tech-digest-config.md` directly
