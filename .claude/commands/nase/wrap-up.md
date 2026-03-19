---
name: nase:wrap-up
description: Run at end of day to capture everything in one autonomous pass — reflection, lessons, KB updates, and a journal entry. Use when the user says "wrap up", "end of day", "EOD", "done for today", "closing out", or wants to summarize today's work.
---

End-of-day autonomous pass: reflection → lessons → skill extraction → KB updates → journal entry. Each step feeds the next; skipping early steps is fine — the conditional logic handles this automatically.

<investigate_before_acting>
Read workspace state (context.md, team profiles, recent logs) before generating output.
Verify file existence before reading — degrade gracefully if files are missing.
</investigate_before_acting>

**Input:** $ARGUMENTS (optional — override behavior: "force" to run all steps regardless of activity)

## Steps

<workflow>

### Step 0: Gather today's activity

1. Read `work/logs/{YYYY-MM-DD}.md` (today's date).
   - The `## Sessions` section is the **source of truth** for AI-assisted work done today.
   - If the file is missing or has no `## Sessions` entries, treat today as low-activity.
2. Read `work/tasks/todo.md` for current task status.
3. Store a summary of today's AI-assisted activity (from session entries) for use in subsequent steps.
   Do NOT scan git repos for commits — those include unrelated changes not done via AI.

Initialize a tracker: `reflect=skipped`, `learn=skipped`, `kb-update=skipped`, `daily-report=pending`.

### Step 1: Reflect (conditional)

**Condition:** today's log file has substantive `## Sessions` entries (beyond the auto-created header).
- If $ARGUMENTS contains "force", run regardless.

**If condition met:** invoke `/nase:reflect` with today's work as context. Capture its output for the journal. Set `reflect=done`.

**If condition NOT met:** print "No significant work detected today — skipping reflect." Set `reflect=skipped-no-activity`.

### Step 2: Learn (conditional)

**Condition:** reflect=done OR the user encountered mistakes/discoveries in today's log.
- If $ARGUMENTS contains "force", run regardless.

**If condition met:** invoke `/nase:learn` (empty args — auto-reflect mode). Treat all extracted insights as plain text tips; do not trigger URL-fetch or confirmation gates. Set `learn=done`.

**If condition NOT met:** skip silently. Set `learn=skipped`.

### Step 2.5: Extract Reusable Skills (conditional)

**Condition:** reflect=done OR learn=done.
- If $ARGUMENTS contains "force", run regardless.

**If condition met:** invoke `/nase:extract-skills auto`. Report any skills created. Set `extract-skills=done`.

**If condition NOT met:** skip silently. Set `extract-skills=skipped`.

### Step 3: KB Update (conditional)

**Condition:** today's session log has entries mentioning repo work.
- If $ARGUMENTS contains "force", run regardless.

**If condition met:**
1. Identify which repos were mentioned in today's session entries (from Step 0).
2. Read `work/kb/.domain-map.md` to map repos to their KB files.
3. For each touched repo/domain, review today's session entries and determine if any new knowledge was gained:
   - New patterns, architectural decisions, constraints clarified, gotchas found.
4. If meaningful updates exist, append them to the relevant KB files using the format from `/nase:kb-update`. Set `kb-update=done`.

**If condition NOT met:**
- Print: "No repos touched today — skipping KB update."
- Set `kb-update=skipped`.

### Step 4: Journal Entry (always runs)

Generate today's journal entry from the data already gathered in Step 0:

1. From today's session log (`work/logs/{YYYY-MM-DD}.md`), summarize each `## Sessions` entry — one bullet per major task/topic: what was done and the outcome/decision. **Preserve all original links** (PR URLs, Jira tickets, Confluence pages, pipeline links) exactly as they appear.
2. From `work/tasks/todo.md` (if it exists): list items marked complete today under **Tasks Completed**, and any still in-progress under **In Progress**.
3. From `work/tasks/lessons.md` (if it exists): note any lessons added today under **Blockers / Notes**.
4. If no `## Sessions` entries exist for today, note that no AI-assisted work was logged.
5. Set `daily-report=done`.

### Step 5: Write output file

1. Display all generated content inline (reflection, lessons, KB updates, daily report) so the user can review

2. Write to `work/journals/{YYYY-MM-DD}.md`. If the file already exists, overwrite it with the latest content (re-running wrap-up produces a fresh result, not a duplicate append).

```markdown
# Wrap-up — {YYYY-MM-DD}

## Reflection
{reflection output from Step 1, or "skipped — no significant activity"}

## Lessons
{lessons extracted in Step 2, or "skipped"}

## KB Updates
{list of KB files updated and what was added, or "skipped — no repo work today"}

## Daily Report
{full daily report from Step 4}

---
{status line}
```

Status line format:
```
Wrap-up complete — reflect | learn | extract-skills | kb-update | daily-report
```
Use ~~strikethrough~~ for skipped steps. Example:
- Full day: `reflect | learn | extract-skills | kb-update | daily-report`
- Light day: `~~reflect~~ | ~~learn~~ | ~~extract-skills~~ | ~~kb-update~~ | daily-report`

After writing the file, print only:
```
Wrap-up written → work/journals/{YYYY-MM-DD}.md
{status line}
```

</workflow>

## Notes

<error_handling>

- **Fully autonomous** — execute all steps without pausing. All output is written to `work/journals/{YYYY-MM-DD}.md`; if the file exists it is overwritten. Edit the file afterward as needed.
- **"force" argument** — `$ARGUMENTS` containing "force" bypasses all skip conditions and runs every step.
- **Late sessions** — if no commits since midnight but commits exist in the last 12 hours, include those (handles cross-midnight work).
- **Idempotent** — running wrap-up twice in one day is safe; reflect/learn will see previous entries and can skip or augment.
- **Order matters** — Execute steps in sequence: reflect → learn → kb-update → daily-report (each feeds the next).

</error_handling>
