Generate a clear daily work report for today based on AI-assisted work only.

## Steps

<workflow>

1. Read `work/logs/{today's date}.md`.
   - The `## Sessions` section is the **primary source** — it captures everything worked on via AI in this workspace.
   - If the file doesn't exist or has no `## Sessions` entries, report that no AI-assisted work was logged today.

2. Read `work/tasks/todo.md` if it exists — note any items marked complete today.

3. Read `work/tasks/lessons.md` if it exists — note any lessons added today.

## Output Format

---
**Daily Report — {today's date}**

**Work Done (AI-assisted)**
- Summarize each session entry from `## Sessions` — one bullet per major task/topic.
  Keep it concise: what was done and outcome/decision, not a verbatim copy.
  **Preserve all original links** (PR URLs, Jira tickets, Confluence pages, pipeline links) exactly as they appear in the session log.

**Tasks Completed**
- List completed checklist items from tasks/todo.md (if any)

**In Progress**
- List any tasks still marked in-progress

**Blockers / Notes**
- Any issues, decisions made, or things to watch (drawn from session entries)
---

If no `## Sessions` entries are found for today, say so clearly and suggest appending a session log entry.

4. **Write output to log**:
   Append the report to `work/logs/{today}.md` under a `## Daily Report` section.
   - If the section already exists in the file, skip (do not duplicate).
   - If the file does not exist, create it with `# Work Log — {today}\n` header first.

</workflow>
