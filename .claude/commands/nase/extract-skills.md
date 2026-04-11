---
name: nase:extract-skills
description: Analyze the current session and extract reusable problem-solving patterns as new nase skills. Run at the end of any session where you solved a non-trivial problem or found a useful technique. Also triggers on "extract pattern", "save technique", "capture workflow".
---

Captured patterns compound into lasting productivity gains — don't skip this after non-trivial sessions.

**DO NOT enter plan mode.** Execute steps directly and autonomously.

**Input:** $ARGUMENTS (optional — focus hint, e.g. "the backup fix" or "the onboard workflow"; pass `--auto-accept` to skip the confirmation gate and auto-approve all candidates)

## Setup

Needs: `AskUserQuestion` (fetch via ToolSearch). Skip if `--auto-accept`.

## Steps

<workflow>

### 1. Mine the session for patterns

Review the conversation history (or focus on $ARGUMENTS if provided). The richest sources of patterns are:

- **User corrections** — when the user redirected your approach, that delta between "what you tried" and "what worked" is often a reusable insight
- **Multi-step tool sequences** — if you chained 3+ tool calls to achieve something, that sequence might be worth templating
- **Repeated workflows** — the same shape of work appearing across different parts of the session
- **Debugging breakthroughs** — diagnostic techniques that cracked a non-obvious problem
- **"I wish I had a command for this" moments** — friction points that slowed the work down

List 1-3 candidates with one-line descriptions.

### 2.5. Scan for stale skills (confidence decay)

Run this scan **after** Step 2 filters candidates — skip entirely if no candidates pass the quality bar. This avoids reading all skill files in sessions that produce no new extractions.

Check existing skills for staleness:

1. Read all `workspace/skills/*.md` files
2. For each file with `confidence:` and `extracted:` frontmatter:
   - Calculate age in days since `extracted:` date
   - Apply decay: `effective_confidence = confidence - (age_days / 5)` (loses ~6 points per month)
   - If effective_confidence < 40: flag as **stale** — candidate for pruning
   - If effective_confidence 40-59: flag as **aging** — candidate for re-validation
3. If any stale/aging skills found, report them before proposing new extractions:
   ```
   ⚠ Stale skills (consider pruning):
   - {name} — confidence {original} → {effective} (extracted {date}, {age}d ago)

   ⏳ Aging skills (re-validate or boost):
   - {name} — confidence {original} → {effective} (extracted {date}, {age}d ago)
   ```
4. If a new candidate overlaps with a stale skill, propose replacing it instead of creating a new one

### 2. Apply the quality bar + confidence scoring

For each candidate, assign a **confidence score (0–100)** based on:
- **Frequency signal** (0–30): How often might this recur? Daily = 30, weekly = 20, monthly = 10, rare = 0
- **Complexity saved** (0–30): How many steps/minutes does the pattern save? 5+ steps = 30, 3-4 = 20, 1-2 = 10
- **Generality** (0–20): Applies across repos = 20, across domains = 15, single repo = 5
- **Clarity** (0–20): Could a fresh Claude instance execute cold? Fully = 20, mostly = 10, needs context = 0

**Minimum threshold: 60.** Candidates scoring < 60 are dropped with reason.

Each candidate must also pass all three qualitative checks:

- **Reusable** — will this come up again in future sessions, across different repos or tasks? A pattern that only applies to one specific codebase isn't worth extracting.
  - ✅ Pass: "How to resolve a diverged git worktree before onboarding" — could happen in any repo
  - ❌ Fail: "How to fix the ADF pipeline for the Mercy tenant" — specific to one customer/env

- **Non-obvious** — is this already covered by a `/nase:*` command, a CLAUDE.md rule, or an existing `workspace/skills/` file? If so, consider updating the existing one instead.
  - ✅ Pass: A multi-step sequence for safely testing hook changes without triggering the Stop backup — not in any existing skill
  - ❌ Fail: "Run `/nase:doctor` when something feels broken" — already in CLAUDE.md

- **Self-contained** — can another Claude instance follow the steps cold, without context from this session? If it requires too much implicit knowledge, it's not ready to extract.
  - ✅ Pass: Step-by-step bash script + expected output for each step
  - ❌ Fail: "Do what we did earlier with the JSON" — requires session context to understand

If zero candidates pass both the score threshold and qualitative checks: report "No extractable skills found in this session." and stop.

### 3. Check for duplicates

For each remaining candidate:
- Scan `.claude/commands/nase/` and `workspace/skills/` file names for similar skills
- If a near-duplicate exists: propose updating that file instead of creating a new one

### 4. Propose to the user

For each skill to create or update, show:
```
Pattern: {proposed-name}
File: workspace/skills/{proposed-name}.md
Summary: {one-line description}
Steps: {brief outline of the workflow}
```

If $ARGUMENTS contains `--auto-accept`, skip this gate and proceed directly to Step 5.

Otherwise confirm using AskUserQuestion:
```
question: "Create these skills?"
header: "Confirm Skills"
options:
  - label: "Yes — create all"  , description: "Write skill files to workspace/skills/"
  - label: "Edit"               , description: "Adjust before creating"
  - label: "No — skip"          , description: "Nothing is written"
```
- **Yes**: proceed to Step 5
- **Edit**: ask what to change, then re-propose
- **No**: stop, nothing is written

### 5. Write the skill file(s)

Create `workspace/skills/{name}.md` for each approved skill:

```markdown
---
confidence: {score from Step 2, 0-100}
extracted: {YYYY-MM-DD}
---

{One-sentence description — what this skill does and when to reach for it.}

**Input:** $ARGUMENTS (describe expected input, or "no input required")

## When to use

{1-2 sentences describing the trigger — what situation or symptom tells you this skill is the right tool.}

## Steps

1. ...
2. ...
3. ...

## Notes
- {important constraints, gotchas, or things that look like they'd work but don't}
```

The `confidence:` and `extracted:` frontmatter enables Step 1.5's decay mechanism in future runs.

Writing guidelines:
- First line: plain sentence, no heading — this is what future sessions scan to decide relevance
- Steps must be concrete enough that a fresh Claude instance can execute them without asking clarifying questions
- Explain **why** each step matters, not just **what** to do — this helps the model adapt when the situation doesn't match exactly
- One skill = one goal; if you're cramming two workflows into one file, split them

### 6. Cross-reference lessons

If the extracted skill captures a hard-won lesson (not just a procedural template), append a brief entry to `workspace/tasks/lessons.md` noting the pattern and why it matters.

### 6b. Generate thin wrapper for immediate invocation

For each new skill created in `workspace/skills/{name}.md`, also generate the thin wrapper command file at `.claude/commands/nase/workspace/{name}.md` so the skill is immediately invocable without restarting the session:
```
---
name: nase:workspace:{name}
description: "{first non-empty content line from the skill file}"
---
Read and follow `workspace/skills/{name}.md`
```

### 7. Report

List skills created (with file paths), skills updated (with what changed), and skills skipped (with reason).

</workflow>
