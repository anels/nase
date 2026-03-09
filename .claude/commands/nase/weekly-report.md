Generate a weekly work report covering the past 7 days (Monday to today).
Aggregates session logs (not raw git history) to show what was accomplished through AI-assisted work this week. Useful for standups and self-review.

## Steps

<workflow>

1. Read the daily log files for this week from `work/logs/YYYY-MM-DD.md` (Monday to today).
   Extract commits and activities only from the `## Sessions` sections — these represent work done in nase sessions.
   Do not run git log or pull commits from repos directly.

2. Read `work/tasks/todo.md` — summarize completed vs pending items.
3. Read `work/tasks/lessons.md` — highlight key lessons learned this week.
4. Identify recurring themes across the session work (e.g., bug fixes, features, refactors).
5. Record that the weekly report was generated today:
   Update `work/logs/.report-status` — set or replace the line `weekly-report=YYYY-MM-DD` (today's date).
   Create the file if it doesn't exist.

## Output Format

---
**Weekly Report — Week of {Monday's date} to {today's date}**

**Summary**
- One sentence overview of what this week focused on

**Work by Day**
- {YYYY-MM-DD} [{repo/topic}] {what was done}

**Tasks**
- Completed: ...
- In Progress: ...
- Pending: ...

**Key Decisions & Learnings**
- Notable architectural or workflow decisions made
- Lessons from tasks/lessons.md added this week

**Files Most Changed**
- Top files by change frequency

**Next Week Focus**
- Suggest 2-3 priorities based on pending tasks and blockers
---

**Link preservation:** Keep all original URLs (PR links, Jira tickets, Confluence pages, pipeline links, release IDs) exactly as they appear in the session logs. Do not paraphrase or drop them.

If no activity is found, say so and suggest next steps.

6. **Write output to log**:
   Write the report to `work/logs/weekly-{Monday's date}.md` (e.g. `weekly-2026-03-02.md`).
   Overwrite if the file already exists.

</workflow>
