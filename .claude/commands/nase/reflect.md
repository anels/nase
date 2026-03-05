Run a structured post-task reflection to extract learnings and improve future performance.

**Context:** $ARGUMENTS (optional — name of the task or feature just completed)

## Steps

1. Identify the task being reflected on (from $ARGUMENTS or recent context)

2. Answer these reflection questions:
   - **What went well?** — techniques, decisions, speed
   - **What was harder than expected?** — surprises, wrong assumptions
   - **What would I do differently?** — if starting fresh
   - **What pattern or rule can I extract?** — generalizable to future tasks
   - **Any new tool/technique discovered?** — worth remembering

3. Score the task on:
   - Accuracy (did the output match requirements?) 1-5
   - Efficiency (unnecessary steps taken?) 1-5
   - Code quality (clean, simple, correct?) 1-5

4. Save key learnings to `work/tasks/lessons.md` using the format defined in `/nase:learn` (ensure file exists, create with header if missing).
   - If the extracted pattern is a reusable rule, also use `<remember>` to persist it as a behavioral directive.
   - Verify the append: read back the last entry to confirm it was written correctly.

5. If patterns suggest a process improvement, propose a concrete update to `CLAUDE.md`.

6. Output a brief reflection summary to the conversation.

## Output Format

---
**Reflection — {task name}**

Went well: ...
Harder than expected: ...
Would do differently: ...
Rule extracted: ...
New tool/technique: ...

Scores: Accuracy {N}/5 | Efficiency {N}/5 | Quality {N}/5

Saved to tasks/lessons.md: {one-line summary of what was saved}
---
