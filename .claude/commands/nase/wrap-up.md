---
name: nase:wrap-up
description: Run at end of day to capture everything in one autonomous pass — reflection, lessons, KB updates, and a journal entry. Use when the user says "wrap up", "end of day", "EOD", "done for today", "closing out", or wants to summarize today's work.
---

End-of-day autonomous pass: reflection → lessons → skill extraction → KB updates → journal entry. Each step feeds the next; skipping early steps is fine — the conditional logic handles this automatically.

**DO NOT enter plan mode.** This skill is fully autonomous — execute all steps directly without requesting user approval. Plan mode breaks the automated flow.

<investigate_before_acting>
Follow the shared data-gathering algorithm (`workspace-data-gathering.md`) — read today's log/journal, tasks, and lessons. Do NOT read context.md or team profiles; wrap-up does not use them.
Verify file existence before reading — degrade gracefully if files are missing.
</investigate_before_acting>

**Input:** $ARGUMENTS (optional — override behavior: "force" to run all steps regardless of activity)

## Steps

<workflow>

### Step 0: Gather today's activity

Follow the shared data-gathering algorithm in `.claude/docs/workspace-data-gathering.md` with `SCOPE="day"` (today only). This loads today's log/journal, tasks, lessons, and extracts structured data.

Key points from the shared algorithm:
- The `## Sessions` section in `workspace/logs/{YYYY-MM-DD}.md` is the **source of truth** for AI-assisted work.
- If the file is missing or has no `## Sessions` entries, treat today as low-activity.
- Do NOT scan git repos for commits — those include unrelated changes not done via AI.

Initialize a tracker: `reflect=skipped`, `learn=skipped`, `extract-skills=skipped`, `kb-update=skipped`, `daily-report=pending`.

### Step 1: Reflect (conditional)

**Condition:** today's log file has substantive `## Sessions` entries (beyond the auto-created header).
- If $ARGUMENTS contains "force", run regardless.

**If condition met:** invoke `/nase:reflect --auto-accept` with today's work as context (note: `reflect.md` recognizes `--auto-accept` and skips all interactive prompts). Capture its output for the journal. Set `reflect=done`.

**If condition NOT met:** print "No significant work detected today — skipping reflect." Set `reflect=skipped-no-activity`.

### Step 2: Learn (conditional)

**Condition:** reflect=done OR the user encountered mistakes/discoveries in today's log.
- If $ARGUMENTS contains "force", run regardless.

**If condition met:** invoke `/nase:learn --auto-accept` (empty args — auto-reflect mode). Set `learn=done`.

**If condition NOT met:** skip silently. Set `learn=skipped`.

### Step 3: Extract Reusable Skills (conditional)

**Condition:** reflect=done OR learn=done.
- If $ARGUMENTS contains "force", run regardless.

**If condition met:** invoke `/nase:extract-skills --auto-accept`. Report any skills created. Set `extract-skills=done`.

**If condition NOT met:** skip silently. Set `extract-skills=skipped`.

### Step 4: KB Update (conditional)

**Condition:** today's session log has entries mentioning repo work.
- If $ARGUMENTS contains "force", run regardless.

**If condition met:**
1. Identify which repos were mentioned in today's session entries (from Step 0).
2. For each touched repo/domain, review today's session entries and determine if any new knowledge was gained:
   - New patterns, architectural decisions, constraints clarified, gotchas found.
3. If meaningful updates exist, write directly to the relevant KB file(s):
   - **Conflict check (lightweight):** Before writing, extract 1–2 key terms from the planned entry and Grep the *target KB file only* (not the full KB directory). If a matching entry is found, compare: if it's a true duplicate, skip the write; if it's genuinely new or complementary information, proceed.
   - Read the target KB file, locate the right section, append the new entry.
   - Use the standard `### YYYY-MM-DD — {topic}` format (same as `/nase:kb-update`).
   - Update the `<!-- Last updated: YYYY-MM-DD -->` timestamp.
   - **Note:** This is a lightweight direct write — it skips full cross-reference wiring. For complex multi-domain updates with potential conflicts, invoke `/nase:kb-update` directly instead.
   - Set `kb-update=done`.

**If condition NOT met:**
- Print: "No repos touched today — skipping KB update."
- Set `kb-update=skipped`.

### Step 4b: Estimate Calibration (conditional)

**Condition:** today's log contains any `ETA estimate:` lines (written by `/nase:estimate-eta`).

