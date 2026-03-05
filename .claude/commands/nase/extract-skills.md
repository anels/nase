Analyze the current session and extract reusable problem-solving patterns as new nase skills.

**Input:** $ARGUMENTS (optional — focus hint, e.g. "the backup fix" or "the onboard workflow"; pass `auto` to skip the confirmation gate and auto-approve all candidates)

## Purpose

After solving a non-trivial problem or discovering a useful pattern, run this skill to capture it as a reusable pattern file under `work/skills/`. This is the "cognitive flywheel" step: good solutions compound over time.

## Quality Bar

Only extract a pattern if ALL of these are true:
- It is **reusable** — the same workflow or technique will apply in future sessions
- It is **non-obvious** — not already covered by an existing skill or CLAUDE.md rule
- It is **self-contained** — can be described as a clear sequence of steps

Skip if the pattern is: a one-time fix, a project-specific hack, or already documented.

## Steps

<workflow>

### 1. Identify candidate patterns

Review the current conversation (or focus on $ARGUMENTS if provided). Look for:
- Workflows repeated across multiple steps that could be templated
- Diagnostic or debugging techniques that proved effective
- Sequences of tool calls that solved a class of problem
- Any "I wish I had a command for this" moments

List 1-3 candidates with one-line descriptions.

### 2. Filter by quality bar

For each candidate, check against the quality bar above. Discard any that don't pass all three criteria.

If zero candidates pass: report "No extractable skills found in this session." and stop.

### 3. Check for duplicates

For each remaining candidate:
- Scan `.claude/commands/nase/` and `work/skills/` file names to check if a similar skill already exists
- If a near-duplicate exists: propose updating that file instead of creating a new one

### 4. Propose skill(s) to the user

For each skill to create or update, show:
```
Pattern: {proposed-name}
File: work/skills/{proposed-name}.md
Summary: {one-line description}
Steps: {brief outline of the workflow}
```

If $ARGUMENTS contains `auto`, skip this gate and auto-approve all proposed skills.

Otherwise ask: "Create these skills? (yes / no / edit)"
- **yes**: proceed to Step 5
- **no**: stop, nothing is written
- **edit**: ask what to change, then re-propose

### 5. Write skill file(s)

For each approved skill, create `work/skills/{name}.md` using this template:

```markdown
{One-sentence description of what this skill does.}

**Input:** $ARGUMENTS (describe what the input is, or "no input required")

## Steps

1. ...
2. ...
3. ...

## Notes
- {any important constraints or gotchas}
```

Rules for the skill file:
- First line must be a plain one-sentence description (no heading)
- Use `$ARGUMENTS` for user-provided input
- Steps should be concrete and self-contained — another Claude instance should be able to follow them cold
- Keep it focused: one skill = one goal

### 6. Record in lessons.md (if applicable)

If the extracted skill captures a lesson worth remembering (not just a procedural template), append a brief entry to `work/tasks/lessons.md` noting what pattern was extracted and why.

### 7. Confirm

Report:
- Skills created (file paths)
- Skills updated (file paths + what changed)
- Skills skipped (reason)

</workflow>
