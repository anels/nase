Generate a monthly work report covering the past 30 days (or the current calendar month).

## Steps

<workflow>

1. Read all daily log files for the month from `work/logs/YYYY-MM-DD.md`.
   Extract commits and activities only from the `## Sessions` sections — these represent work done in nase sessions.
   Do not run git log or pull commits from repos directly.

2. Read `work/tasks/todo.md` — full task status overview.
3. Read `work/tasks/lessons.md` — all lessons logged this month.
4. Identify major milestones, themes, and patterns across the month.
5. Read CLAUDE.md "Key Decisions & Architecture Notes" section for architectural notes.

6. KB freshness audit:
   - For each KB file in `work/kb/`, check for a `<!-- Last reviewed: YYYY-MM-DD -->` comment.
   - Any file missing this comment, or with a date older than 90 days, is stale.
   - Include a "KB Maintenance" section in the report listing stale files.

7. Lessons distillation (run if lessons.md has entries older than 90 days):
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

If no activity is found for the month, say so clearly.

8. **Write output to log**:
   Write the report to `work/logs/monthly-{YYYY-MM}.md` (e.g. `monthly-2026-03.md`).
   Overwrite if the file already exists.

</workflow>
