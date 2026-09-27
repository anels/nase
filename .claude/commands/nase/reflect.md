---
name: nase:reflect
description: "Reflect on completed work and extract lessons. Use after a feature, bug fix, or debugging session, or for reflect, what went well, or post-mortem."
argument-hint: "[completed task] [--auto-accept]"
category: Learning & reflection
---

Fresh reflections capture more than end-of-day summaries. Also invoked by `/nase:wrap-up`.

**DO NOT enter plan mode.** Execute the steps directly: the six steps below are the plan, and `/nase:wrap-up` calls this mid-run where a second planning pass would stall the caller.

If `$ARGUMENTS` contains `--auto-accept`, used by `/nase:wrap-up`, then exactly three things change: AskUserQuestion prompts are skipped, the step 4 lessons write applies without a prompt (still through the write guard and its drift checks), and step 5's CLAUDE.md proposal is dropped. It does **not** cover step 4a's write outside `workspace/`, and it does not skip any gate.

**Context:** $ARGUMENTS (optional - name of the task or feature just completed)

## Steps

**Step 0 - Language preflight (MUST run first, non-negotiable):** follow `.claude/docs/language-config.md` → Minimum Step 0 block.

1. Identify the task being reflected on:
   a. From `$ARGUMENTS` if provided
   b. Otherwise, read `workspace/logs/{today}.md` to load today's activity as reflection context
   If both are empty, ask the user what to reflect on.

2. Answer these reflection questions:
   - **What went well?** - techniques, decisions, speed
   - **What was harder than expected?** - surprises, wrong assumptions
   - **What would I do differently?** - if starting fresh
   - **What pattern or rule can I extract?** - generalizable to future tasks
   - **Any new tool/technique discovered?** - worth remembering

   Focus on the question with the strongest signal - not every question needs a deep answer every time.

3. Score the task on:
   - Accuracy (did the output match requirements?) 1-5
   - Efficiency (unnecessary steps taken?) 1-5
   - Code quality (clean, simple, correct?) 1-5

   Try jev first, one call per dimension (`jev-judgment-points.md` points `reflect.score-accuracy`, `reflect.score-efficiency`, `reflect.score-quality`, each `--type Score` on the 1-5 scale above; state = the step 2 answers plus the task name); confidence < 0.9 or unavailable → score it yourself against the same three definitions.

   Scores are a calibration tool, not a grade. They help detect patterns over time - if efficiency is consistently low, it signals a workflow issue worth addressing.

4. Save key learnings to `workspace/tasks/lessons.md` (create with `# Lessons` header if missing), formatted per `.claude/docs/lessons-format.md`. This is a durable workspace write, so build the complete proposed file under `workspace/tmp/` and apply it through `.claude/docs/workspace-write-guard.md`:

```bash
python3 .claude/scripts/workspace-write-guard.py stage \
  --target workspace/tasks/lessons.md --content-file {proposed} --skill reflect
```

   Show the helper diff, then apply after the mtime/hash/staged-hash checks pass. Confirm the applied file ends with the new entry.

4a. A reusable rule also belongs in the auto-memory directory, which sits **outside** `workspace/` and outside this repo. Name the exact target path in chat and get explicit approval for that one file before writing it; `--auto-accept` never covers this write, because the user's standing approval is scoped to the workspace. Skipping it is fine - the lessons entry is the durable record.

5. If patterns suggest a process improvement, propose a concrete update to `CLAUDE.md` (core rules) or `.claude/docs/reference.md` (architecture notes). If `--auto-accept` is active, skip CLAUDE.md update proposals (wrap-up handles these separately).

6. Per `.claude/docs/skill-contract.md`, the lessons entry is the artifact and chat gets a pointer plus the short block below; do not restate the full step 2 answers inline. To capture reusable patterns from this reflection, suggest `/nase:extract-skills`.

## Output Format (the whole chat reply)

---
**Reflection - {task name}**

Went well: ...
Harder than expected: ...
Would do differently: ...
Rule extracted: ...
New tool/technique: ...

Scores: Accuracy {N}/5 | Efficiency {N}/5 | Quality {N}/5

Saved to tasks/lessons.md: {one-line summary of what was saved}
---
