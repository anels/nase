---
name: nase:extract-skills
description: Analyze the current session and extract reusable problem-solving patterns as new nase skills. Run at the end of any session where you solved a non-trivial problem or found a useful technique. Also triggers on "extract pattern", "save technique", "capture workflow".
argument-hint: "[session notes or topic]"
when_to_use: "Analyze the current session and extract reusable problem-solving patterns as new nase skills. Run at the end of any session where you solved a non-trivial problem or found a useful technique. Also triggers on \"extract pattern\", \"save technique\", \"capture workflow\"."
pattern: pipeline
category: Learning & reflection
---

Captured patterns make future sessions easier to repeat — don't skip this after non-trivial sessions.

**DO NOT enter plan mode.** Execute the steps directly.
Follows `.claude/docs/workspace-write-guard.md` for `workspace/skills/`, wrapper commands, and lesson writes. Auto-write modes only skip human confirmation; they never skip final drift checks. `--auto-accept` skips only the proposal prompt, not staging or the final drift check.

**Input:** $ARGUMENTS (optional — focus hint, e.g. "the backup fix" or "the onboard workflow"; pass `--auto-accept` to skip the confirmation gate and auto-approve all candidates)

## Steps

<workflow>

### 0. Language preflight (MUST run first, non-negotiable)

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Skill files written in Step 5 keep English for `name:` / `description:` / structural headers; freeform prose follows `conversation:`.

### 1. Mine the session for patterns

Review the conversation history (or focus on $ARGUMENTS if provided). The richest sources of patterns are:

- **Human-intervention gaps (highest signal)** — anywhere the user had to step in to unblock you. The struggle is what exposes a genuine knowledge gap the fresh model lacked; name explicitly what the gap was and what closed it, and seed the skill from that — not from re-deriving what the model already does well.
- **User corrections** — when the user redirected your approach, that delta between "what you tried" and "what worked" is often a reusable insight
- **Multi-step tool sequences** — if you chained 3+ tool calls to achieve something, that sequence might be worth templating
- **Repeated workflows** — the same shape of work appearing across different parts of the session
- **Debugging breakthroughs** — diagnostic techniques that cracked a non-obvious problem
- **"I wish I had a command for this" moments** — friction points that slowed the work down

List 1-3 candidates with one-line descriptions. Prioritize the intervention-gap candidates — they are usually the strongest evidence for Step 2's "non-obvious" check.

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

### 2.5. Scan for stale skills (confidence decay)

Skip entirely if no candidates passed Step 2's quality bar.

Check existing skills for staleness:

1. Read all `workspace/skills/*.md` files
2. For each file with `confidence:` and `extracted:` frontmatter:
   - Calculate age in days since `extracted:` date
   - Apply decay, offset by demonstrated successes: `effective_confidence = confidence - (age_days / 5) + (successes × 8)` (decay loses ~6 pts/month; each proven success buys back ~8 — patterns that keep helping resist aging, unused ones decay normally). `successes:` defaults to 0 if absent.
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

For each approved skill, stage the raw skill file and wrapper under `workspace/tmp/`, show the diff or first 40 lines for new files, then re-check target mtime/hash before writing. Create `workspace/skills/{name}.md` for each approved skill:

```markdown
---
confidence: {score from Step 2, 0-100}
extracted: {YYYY-MM-DD}
successes: 0
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

The `confidence:`, `extracted:`, and `successes:` frontmatter enable Step 2.5's decay/graduation mechanism in future runs. When a session confirms a previously-extracted skill demonstrably helped — it was invoked and produced the right outcome — increment its `successes:` counter by 1 so a proven pattern earns back confidence instead of decaying like an unused one.

Writing guidelines:
- First line: plain sentence, no heading — this is what future sessions scan to decide relevance
- Steps must be concrete enough that a fresh Claude instance can execute them without asking clarifying questions
- Explain **why** each step matters, not just **what** to do — this helps the model adapt when the situation doesn't match exactly
- One skill = one goal; if you're cramming two workflows into one file, split them
- **MCP tool name verification**: if the skill references any MCP tools (e.g. `mcp__plugin_slack_slack__*`, `mcp__plugin_atlassian_atlassian__*`), verify each tool name against the current session's available tool list before writing. Wrong MCP tool names fail silently at runtime — the skill appears correct but produces no results when executed

### 5.5. Failure-mode self-review (before writing)

Run the staged draft against `.claude/docs/skill-authoring-contract.md → §11 Authoring self-review`. This exists because a freshly-generated skill is exactly where the six failure modes creep in — a mined pattern tends to arrive over-specified and padded with lines the model already obeys. Scan for and fix:
- **No-op** — delete any step the model would do by default (test each sentence in isolation: does it change behavior vs no instruction?). A weak "be thorough" becomes a stronger leading word or gets cut.
- **Negation** — rewrite bare prohibitions as the positive target; keep a ban only when the target is unphraseable positively.
- **Premature completion** — every step ends on a checkable completion criterion; make the demanding ones exhaustive ("every X accounted for", not "produce a list of X").
- **Duplication / Sediment / Sprawl** — one source of truth per meaning; if the body nears the length limit, push detail behind a reference pointer.

Then set invocation type by cost (§11): default user-invoked (`disable-model-invocation`-style, zero context load) unless the agent or another skill must reach it on its own — model-invoked pays permanent per-turn context load, so it earns its keep only when auto-discovery is required.

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
