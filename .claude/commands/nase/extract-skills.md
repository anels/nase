Analyze the current session and extract reusable problem-solving patterns as new nase skills. Run at the end of any session where you solved a non-trivial problem, debugged something tricky, or found a useful technique. Don't skip it — captured patterns compound into lasting productivity gains.

**Input:** $ARGUMENTS (optional — focus hint, e.g. "the backup fix" or "the onboard workflow"; pass `auto` to skip the confirmation gate and auto-approve all candidates)

## Why this matters

Every hard problem you solve is an investment. Without capture, that knowledge evaporates when the session ends. This skill is the "cognitive flywheel" — it turns one-off solutions into reusable patterns that compound over time. The bar is intentionally high: a few excellent skills are worth more than a pile of mediocre ones.

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

### 2. Apply the quality bar

For each candidate, it must pass all three:

- **Reusable** — will this come up again in future sessions, across different repos or tasks? A pattern that only applies to one specific codebase isn't worth extracting.
  - ✅ Pass: "How to resolve a diverged git worktree before onboarding" — could happen in any repo
  - ❌ Fail: "How to fix the ADF pipeline for the Mercy tenant" — specific to one customer/env

- **Non-obvious** — is this already covered by a `/nase:*` command, a CLAUDE.md rule, or an existing `work/skills/` file? If so, consider updating the existing one instead.
  - ✅ Pass: A multi-step sequence for safely testing hook changes without triggering the Stop backup — not in any existing skill
  - ❌ Fail: "Run `/nase:doctor` when something feels broken" — already in CLAUDE.md

- **Self-contained** — can another Claude instance follow the steps cold, without context from this session? If it requires too much implicit knowledge, it's not ready to extract.
  - ✅ Pass: Step-by-step bash script + expected output for each step
  - ❌ Fail: "Do what we did earlier with the JSON" — requires session context to understand

If zero candidates pass: report "No extractable skills found in this session." and stop.

### 3. Check for duplicates

For each remaining candidate:
- Scan `.claude/commands/nase/` and `work/skills/` file names for similar skills
- If a near-duplicate exists: propose updating that file instead of creating a new one

### 4. Propose to the user

For each skill to create or update, show:
```
Pattern: {proposed-name}
File: work/skills/{proposed-name}.md
Summary: {one-line description}
Steps: {brief outline of the workflow}
```

If $ARGUMENTS contains `auto`, skip this gate and proceed directly to Step 5.

Otherwise confirm using AskUserQuestion:
```
question: "Create these skills?"
header: "Confirm Skills"
options:
  - label: "Yes — create all"  , description: "Write skill files to work/skills/"
  - label: "Edit"               , description: "Adjust before creating"
  - label: "No — skip"          , description: "Nothing is written"
```
- **Yes**: proceed to Step 5
- **Edit**: ask what to change, then re-propose
- **No**: stop, nothing is written

### 5. Write the skill file(s)

Create `work/skills/{name}.md` for each approved skill:

```markdown
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

Writing guidelines:
- First line: plain sentence, no heading — this is what future sessions scan to decide relevance
- Steps must be concrete enough that a fresh Claude instance can execute them without asking clarifying questions
- Explain **why** each step matters, not just **what** to do — this helps the model adapt when the situation doesn't match exactly
- One skill = one goal; if you're cramming two workflows into one file, split them

### 6. Cross-reference lessons

If the extracted skill captures a hard-won lesson (not just a procedural template), append a brief entry to `work/tasks/lessons.md` noting the pattern and why it matters.

### 7. Report

List skills created (with file paths), skills updated (with what changed), and skills skipped (with reason).

</workflow>