**If condition met:**
1. Find all lines matching `ETA estimate: {task} — {estimate}` in today's log
2. For each estimate, check today's session entries and completed tasks for evidence of actual completion time
3. If the task was completed today, estimate actual elapsed time from session entry timestamps or narrative
4. Compare realistic estimate vs actual:
   - Divergence ≥ 30%: append a calibration note to `workspace/tasks/lessons.md`:
     ```
     ## calibration -- {YYYY-MM-DD} -- ETA: {task name}
     **Estimated:** {realistic estimate} | **Actual:** ~{actual} | **Drift:** {over/under} by ~{%}
     **Pattern:** {one-line observation — e.g. "underestimated integration work", "unknown dependency added 2h"}
     ```
   - Divergence < 30%: no action needed — estimate was accurate
5. Over multiple entries, these notes let `/nase:estimate-eta` pattern-match against historical accuracy for the same types of tasks

**If condition NOT met:** skip silently.

### Step 4c: Jira Status Sync (conditional)

**Condition:** tasks marked complete today or today's session log entries reference Jira ticket keys (pattern: `[A-Z]+-\d+`), AND `workspace/config.md` has a `## Jira > cloudId` entry.

**If condition met:**
1. Extract all ticket keys from `[x]` items in `workspace/tasks/todo.md` (if any contain keys) AND from today's session log entries (`workspace/logs/{YYYY-MM-DD}.md` — these are the primary source since the todo format doesn't always embed Jira keys)
2. Read `cloudId` from `workspace/config.md`
3. For each key, fetch current status via Atlassian MCP `getJiraIssue`
4. Build a transition table — tickets still "In Progress" or "Open":

   | Key | Summary | Current Status |
   |-----|---------|----------------|
   | SRE-XXXXX | ... | In Progress |

5. Ask the user: "Transition these to Done? (all / pick numbers / skip)" — then call `transitionJiraIssue` for confirmed ones
6. If Atlassian MCP unavailable or no matching tickets: skip silently

### Step 5: Journal Entry (always runs)

Generate today's journal entry from the data already gathered in Step 0:

1. From today's session log (`workspace/logs/{YYYY-MM-DD}.md`), summarize each `## Sessions` entry — one bullet per major task/topic: what was done and the outcome/decision. **Preserve all original links** (PR URLs, Jira tickets, Confluence pages, pipeline links) exactly as they appear.
2. From `workspace/tasks/todo.md` (if it exists): list items marked complete today under **Tasks Completed**, and any still in-progress under **In Progress**.
3. From `workspace/tasks/lessons.md` (if it exists): note any lessons added today under **Blockers / Notes**.
4. If no `## Sessions` entries exist for today, note that no AI-assisted work was logged.
5. Set `daily-report=done`.

### Step 6: Write output file

1. Display all generated content inline (reflection, lessons, KB updates, daily report) so the user can review

2. Write to `workspace/journals/{YYYY-MM-DD}.md`. If the file already exists, overwrite it with the latest content (re-running wrap-up produces a fresh result, not a duplicate append).

```markdown
# Wrap-up — {YYYY-MM-DD}

## Reflection
{reflection output from Step 1, or "skipped — no significant activity"}

## Lessons
{lessons extracted in Step 2, or "skipped"}

## KB Updates
{list of KB files updated and what was added, or "skipped — no repo work today"}

## Daily Report
{full daily report from Step 5}

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
Wrap-up written → workspace/journals/{YYYY-MM-DD}.md
{status line}
```

Follow .claude/docs/language-config.md for conversation vs output language.

</workflow>

## Notes

<error_handling>

- **Fully autonomous** — execute all steps without pausing. All output is written to `workspace/journals/{YYYY-MM-DD}.md`; if the file exists it is overwritten. Edit the file afterward as needed.
- **"force" argument** — `$ARGUMENTS` containing "force" bypasses all skip conditions and runs every step.
- **Late sessions** — if no session log entries since midnight but entries exist in the last 12 hours, include those (handles cross-midnight work).
- **Idempotent** — running wrap-up twice in one day is safe; reflect/learn will see previous entries and can skip or augment.
- **Order matters** — Execute steps in sequence: reflect → learn → extract-skills → kb-update → daily-report (each feeds the next).
- **Bookend** — This skill closes the day. Start the next day with `/nase:today` for a focused kickoff.

</error_handling>
