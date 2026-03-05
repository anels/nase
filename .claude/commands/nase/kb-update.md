Update the knowledge base with new learnings from this session or task.

**Input:** $ARGUMENTS
(If empty, reflect on recent work and identify what's worth capturing.)

## Steps

1. Identify the domain from $ARGUMENTS or recent context:

   Read `work/kb/.domain-map.md` — all known domains (general and project) are listed there.
   Each line has format: `- {domain} → {path}`. Match the domain key against entries in that file.

   **Fallback:** If no match, list all known domains from `.domain-map.md` and ask the user to clarify.

2. Read the target kb file to understand current state.

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

5. If the learning is cross-cutting (affects multiple kb files), update all relevant files.

6. Confirm what was added and where.
