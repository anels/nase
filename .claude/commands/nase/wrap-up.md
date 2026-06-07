---
name: nase:wrap-up
description: Run at end of day to capture reflection, lessons, KB updates, and a journal entry in one pass. Use when the user says "wrap up", "end of day", "EOD", "done for today", "closing out", or wants to summarize today's work.
---

End-of-day pass: reflection → lessons → skill extraction → KB updates → style deltas → journal entry. Each step feeds the next; skipping early steps is fine — the conditional logic handles this automatically.

**DO NOT enter plan mode.** Execute all steps directly; only pause at the explicit Jira sync and style-delta approval gates. Plan mode breaks the automated flow.

<investigate_before_acting>
Follow the shared data-gathering algorithm (`workspace-data-gathering.md`) — read today's log/journal, tasks, and lessons. Do NOT read context.md or team profiles; wrap-up does not use them.
Verify file existence before reading — degrade gracefully if files are missing.
</investigate_before_acting>

**Input:** $ARGUMENTS (optional — override behavior: "force" to run all steps regardless of activity)

Follows `.claude/docs/external-mutation-policy.md` — Jira `transitionJiraIssue` calls in Step 5/6 go through `AskUserQuestion` before the API call.
Follows `.claude/docs/style-delta-capture.md` — Step 4e consumes pending `[STYLE-DELTA]` lines from today's log and proposes approval-gated edits to `workspace/communication-style.md`.
Follows `.claude/docs/confidential-marker.md` — do not promote `[CONFIDENTIAL]` log content into KB, recap, or journal prose.

## Steps

<workflow>

### Preflight: Language (MUST run first, non-negotiable)

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Journal entries at `workspace/journals/{date}.md` also follow `conversation:` (personal notes, not externally-posted). If `workspace/config.md` is missing, default English and note it once at the top.

### Step 0: Gather today's activity

Follow the shared data-gathering algorithm in `.claude/docs/workspace-data-gathering.md` with `SCOPE="day"` (today only). Start from the compact scanner payload, then read today's raw log/journal only when a truncated payload lacks required detail.

Key points from the shared algorithm:
- The `## Sessions` section in `workspace/logs/{YYYY-MM-DD}.md` is the **source of truth** for AI-assisted work.
- If the file is missing or has no `## Sessions` entries, treat today as low-activity.
- Do NOT scan git repos for commits — those include unrelated changes not done via AI.
- Build a sanitized session set before any promotion step:
  - `SAFE_SESSION_ENTRIES`: `## Sessions` entries with any `[CONFIDENTIAL]` line/block removed.
  - `CONFIDENTIAL_COUNT`: count of omitted confidential lines/blocks.
  - Never paraphrase omitted confidential content. Downstream reflect, learn, extract-skills, KB update, journal, highlights, and closing text must use `SAFE_SESSION_ENTRIES`, not the raw log.

Initialize a tracker: `reflect=skipped`, `learn=skipped`, `extract-skills=skipped`, `kb-update=skipped`, `style-delta=skipped`, `daily-report=pending`.

### Step 1: Reflect (conditional)

**Condition:** `SAFE_SESSION_ENTRIES` has substantive entries (beyond the auto-created header).
- If $ARGUMENTS contains "force", run regardless.

**If condition met:** invoke `/nase:reflect --auto-accept` with `SAFE_SESSION_ENTRIES` as today's work context (note: `reflect.md` recognizes `--auto-accept` and skips all interactive prompts). Capture its output for the journal. Set `reflect=done`.

**If condition NOT met:** print "No significant non-confidential work detected today — skipping reflect." Set `reflect=skipped-no-activity` (or `reflect=skipped-confidential-only` if the raw log had entries but `SAFE_SESSION_ENTRIES` is empty).

### Step 2: Learn (conditional)

**Condition:** reflect=done OR `SAFE_SESSION_ENTRIES` contains mistakes/discoveries.
- If $ARGUMENTS contains "force", run regardless.

