---
name: nase:kb-update
description: Persist durable knowledge about a repo's architecture, constraints, or established technical patterns to the KB. Use when the insight is about a specific codebase's design, a hard constraint, or a cross-project pattern — not a quick tip (use /learn for that). Also triggers on "update KB", "add to knowledge base", "document this pattern", "记录到KB".
---

The KB is the workspace's long-term memory — it outlives individual sessions.

**Decision rule:** does this insight apply specifically to one repo's internals (API contract, migration constraint, naming convention, architectural decision)? → here. Could it apply across projects or repos? → use `/learn` instead.

**Input:** $ARGUMENTS
(If empty, reflect on recent work and identify what's worth capturing.)

## Steps

1. Identify the domain from $ARGUMENTS or recent context:

   Follow `.claude/docs/repo-resolution.md` Part 2 (KB File Loading): derive the domain key, read `workspace/kb/.domain-map.md`, and locate the target KB file.

   **Fallback:** If no match, infer the best category:
   - Deployment/ops runbooks → `workspace/kb/ops/{deployment-type}.md`
   - General stack patterns → `workspace/kb/general/{domain}.md`
   - Project-specific → `workspace/kb/projects/{repo}.md`
   Create the file with a minimal header, add to `.domain-map.md`, then proceed.

2. Read the target kb file to understand current state.

2a. **Conflict check** — before writing, search for similar content:
   - Extract 2–3 key terms from what you're about to add (domain names, function names, error messages, pattern keywords)
   - Grep the entire `workspace/kb/` directory for those terms (case-insensitive)
   - **Hits in other KB files:** show the matching snippets and ask — "Similar content exists in `{file}` — duplicate, update, or distinct pattern?"
   - **Hits only in the target file:** consider updating the existing entry instead of appending a new one; surface the existing entry to the user before proceeding
   - **No hits:** proceed silently

3. Determine what to add:
   - New patterns or gotchas discovered
   - Architectural decisions made
   - Constraints clarified
   - Tools or techniques found useful

4. Append to the appropriate section using this format:
```
### YYYY-MM-DD — {topic}
**What:** {one-line summary}
**Why it matters:** {context and impact}
**Details:** {specifics, examples, code snippets if relevant}
**Links:** {preserve any original PR, Jira, Confluence, or pipeline URLs from the source material}
```
Omit the `**Links:**` line if there are no relevant links.
Include links because future sessions can't search conversation history — the KB entry is the only record.

5. If the learning is cross-cutting (affects multiple kb files), update all relevant files.

6. Confirm what was added and where.

## Error Handling

If the target KB file doesn't exist, create it with a basic header and the new content. If `.domain-map.md` has no matching domain, ask the user which KB file to use.
