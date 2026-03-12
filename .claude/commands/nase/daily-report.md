Generate a clear daily work report for today (or a specified date) based on AI-assisted work only. Use when asked for a daily summary, at the end of a work session, or to see what was accomplished today. Also invoked automatically by /wrap-up.
The report covers only AI-assisted work (from session logs), not all git activity — this keeps it focused on what this workspace actually contributed.

## Arguments

`$ARGUMENTS` may contain a date in `YYYY-MM-DD` format to report on a specific day.
If empty or absent, default to **today**.

## Steps

<workflow>

1. Determine the **target date**:
   - If `$ARGUMENTS` contains a `YYYY-MM-DD` value, use that.
   - Otherwise use today's date.

2. Read `work/logs/{target-date}.md`.
   - The `## Sessions` section is the **primary source** — it captures everything worked on via AI in this workspace.
   - If the file doesn't exist or has no `## Sessions` entries, report that no AI-assisted work was logged for that date.

3. Read `work/tasks/todo.md` if it exists — note any items marked complete on the target date.

4. Read `work/tasks/lessons.md` if it exists — note any lessons added on the target date.

## Output Format

---
**Daily Report — {target-date}**

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

If no `## Sessions` entries are found for the target date, say so clearly and suggest appending a session log entry.

5. **Write output to file**:
   Write the report to `work/logs/{target-date}.md` under a `## Daily Report` section.
   - If the section already exists in the file, skip (do not duplicate).
   - If the file does not exist, create it with `# Work Log — {target-date}\n` header first.
   - **Also display the full report on screen.**

</workflow>