**If condition met:** invoke `/nase:learn --auto-accept` using only `SAFE_SESSION_ENTRIES` as context. Set `learn=done`.

**If condition NOT met:** skip silently. Set `learn=skipped`.

### Step 3: Extract Reusable Skills (conditional)

**Condition:** reflect=done OR learn=done.
- If $ARGUMENTS contains "force", run regardless.

**If condition met:** invoke `/nase:extract-skills --auto-accept`. Report any skills created. Set `extract-skills=done`.

**If condition NOT met:** skip silently. Set `extract-skills=skipped`.

### Step 4: KB Update (conditional)

**Condition:** `SAFE_SESSION_ENTRIES` has entries mentioning repo work.
- If $ARGUMENTS contains "force", run regardless.

**If condition met:**
0. If today's session log contains `[CONFIDENTIAL]`, skip this automatic KB update and set `kb-update=skipped-confidential`. The user can run `/nase:kb-update` later with a sanitized summary.
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
   - Divergence ≥ 30%: append a calibration note to `workspace/tasks/lessons.md` (header format per `.claude/docs/lessons-format.md`):
     ```
     ## calibration -- {YYYY-MM-DD} -- ETA: {task name}
     **Estimated:** {realistic estimate} | **Actual:** ~{actual} | **Drift:** {over/under} by ~{%}
     **Pattern:** {one-line observation — e.g. "underestimated integration work", "unknown dependency added 2h"}
     ```
   - Divergence < 30%: no action needed — estimate was accurate
5. Over multiple entries, these notes let `/nase:estimate-eta` pattern-match against historical accuracy for the same types of tasks

**If condition NOT met:** skip silently.

### Step 4c: Jira Status Sync (opt-in)

**Condition:** `$ARGUMENTS` contains `jira-sync`. **Skipped by default** — this step asks the user to confirm transitions. The user opts in explicitly when they want it.

**If opted in** (follow `.claude/docs/jira-lifecycle.md` for cloudId resolution, transition lookup, confirmation rules, and graceful degradation):
1. Extract all ticket keys from `[x]` items in `workspace/tasks/todo.md` AND from today's session log entries (`workspace/logs/{YYYY-MM-DD}.md`)
2. For each key, fetch current status via `getJiraIssue`
3. Build a transition table — tickets still "In Progress" or "Open":

   | Key | Summary | Current Status |
   |-----|---------|----------------|
   | SRE-XXXXX | ... | In Progress |

4. Use a single `AskUserQuestion` (batched, per CLAUDE.md skill-output discipline): "Transition these to Done?" with options `all / pick numbers / skip`.
5. For each confirmed transition, write a fresh one-shot `workspace/.jira-write-token` immediately before calling `transitionJiraIssue`:
   ```json
   {
     "tool_name": "{actual transitionJiraIssue tool name}",
     "issue_key": "{KEY}",
     "created_at": "{UTC ISO timestamp}",
     "payload_summary": "{KEY} -> Done",
     "payload_sha256": "{sha256 of canonical transitionJiraIssue tool_input}"
   }
   ```
   One token per Jira tool call; never reuse a token across tickets. Then call `transitionJiraIssue`.

**If not opted in:** skip silently — note `jira-sync` in the status line as `~~jira-sync~~` only if the user supplied the flag and it ran.

### Step 4d-pre: Log compaction (conditional)

**Condition:** today's log file (`workspace/logs/{YYYY-MM-DD}.md`) exceeds 15 KB.

**If condition met:**
1. Read the log file. Identify non-confidential `## Sessions` entries with timestamps older than 4 hours (older than `now − 4h`) AND no follow-up activity (no later entry that references the same PR / SRE ticket / file path).
2. For each stale entry, collapse it to a one-line summary: `HH:MM — {topic} — {outcome}`. Preserve PR / Jira / Confluence URLs verbatim.
3. Move the original full-text entries into `workspace/logs/archive/{YYYY-MM-DD}-full.md` (append, do not overwrite — multiple wrap-ups in one day may each compact a different slice). Leave `[CONFIDENTIAL]` entries unchanged in the live log; do not summarize or relocate them.
4. Rewrite the live log: keep the today-header, keep all entries from the last 4 hours full-fidelity, replace older entries with their one-line summaries under a `## Sessions (compacted)` subheading.

