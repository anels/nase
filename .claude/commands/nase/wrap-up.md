Consolidate end-of-day routine: reflect, learn, kb-update, and daily-report in one command with smart auto-skip.

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

**Condition:** today's commits exist OR today's log file has substantive entries (beyond the auto-created header).
- If $ARGUMENTS contains "force", run regardless.

**If condition met:**
1. Run the reflection process (same as `/nase:reflect`):
   - What went well, what was harder than expected, what would I do differently, patterns extracted, new tools/techniques.
   - Score: Accuracy, Efficiency, Quality (1-5 each).
2. Save the reflection output to `work/tasks/lessons.md`. Set `reflect=done`.

**If condition NOT met:**
- Print: "No significant work detected today — skipping reflect."
- Set `reflect=skipped-no-activity`.

### Step 2: Learn (conditional)

**Condition:** Step 1 produced insights (reflect=done) OR the user encountered mistakes/discoveries in today's log.
- If $ARGUMENTS contains "force", run regardless.

**If condition met:**
1. Auto-extract learnings from the reflect output and today's activity.
2. Categorize each learning (workflow / code / debugging / architecture / project).
3. Append to `work/tasks/lessons.md`. Set `learn=done`.
4. If a learning is an important reusable rule, also use `<remember>` to persist it.

**If condition NOT met:**
- Skip silently (no message needed). Set `learn=skipped`.

### Step 2.5: Extract Reusable Skills (conditional)

**Condition:** reflect=done OR learn=done (i.e., today had substantive work worth capturing as skills).
- If $ARGUMENTS contains "force", run regardless.

**If condition met:**
1. Run `/nase:extract-skills auto` — it analyzes the current session and extracts reusable patterns as new pattern files under `work/skills/`. The `auto` flag bypasses the interactive confirmation gate.
2. Report any skills created (name + one-line description). Set `learner=done`.

**If condition NOT met:**
- Skip silently. Set `learner=skipped`.

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

### Step 4: Daily Report (always runs)

1. Run the daily report process (same as `/nase:daily-report`):
   - Reads today's session log, tasks completed/in-progress from todo.md, lessons added today.
2. Set `daily-report=done`.

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
Wrap-up complete — reflect | learn | learner | kb-update | daily-report
```
Use ~~strikethrough~~ for skipped steps. Example:
- Full day: `reflect | learn | learner | kb-update | daily-report`
- Light day: `~~reflect~~ | ~~learn~~ | ~~learner~~ | ~~kb-update~~ | daily-report`

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
