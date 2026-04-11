---
name: nase:design
description: "KB-aware collaborative design skill — turn vague ideas into concrete, tracked design docs through structured interview. Reads domain KB before asking questions, explores 2-3 approaches with tradeoffs, and writes a tracked effort doc with lifecycle checklist. Use when starting any non-trivial feature or project. Triggers on: 'design', 'brainstorm', 'plan a feature', 'kickoff', 'start project', 'I want to build...', 'let's design...', or any request that needs collaborative thinking before implementation."
---

Turn ideas into concrete, tracked design plan through KB-aware collaborative thinking.

Enter plan mode at the start of Phase 5 (Writing the Design Doc), not during Phase 4 (Design Presentation is interactive Q&A).

## Design Principles Framework

Apply these five principles to every design. The **order matters** — it changes which tradeoffs you prioritize first:

| Principle | What it means in practice |
|-----------|--------------------------|
| **First Principles** | Strip back to core requirements. What is the actual problem? What assumptions can be challenged? |
| **YAGNI** | Only design for what is needed now. No speculative extensibility. |
| **KISS** | Prefer the simpler design. Complexity is a liability — justify it. |
| **SOLID** | When modeling components/modules: single responsibility, open/closed, dependency inversion. |
| **DRY** | Identify reusable patterns; don't reinvent what the KB or codebase already has. |

**Dynamic ordering by context** — lead with the principle that matters most for the current design:

- **Architecture / Project Kickoff**: First Principles → YAGNI → KISS → SOLID → DRY
- **New Feature / Incremental**: YAGNI → KISS → SOLID → DRY → First Principles
- **Small Function / Utility**: KISS → DRY → YAGNI → SOLID → First Principles
- **Complex Component / OO Modeling**: First Principles → SOLID → YAGNI → KISS → DRY

Before presenting options in Phase 3, explicitly state which ordering you're applying and why. Use the principles as a lens to evaluate each option — not just pros/cons, but *which principle each option honors or violates*.

## Review Mode

Triggered when: user re-runs `/nase:design` on an existing effort (slug already exists in `workspace/efforts/`), or passes `--review` to force review mode even if auto-detection doesn't match (e.g., the slug is in a non-standard location).

1. **Read** the existing effort doc from `workspace/efforts/{slug}.md`
2. **Gather current state** — check repo for changes since the design was written (git log, new patterns, resolved open questions)
3. **Evaluate against Quality Criteria** (see below) — score each criterion
4. **Verdict** via `AskUserQuestion`:
   - **APPROVED** — design holds, no changes needed. Suggest proceeding to `/nase:fsd`
   - **Needs Revision** — specific issues listed with suggested fixes. Return to Phase 2 with the issues as context
   - **Superseded** — requirements changed enough to warrant a fresh design. Archive the old doc (rename to `{slug}-v1.md`) and start Phase 1

The output is a design doc at `workspace/efforts/{slug}.md` with a lifecycle checklist. Other skills (`/nase:fsd`, `/nase:prep-merge`) update the same file as the effort progresses. `/nase:today` surfaces active efforts automatically.

This skill is only allowed to create or edit the design doc. no code edit is allowed.

Always ask for clarification when anything is unclear — do not include uncertain items in the plan.

**Input:** $ARGUMENTS — the idea, feature request, or problem statement (can be vague). If empty, use `AskUserQuestion` to ask the user to describe what they want to design.

## Setup

If `AskUserQuestion` is not already available, use `ToolSearch` to fetch it before starting. Also fetch `EnterPlanMode` — it's a deferred tool needed at the start of Phase 4.

Read `workspace/config.md` to extract `conversation:` and `output:` language settings. Use conversation language for interview dialogue, output language for the design doc. If config.md is missing, default to English for both.

## Hard Gate

Do NOT write any code or take any implementation action. This skill produces a design doc, not code. Implementation is a separate step (e.g., `/nase:fsd`).

## Phase 1: Context Gathering (parallel, before asking anything)

Research first — minimize questions to the user. Run all in parallel:

**1a. Parse the idea** — extract keywords, domain areas, tech references from $ARGUMENTS

**1b. KB lookup** — read `workspace/kb/.domain-map.md`, identify the most relevant domain(s), read those KB files. Extract: architecture constraints, existing patterns, related past decisions, ownership info

**1c. Repo state** — if a target repo is inferable, read `.local-paths` to resolve the path, then:
```bash
git -C {repo} log --oneline -10
git -C {repo} branch -a --list 'feature/*'
```
Also read the repo's `CLAUDE.md` for coding standards and constraints.

