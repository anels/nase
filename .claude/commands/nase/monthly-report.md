Generate a monthly work report covering a natural calendar month (1st–last day). Use at end of month, when asked for a month-in-review, or to audit productivity trends. Includes a KB freshness audit to flag stale documentation.

## Arguments

`$ARGUMENTS` may contain:
- A month in `YYYY-MM` format — report on that specific month.
- The word `this` — report on the **current (incomplete) month** (1st to today).
- Empty or absent — report on **last complete month**.

## Steps

<workflow>

1. **Determine target month boundaries**:
   - Parse `$ARGUMENTS` per the rules above.
   - Calculate the **first day** and **last day** of the target month.
   - If the target month is the current month and `$ARGUMENTS` is empty/absent, use **last month** instead.
     (Use `this` explicitly to report on the current incomplete month.)
   - Display: "Reporting on: {Month Year} ({first-day} to {last-day})"

2. **Collect weekly reports first**:
   For each natural week (Monday–Sunday) that overlaps with the target month:
   - Check for `work/logs/weekly-{Monday YYYY-MM-DD}.md`.
   - If found, use it as a summarized source for that week's activity.
   - Track which days are already covered by weekly reports.

3. **Fill gaps with daily data**:
   For days NOT covered by a weekly report:
   - Check `work/logs/{YYYY-MM-DD}.md`:
     - **First**, look for a `## Daily Report` section — use as summarized source.
     - **If no daily report**, fall back to `## Sessions` section.
   - Skip days with no data.

4. Read `work/tasks/todo.md` — full task status overview.
5. Read `work/tasks/lessons.md` — all lessons logged during the target month.
6. Identify major milestones, themes, and patterns across the month.
7. Read `.claude/docs/reference.md` "Key Decisions & Architecture Notes" section for architectural notes.

8. KB freshness audit:
   - For each KB file in `work/kb/`, check for a `<!-- Last reviewed: YYYY-MM-DD -->` comment.
   - Any file missing this comment, or with a date older than 90 days, is stale.
   - Include a "KB Maintenance" section in the report listing stale files.

9. Lessons distillation (run if lessons.md has entries older than 90 days):
   - Count entries older than 90 days.
   - Prompt: "Consider running /learn to promote stable patterns into CLAUDE.md rules and archive raw entries to keep lessons.md focused."

## Output Format

---
**Monthly Report — {Month Year}**

**Executive Summary**
- 2-3 sentences: what was built/fixed/improved this month

**Milestones & Highlights**
- Major features shipped
- Important bugs fixed
- Key refactors or improvements

**Work Activity**
- Total sessions: N
- Active days: N
- Busiest week: ...

**Task Overview**
- Completed: N tasks
- In Progress: N tasks
- Backlog: N tasks

**Key Decisions Made**
- Architectural or design decisions recorded this month

**Lessons Learned**
- Top insights from tasks/lessons.md

**Areas of Improvement**
- Patterns in bugs or rework that suggest process improvements

**KB Maintenance**
- Stale files (90+ days since review): [list or "none"]
- Action: add `<!-- Last reviewed: {date} -->` to each file after reviewing

**Next Month Goals**
- 3-5 suggested priorities based on current state
---

**Link preservation:** Keep all original URLs (PR links, Jira tickets, Confluence pages, pipeline links, release IDs) exactly as they appear in the session logs. Do not paraphrase or drop them.

If no activity is found for the target month, say so clearly.

10. **Write output to file**:
    Write the report to `work/logs/monthly-{YYYY-MM}.md` (e.g. `monthly-2026-02.md`).
    Overwrite if the file already exists.
    Update `work/logs/.report-status` — set or replace the line `monthly-report={YYYY-MM}`.
    Create the status file if it doesn't exist.
    **Also display the full report on screen.**

</workflow>