**If condition NOT met:** skip silently.

**Rationale:** busy-day logs reach 14–21 KB; review cost compounds across `/nase:recap`, `/nase:today`, and `/nase:wrap-up`. Older entries already have their links surfaced — full prose is rarely re-read.

### Step 4d: Today's Stats (always runs)

Invoke `.claude/scripts/today-stats.py` — single helper that reads the nase workspace name from `workspace/config.md` and emits both blocks (sessions+tokens, skill ranking) as key=value lines.

```bash
python3 .claude/scripts/today-stats.py
```

Expected output shape:
```
sessions=<int>
input_tokens=<int>
output_tokens=<int>
total_tokens=<int>
note=no-session-meta-dir         # only when ~/.claude/usage-data/session-meta/ missing
total_invocations=<int>
unique_skills=<int>
skill <name> <count>             # repeated, descending; absent when 0 invocations
```

Pass `--date YYYY-MM-DD` to override today, `--root <path>` to query a different nase workspace. Script always exits 0; missing inputs degrade to zeros (with a `note=` line when the session-meta directory is absent).

Store the parsed values; include them in Step 6's journal output. If `note=no-session-meta-dir` is present, render token data as "unavailable" rather than zeros.

### Step 4e: Style Delta Consolidation (conditional)

**Condition:** today's log contains at least one pending line matching `\[STYLE-DELTA\]`.

**If condition met:** follow `.claude/docs/style-delta-capture.md -> ## Wrap-up Consolidation (Step 4e)` end to end. Set `style-delta=done` when all pending deltas are applied, `style-delta=partial` when any remain pending after a selected apply, and `style-delta=discarded` when all pending deltas are discarded.

**If condition NOT met:** set `style-delta=skipped-no-deltas`.

### Step 5: Journal Entry (always runs)

Generate today's journal entry from the data already gathered in Step 0:

1. From `SAFE_SESSION_ENTRIES`, summarize each non-confidential `## Sessions` entry — one bullet per major task/topic: what was done and the outcome/decision. **Preserve all original links** (PR URLs, Jira tickets, Confluence pages, pipeline links) exactly as they appear. If `CONFIDENTIAL_COUNT > 0`, add one neutral note: `{CONFIDENTIAL_COUNT} confidential log item(s) omitted`.
2. From `workspace/tasks/todo.md` (if it exists): list items marked complete today under **Tasks Completed**, and any still in-progress under **In Progress**.
3. From `workspace/tasks/lessons.md` (if it exists): note any lessons added today under **Blockers / Notes**.
4. Include Step 4e's result under **Style Updates**: applied clusters, discarded clusters, pending clusters, or skipped.
5. If no `## Sessions` entries exist for today, note that no AI-assisted work was logged.
6. Set `daily-report=done`.

### Step 5b: Closing block (TLDR + tint)

Follow `.claude/docs/closing-block.md` for shape, name resolution, style palette, and generation rules.

**Per-skill delta for `/nase:wrap-up`:** TLDR items lift from today's actual outcomes (Steps 1–5) — completed PRs/Jira, lessons captured, KB updates, blockers hit. Tint may be reflective (look-back at the day) rather than forward-looking. For the style-rotation check, read the most recent prior `workspace/journals/*.md` only. In the new format, use the second non-empty `│     ...` content line inside the prior closing card; fall back to `^│ tint:` and then legacy `^｜` during format migration.

### Step 6: Write output file

**Do NOT echo full step content inline** — the file is the canonical record; chat only gets a brief summary. This keeps output tokens low while preserving full review-ability via the companion file.

**Scores-line requirement (instruction, not part of template):** the `**Scores:**` line is required whenever Step 1 (reflect) ran. `/nase:reflect` always produces three 1–5 dimensions (Accuracy / Efficiency / Quality) — capture them verbatim, do not omit. They are the user's day-rating signal and the source of `## calibration -- {YYYY-MM-DD}` entries in `lessons.md`. Include a one-line justification per dimension only if a score < 5.

