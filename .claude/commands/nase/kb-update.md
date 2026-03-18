---
name: nase:kb-update
description: Persist durable knowledge about a repo's architecture, constraints, or established technical patterns to the KB. Use when the insight is about a specific codebase's design, a hard constraint, or a cross-project pattern — not a quick tip (use /learn for that).
---

Persist durable knowledge about a repo's architecture, constraints, or established technical patterns to the KB. Use this (not /learn) when the insight is about a specific codebase's design, a hard constraint, or a cross-project pattern — not a quick tip or article. For tips, URLs, and mistake patterns, use /learn instead.

The KB is the workspace's long-term memory — it outlives individual sessions. Use `/kb-update` for durable knowledge about repos, patterns, and constraints. For capturing quick tips, articles, or mistake patterns, use `/learn` instead — it handles lessons.md and may also route to KB.

**Input:** $ARGUMENTS
(If empty, reflect on recent work and identify what's worth capturing.)

## Steps

1. Identify the domain from $ARGUMENTS or recent context:

   Read `work/kb/.domain-map.md` — all known domains (general and project) are listed there.
   Each line has format: `- {domain} → {path}`. Match the domain key against entries in that file.

   **Fallback:** If no match, infer the best category:
   - Deployment/ops runbooks → `work/kb/ops/{deployment-type}.md`
   - General stack patterns → `work/kb/general/{domain}.md`
   - Project-specific → `work/kb/projects/{repo}.md`
   Create the file with a minimal header, add to `.domain-map.md`, then proceed.

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
Include links because future sessions can't search conversation history — the KB entry is the only record.

5. If the learning is cross-cutting (affects multiple kb files), update all relevant files.

6. Confirm what was added and where.