**1d. Existing efforts** — read `workspace/tasks/todo.md` to check for overlapping or related efforts already tracked

**1e. Jira context** (if Atlassian MCP available) — search for related tickets:
```
project in (...) AND (summary ~ "{keywords}" OR description ~ "{keywords}") ORDER BY updated DESC
```
Note any existing tickets, their status, and assignees.

After gathering: synthesize a 3-5 sentence context brief showing what you already know. Present it to the user: "Here's what I found in the KB and codebase before we dive in..."

## Phase 2: Collaborative Design (one question at a time)

Interview the user to refine the idea into a concrete design. Rules:
- **One question at a time** via `AskUserQuestion` — never batch
- **Multiple choice preferred** with 2-4 options + "Other"
- **Never ask codebase facts** — look them up yourself (Grep, Read, explore agent)
- **Focus on**: intent, constraints, success criteria, scope decisions, priority

### 2a. Scope Classification

First question classifies scope:
```
question: "What kind of effort is this?"
header: "Scope"
options:
  - label: "Quick fix"          , description: "< 1 hour, single repo, focused change"
  - label: "Feature"            , description: "1-3 days, may span multiple files/services"
  - label: "Initiative"         , description: "Multi-day, cross-cutting, needs decomposition"
  - label: "Exploration"        , description: "Research/spike — uncertain scope, need to learn first"
```

When writing the `scope:` frontmatter value, normalize the user's choice to lowercase-hyphenated form (e.g., "Quick fix" → `quick-fix`).

- **Quick fix**: streamlined path — 1-2 clarifying questions → minimal design
- **Feature**: standard path — 3-5 questions → design with alternatives
- **Initiative**: decomposition path — break into sub-efforts, each gets its own design doc
- **Exploration**: spike path — time-boxed research plan → findings doc → decide next

### 2b. Clarifying Questions (3-5 based on scope)

Tailor questions to what the KB didn't already answer. Focus areas:
- What does "done" look like? (success criteria)
- Are there constraints the KB doesn't capture? (deadlines, dependencies, stakeholder needs)
- Which approach do you prefer? (present 2-3 options with tradeoffs — see Phase 3)

### 2c. Cross-Reference During Interview

As the user answers, cross-reference against KB:
- If user mentions a pattern → check if KB already documents it
- If user describes a constraint → check if it conflicts with existing architecture
- If user names a dependency → verify it exists in the repo

Surface any conflicts: "The KB says X, but you're describing Y — should we update the KB after this?"

## Phase 3: Approach Exploration

Always present **2-3 options** — even for seemingly obvious problems. A second option sharpens the reasoning for the first.

**Step 1 — Declare your principle lens.** Before presenting options, state which ordering you're applying from the Design Principles Framework and why (1 sentence).

**Step 2 — Present options one at a time** to avoid decision fatigue. For each option use this format:

```markdown
### Option {N}: {Name}
**Approach:** {1-2 sentences}
**Pros:** {concrete advantages}
**Cons:** {concrete risks or costs}
**Fits KB patterns?** {yes/no + why}
**Principle alignment:** {which principles this honors; which it trades off}
```

After each option, ask: "What's your reaction to this?" — wait for the user before presenting the next.

**Step 3 — Comparative summary.** After all options are presented, show a concise comparison table:

```markdown
| | Option A | Option B | Option C |
|---|---|---|---|
| Complexity | Low | Medium | High |
| KB alignment | ✓ | ~ | ✗ |
| YAGNI | ✓ | ~ | ✗ |
| Risk | Low | Medium | High |
```

Columns: Complexity, KB alignment, key principle scores, Risk. Adapt columns to what actually differs.

**Step 4 — Recommend + Challenge.** Share your recommendation with clear reasoning. Then explicitly challenge it:

> "That said — is there a more elegant path? Could Option {X} be simplified to capture the core of Option {Y} without the overhead? What if we {specific suggestion}?"

Push yourself to find at least one concrete way to improve the leading option before asking the user to choose.

**Step 5 — Ask for final choice:**

```
question: "Which approach should we go with?"
header: "Approach"
options:
  - label: "{Approach A}"       , description: "{one-line summary + key tradeoff}"
  - label: "{Approach B}"       , description: "{one-line summary + key tradeoff}"
  - label: "Combine elements"   , description: "Mix and match — tell me what you want from each"
```

For **quick fixes**: still present 2 options, but keep them brief (one line each) — skip the comparative table.

## Phase 4: Design Presentation

Present the design in sections, scaled to complexity. After each section, check: "Does this look right so far?"

### Design Structure

