Generate a weekly work report covering a natural week (Monday–Sunday). Use for end-of-week review, standup preparation, or when asked "what did I accomplish this week?". Reads session logs and daily reports — not raw git history — so it reflects AI-assisted work only.

## Arguments

`$ARGUMENTS` may contain:
- A date in `YYYY-MM-DD` format — report on the **natural week containing that date** (Monday–Sunday).
- The word `this` — report on the **current (incomplete) week** (Monday of this week to today).
- Empty or absent — report on **last complete week** (previous Monday–Sunday).

## IMPORTANT

**You MUST display the full report in the chat AND write it to file. Both are required — never skip the chat output.**

## Steps

<workflow>

1. **Determine target week boundaries**:
   - Parse `$ARGUMENTS` per the rules above.
   - Calculate the **Monday** and **Sunday** of the target week.
   - If the target week is the current week and `$ARGUMENTS` is empty/absent, use **last week** instead.
     (Use `this` explicitly to report on the current incomplete week.)
   - Display: "Reporting on week: {Monday} to {Sunday}"

2. **Collect daily data** (Monday through Sunday, or through today if current week):
   For each day in the range:
   - **First**, check for a daily report at `work/reports/daily/{YYYY-MM-DD}.md` — if it exists, use that as the summarized source for that day.
   - **If no daily report file**, fall back to reading `work/logs/{YYYY-MM-DD}.md`:
     - Look for a `## Daily Report` section first.
     - If absent, fall back to the `## Sessions` section directly.
   - Skip days with no data.

3. Read `work/tasks/todo.md` — summarize completed vs pending items.
4. Read `work/tasks/lessons.md` — highlight key lessons learned during the target week.
5. Identify recurring themes across the session work (e.g., bug fixes, features, refactors).

## Output Format

---
**Weekly Report — {Monday YYYY-MM-DD} to {Sunday YYYY-MM-DD}**

**Summary**
- One sentence overview of what this week focused on

**Work by Day**
- {YYYY-MM-DD (day-of-week)} [{repo/topic}] {what was done}
  (Group by day; skip days with no activity)

**Tasks**
- Completed: ...
- In Progress: ...
- Pending: ...

**Key Decisions & Learnings**
- Notable architectural or workflow decisions made
- Lessons from tasks/lessons.md added this week

**Next Week Focus**
- Suggest 2-3 priorities based on pending tasks and blockers
---

**Link preservation:** Keep all original URLs (PR links, Jira tickets, Confluence pages, pipeline links, release IDs) exactly as they appear in the session logs. Do not paraphrase or drop them.

If no activity is found for the target week, say so and suggest next steps.

6. **Write output to file**:
   - Ensure directory exists: `work/reports/weekly/`
   - Write the report to `work/reports/weekly/{Monday YYYY-MM-DD}.md` (e.g. `2026-03-02.md`).
   - Overwrite if the file already exists.
   - Update `work/reports/.report-status` — set or replace the line `weekly-report={Monday date}`.
     Create the status file if it doesn't exist.
   - **Also display the full report on screen.**

</workflow>