**Section omission (instruction, not part of template):** omit the `## Today's Stats` section if `~/.claude/usage-data/session-meta/` produced no data. Omit `## Lessons` / `## KB Updates` only via their respective skip notes — do not leave headers empty.

1. Write to `workspace/journals/{YYYY-MM-DD}.md`. If the file already exists, overwrite it with the latest content (re-running wrap-up produces a fresh result, not a duplicate append).

```markdown
# Wrap-up — {YYYY-MM-DD}

## Today's Stats
Sessions: {N} | Tokens: {input_tokens} in / {output_tokens} out ({total_tokens} total)
Skills ({unique_skills} unique, {total_invocations} invocations): {skill1} ×{N}  {skill2} ×{N}  ...

## Reflection
{reflection output from Step 1, or "skipped — no significant activity"}

**Scores:** Accuracy {N}/5 | Efficiency {N}/5 | Quality {N}/5
{one-line justification per dimension if any score < 5}

## Lessons
{lessons extracted in Step 2, or "skipped"}

## KB Updates
{list of KB files updated and what was added, or "skipped — no repo work today"}

## Style Updates
{style-delta result from Step 4e, or "skipped — no pending style deltas"}

## Daily Report
{full daily report from Step 5}

---
{status line}

╭─ {Name}
│
│     {TLDR — see `.claude/docs/closing-block.md`}
│
│     {tint — see `.claude/docs/closing-block.md`}
│
╰─
```

Status line format:
```
Wrap-up complete — reflect | learn | extract-skills | kb-update | style-delta | daily-report
```
Use ~~strikethrough~~ for skipped steps. Example:
- Full day: `reflect | learn | extract-skills | kb-update | style-delta | daily-report`
- Light day: `~~reflect~~ | ~~learn~~ | ~~extract-skills~~ | ~~kb-update~~ | ~~style-delta~~ | daily-report`

After writing the file, output ONLY these four things (nothing more — no full reflection text, no full daily report, no expanded lists):
1. `Wrap-up written → workspace/journals/{YYYY-MM-DD}.md`
2. **Highlights** — 3–5 bullet lines pulling the most important items from today (e.g. "{pr_ref} merged · {issue_key} resolved · 1 lesson captured · 2 KB files updated"). Keep each bullet ≤80 chars; this is the headline view, not the detail.
3. The status line
4. The **closing block** from Step 5b verbatim (seven lines: `╭─ {Name}`, blank rail, indented TLDR, blank rail, indented tint, blank rail, `╰─`). This must be the final visible chat content. Exception to the "file is canonical, summary only" rule — the block is small and orients the user; it's cheaper to echo than to make them open the journal.

Follow `.claude/docs/language-config.md` for conversation vs output language.

### Step 7: Self-log (mandatory)

Append a `wrap-up` bullet per `.claude/docs/daily-log-format.md → Self-logging rule`. Summary content: `N lessons captured · M KB updates · style-delta {status} · journal written`.

</workflow>

## Notes

<error_handling>

- **One-pass execution** — execute all non-Jira/non-style-delta-gate steps without pausing. All output is written to `workspace/journals/{YYYY-MM-DD}.md`; if the file exists it is overwritten. Edit the file afterward as needed.
- **"force" argument** — `$ARGUMENTS` containing "force" bypasses all skip conditions and runs every step.
- **Late sessions** — if no session log entries since midnight but entries exist in the last 12 hours, include those (handles cross-midnight work).
- **Idempotent** — running wrap-up twice in one day is safe; reflect/learn will see previous entries and can skip or augment.
- **Order matters** — Execute steps in sequence: reflect → learn → extract-skills → kb-update → style-delta → daily-report (each feeds the next).
- **Bookend** — This skill closes the day. Start the next day with `/nase:today` for a focused kickoff.

</error_handling>