```markdown
## Effort: {Title}

### Context
{Why this effort exists — problem statement, user need, or opportunity}

### Scope
{What's in and what's out — explicit boundaries}

### Design
{Architecture, components, data flow — reference KB patterns where applicable}

### Success Criteria
1. {Measurable criterion}
2. {Measurable criterion}

### Risks & Mitigations
- {Risk} → {Mitigation}

### Open Questions
- {Anything unresolved — tracked for follow-up}
```

For **initiatives**: include a decomposition section listing sub-efforts with dependency order.

## Phase 5: Write Design Doc + Track

After user approves the design:

**5a. Write design doc:**
Save to `workspace/efforts/{slug}.md` (create `efforts/` dir if missing):
```markdown
---
status: planned
created: {YYYY-MM-DD}
scope: {quick-fix|feature|initiative|exploration}
repo: {repo-name or "multiple"}
---

{Full design from Phase 4}

## Lifecycle
- [x] Design approved — {YYYY-MM-DD}
- [ ] Implementation started
- [ ] PR opened
- [ ] Review passed
- [ ] Merged
- [ ] Deployed (if applicable)
```

**5b. Add to todo.md:**
Append to `workspace/tasks/todo.md` under `## Pending`:
```markdown
- [ ] **{Title}** — {one-line summary} → `workspace/efforts/{slug}.md`
```

This makes the effort visible in `/nase:today` output.

**5c. Create Jira ticket** (if user wants — ask via AskUserQuestion):
```
question: "Create a Jira ticket for this effort?"
header: "Jira"
options:
  - label: "Yes"                , description: "Create ticket with design summary"
  - label: "No"                 , description: "Track in workspace only"
```
If yes: use the project key from the repo's KB file (or ask the user). Issue type: Task or Story. Set summary to the effort title, description to the design summary, and add a note linking back to the effort doc path.

**5d. Exit plan mode and offer meaningful next steps:**

Exit plan mode, then ask via `AskUserQuestion`:

```
question: "Design is saved. What would you like to do next?"
header: "Next Step"
options:
  - label: "Critic review"      , description: "I'll spawn oh-my-claudecode:critic with the full effort doc to challenge the design before you commit to implementation"
  - label: "Start implementation" , description: "Engage /nase:fsd for autonomous implementation right away"
  - label: "Park it"            , description: "Come back to it later — it'll surface in /nase:today"
```

Do NOT ask "should I proceed?" or "ready to execute?" — those are non-choices. Always offer the critic option so the user can get a second-opinion pass before building.

## Lifecycle Updates (by other skills)

The effort doc is updated by other skills as the effort progresses — no orchestrator needed:
- `/nase:fsd` → checks off "Implementation started" + "PR opened", updates `status: in-progress`
- `/nase:prep-merge` → checks off "Review passed", updates `status: merge-ready` (not "Merged" — actual merge is a human action on GitHub)
- `/nase:wrap-up` → can reference active efforts in the daily journal
- User can manually update any lifecycle item at any time

## Quality Criteria

Used by Review Mode and as a self-check before writing the design doc in Phase 5.

| Criterion | Standard |
|-----------|----------|
| **Specificity** | No vague terms without metrics ("fast" → "p99 < 200ms", "scalable" → "handles 10k concurrent users") |
| **Testability** | 90%+ success criteria are concretely verifiable (not "works well" but "returns 200 for valid input") |
| **Grounding** | Design references specific files, patterns, or KB entries where applicable |
| **Scope clarity** | Explicit in/out boundaries — what is NOT included is as clear as what is |
| **Risk coverage** | Every identified risk has a mitigation; no hand-waving |
| **KB alignment** | Design doesn't contradict documented architecture constraints without explicit justification |

## Final Checklist (before writing doc)

Before writing the effort doc in Phase 5, verify:
- [ ] Success criteria are testable (not vague)
- [ ] Scope boundaries are explicit (in AND out)
- [ ] All risks have mitigations
- [ ] Design references KB patterns where applicable
- [ ] No open questions that would block implementation
- [ ] Approach selection rationale is documented

## Notes

- **KB is the unfair advantage** — always read it before asking the user. The more you know upfront, the fewer questions you need to ask.
- **One question at a time** — hard rule. Batched questions overwhelm and produce lower-quality answers.
- **Scale to scope** — a quick fix gets a 3-line design. An initiative gets decomposition. Don't over-plan small things.
- **Design doc is the durable artifact** — it persists across sessions, visible in `/nase:today`, updated by downstream skills.
- **If things change during implementation** — update the effort doc. It's a living record, not a frozen spec.
- **Language**: use the **conversation language** (from `config.md`) for all interview dialogue. Write the design doc in the **output language**.
