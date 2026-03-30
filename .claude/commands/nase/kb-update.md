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

2. Read the target KB file to understand current state.

2a. **Conflict check** — before writing, search for similar content:
   - Extract 2–3 key terms from what you're about to add (domain names, function names, error messages, pattern keywords)
   - Grep the entire `workspace/kb/` directory for those terms (case-insensitive, excluding `.domain-map.md` to avoid false positives)
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

5. If the learning is cross-cutting (affects multiple KB files), update all relevant files.

6. **Size check — split if needed:**

   Count the lines in the target file after writing.

   If the file exceeds **400 lines**, evaluate whether a split makes sense:
   - Identify top-level `##` sections and their line counts
   - A split is worthwhile when: there are 2+ sections each >150 lines AND they represent distinct sub-domains that would logically be consulted independently (e.g., "alert patterns" vs "runbook procedures" vs "escalation contacts")
   - If no clean semantic boundary exists, skip splitting

   **How to split:**
   - Prefer a **subfolder** when the domain will likely grow (e.g., `ops/oncall/` containing `alerts.md`, `procedures.md`, `escalation.md`)
   - Prefer a **flat sibling file** for a one-off split (e.g., `oncall.md` + `oncall-runbooks.md`)
   - Name files after the content, not the structure: `alerts.md` not `part1.md`

   **Split procedure:**
   1. Create the new file(s) with a header referencing the parent domain
   2. Move the relevant sections; keep a short index with `See also:` links in each file
   3. If using a subfolder: rename the original to `{name}/index.md` or keep it as a routing stub
   4. Update `workspace/kb/.domain-map.md` with the new file paths — use the format `- {domain-key} -> {relative-path}` matching existing entries, under the same category section
   5. Update any existing `See also:` references in other KB files that pointed to the original

7. **Internal links — wire up cross-references:**

   After writing (and after any split), check whether the new content references concepts covered in *other* KB files:
   - Grep `workspace/kb/` for the key terms from the new entry
   - If a hit exists in another file and the connection is genuinely useful (not incidental), add a `> See also: [{description}]({relative-path})` line near the relevant section — both in the file you just wrote *and* in the other file
   - Only add links that would actually help a reader navigate — don't link everything to everything

   Common link-worthy connections:
   - An alert in `oncall.md` referencing a runbook procedure now in `oncall-runbooks.md`
   - A project KB noting a Snowflake pattern that's detailed in `general/snowflake.md`
   - A deployment note in one project KB referencing a shared ops pattern

8. Confirm what was added, where, whether the file was split, and what links were added.

## Error Handling

If the target KB file doesn't exist, create it with a basic header and the new content. If `.domain-map.md` has no matching domain, ask the user which KB file to use.
