---
name: nase:design
description: "KB-aware design — researches context (codebase, KB, official docs, dependency source, forums), explores 2-3 approaches with tradeoffs, writes a tracked, junior-implementable effort doc with a built-in ETA estimate. Design only, no code (use /nase:fsd to implement). Defaults to an end-to-end auto pass that asks any genuine human-input questions at the end. Supports `--interactive` (turn-by-turn flow), `--grill` (multi-persona stress-test), `--review` (re-evaluate), `--auto` (explicit auto pass). Triggers: 'design', 'brainstorm', 'plan feature', 'kickoff', 'I want to build', 'grill plan', 'auto design'."
argument-hint: "<feature/request> [--auto|--interactive|--grill|--review]"
when_to_use: "KB-aware design — researches context (codebase, KB, official docs, dependency source, forums), explores 2-3 approaches with tradeoffs, writes a tracked, junior-implementable effort doc with a built-in ETA estimate. Design only, no code (use /nase:fsd to implement). Defaults to an end-to-end auto pass that asks any genuine human-input questions at the..."
pattern: pipeline
category: Design & implementation
sub-patterns: [fan-out]
---

Turn ideas into a concrete, tracked design plan through KB-aware research.
Follows `.claude/docs/external-mutation-policy.md` — optional Jira issue creation goes through `AskUserQuestion` plus the Jira write-token backstop.
Follows `.claude/docs/workspace-write-guard.md` and `.claude/docs/effort-lifecycle.md` for `workspace/efforts/` and `workspace/tasks/` writes. Use `python3 .claude/scripts/workspace-write-guard.py stage` for Phase 5 full-file writes. Phase 5 is an approved auto-write path, so it skips the prompt but not staging, diff/preview, or final mtime/hash drift checks.

Fan-out threshold: stay main-thread unless the request spans multiple repos, more than 20 files, more than 1000 diff lines, or the user explicitly asks for deep/batch work. Prefer compact script output before spawning agents.

## Design Principles Framework

Apply the principle set and dynamic ordering in `.claude/docs/design-principles.md` — classify the design (kickoff / incremental / small utility / complex component) and lead with the matching order. At design time, **also treat Elegance as a real dimension**: weave it in right after KISS, preferring the option with a coherent shape (fewer moving parts, clear boundaries, natural fit with existing patterns) unless another principle clearly outweighs it.

Before presenting options in Phase 3, explicitly state which ordering you're applying and why. Use the principles as a lens to evaluate each option — not just pros/cons, but *which principle each option honors or violates*.

### What a technical decision optimizes for

When choosing between approaches, optimize for the long-term health of the system: **quality, simplicity, robustness, scalability, elegance, and long-term maintainability**. Development cost — how fast or cheap an option is to build, how much effort it takes, how many hours it saves now — is **not** a selection weight. Do not pick a worse design because it ships sooner, and do not list "quicker to implement" as a pro that tips the decision. We are choosing what the codebase has to live with for years, not what is easiest this week; a few days saved at design time is noise against the cost of carrying the wrong shape.

This is not a license to over-engineer. Simplicity and YAGNI are *in* the optimize-for set, so the bar is the simplest design that is genuinely robust, scalable, and maintainable — not the most elaborate one. Build effort being ignored as a *decision weight* does not mean building more; it means the cheaper-to-build option wins only when it is also the better-quality option.

The ETA Estimate (Phase 4) is still produced — it is planning output for the chosen design, not a factor in choosing it. Runtime, operational, and maintenance cost of an option *are* legitimate quality concerns (they bear on robustness and maintainability); only **development cost** is excluded from the decision.

## Reviewability / PR Economy

Default to one PR for one coherent behavior change. Decomposition is for thinking, implementation order, and risk control; it is not automatically a PR split.

Split into multiple PRs only when at least one of these is true:

- Different repos must change and cannot be reviewed or merged in one repo-local PR.
- A compatibility, migration, or rollout boundary needs a separately mergeable checkpoint.
- A mechanical/generated/rename-only change can be isolated from behavior so reviewers can ignore noise.
- The expected diff is likely to cross `/nase:fsd`'s 1500-line hard review gate.
- Distinct owner groups must review unrelated surfaces and a single PR would hide the load-bearing change.

When a split is justified, minimize the count and name the dependency order. Do not produce one PR per layer, package, file type, or implementation phase by default. Prefer a single vertical-slice PR with a clear review guide over several small PRs that require reviewers to reconstruct intent across branches.

## Mode Detection

Before Phase 1, scan `$ARGUMENTS` for mode flags. Strip the flag from `$ARGUMENTS` before downstream parsing. Check in this order — first match wins.

- `--grill` present → enter **Grill Mode**: multi-persona stress-test of an existing plan, one question at a time. Skip all phases below and follow `.claude/docs/design-grill-mode.md`.
- `--review` present → enter **Review Mode** (next section).
- `--interactive` present → run the **turn-by-turn interactive flow** (Phase 1 onward below): present context, options, and design with the user in the loop. This is the legacy default, now opt-in.
- `--auto` present → enter **Auto Mode** explicitly (same as the no-flag default).
- **Otherwise (no flag) — the default:** if the slug already exists in `workspace/efforts/`, enter **Review Mode**. If not, enter **Auto Mode**: run the end-to-end research-grill-review pipeline without turn-by-turn prompts, then ask any genuinely-unanswerable questions in a single `AskUserQuestion` batch at the very end before writing/updating the report. Follow `.claude/docs/design-auto-mode.md`.

**Why auto is the default:** the research and grill passes resolve most questions from evidence, so turn-by-turn prompting mostly interrupts the user for things the codebase already answers. Auto front-loads the work and saves the user's attention for the few decisions only they can make — asked together, at the end. Reach for `--interactive` when the user explicitly wants to steer each step.

## Review Mode

Triggered when `--review` is present in `$ARGUMENTS`, or auto-detected when the slug already exists in `workspace/efforts/`. Skip all phases below and follow `.claude/docs/design-review-mode.md`. If the target effort doc has a `## Human Input Required` section (typically left by Auto Mode), review mode walks each row via `AskUserQuestion` (one question per turn, design's default flagged as Recommended) before scoring — see `design-review-mode.md` Step 1b.

This skill is only allowed to create or edit the design doc. No code edit is allowed.

When genuinely uncertain about a requirement, ask for clarification — but prefer researching the answer yourself first.

**Input:** $ARGUMENTS — the idea, feature request, or problem statement (can be vague). If empty, use `AskUserQuestion` to ask the user to describe what they want to design.

## Setup

Follow `.claude/docs/language-config.md` — use conversation language for interview dialogue, output language for the design doc.

## Hard Gate

Do NOT write any code or take any implementation action. This skill produces a design doc, not code. Implementation is a separate step (e.g., `/nase:fsd`).

## Phases 1–5 (interactive flow)

Phases 1–5 below define the turn-by-turn flow used by `--interactive`. Auto Mode (the default) runs the same phases without prompting and adapts them per `.claude/docs/design-auto-mode.md`; Grill and Review modes skip them entirely.

## Phase 1: Context Gathering (parallel, before asking anything)

Research first — minimize questions to the user. Run all in parallel:

For non-trivial designs, dispatch local read-only subagents in the same turn:
- `nase-context-kb-researcher` for KB constraints, prior decisions, ownership, and related efforts.
- `nase-repo-state-scanner` for repo `CLAUDE.md`, README/docs, git history, branches, entry points, and build/test hints.
- `nase-workspace-state-scanner` for active efforts, todo overlap, logs, and scheduled work.

The main thread owns design synthesis and workspace writes. Subagents return evidence tables only.
Reconcile conflicts, ask any user question, choose the final option set, and write `workspace/efforts/` / `workspace/tasks/` through the workspace write guard.

**1a. Parse the idea** — extract keywords, domain areas, tech references from $ARGUMENTS

**1b. KB lookup** — follow `.claude/docs/repo-resolution.md` Part 2 to load the relevant KB file(s). Extract: architecture constraints, existing patterns, related past decisions, ownership info

**1c. Repo state** — if a target repo is inferable, follow `.claude/docs/repo-resolution.md` Part 1 to resolve the path, then:
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

**1f. External research** (scale to scope) — for any feature/initiative/exploration, or any approach leaning on an external library/framework/SDK/API/platform behavior, look outward per `.claude/docs/design-research.md → Part A`: official docs (via `context7` / `ms-learn` MCPs or `WebSearch`+`WebFetch`), dependency source + changelog at the pinned version, issue trackers, then Q&A/blogs. Every external claim cites a URL or `path:line`, or is explicitly marked `gap: {reason}` and not used as support; apply the comprehension gate and debias pass before relying on a finding. Skip for well-understood quick-fixes.

After gathering: synthesize a 3-5 sentence context brief showing what you already know. Present it to the user: "Here's what I found in the KB, codebase, and external docs before we dive in..."

## Phase 2: Autonomous Scope & Constraint Analysis

Minimize questions — research aggressively and make evidence-based defaults where the KB, code, and Jira context are clear. The user already stated what they want; your job is to fill in the gaps from available evidence.

### 2a. Infer Scope (don't ask)

Classify scope automatically based on the input + context:
- **quick-fix**: single file/config change, well-understood area, <1 hour
- **feature**: multi-file, 1-3 days, clear boundaries
- **initiative**: cross-cutting, multi-day, needs decomposition
- **exploration**: uncertain scope, research needed first

When writing the `scope:` frontmatter value, use lowercase-hyphenated form.

### 2b. Autonomous Research (instead of asking)

For each gap the KB didn't cover, **look it up** rather than asking:
- Success criteria → infer from the problem statement + existing patterns
- Constraints → read repo CLAUDE.md, CI config, existing architecture
- Dependencies → grep the codebase, check package files
- **External authority** → if an approach depends on a validator script, runner pipeline, or schema generator, fetch that source and grep the exact decision points before Phase 3. Do not freeze a design — or leave a Human Input branch — on a guess when the authoritative behavior is readable.

### 2c. Only Ask When Genuinely Blocked

Use `AskUserQuestion` **only** when:
- There are 2+ equally valid interpretations and the KB gives no signal
- The task involves a business/stakeholder decision the codebase can't answer
- The user's input is too vague to even start researching

When you do ask, batch all uncertainties into a single question with multiple options. Never ask about things you can look up yourself.

### 2d. Telemetry / sampling impact pre-check

If the design touches any AppInsights / Azure Functions telemetry surface — `ExcludedTypes`, `SamplingPercentage`, `AdaptiveSamplingTelemetryProcessor`, `host.json` telemetry settings, `TelemetryProcessor` pipeline additions/removals, `ApplicationInsightsServiceOptions` / `TelemetryConfiguration`, or anything that changes the volume in `customMetrics` / `requests` / `exceptions` — apply the pre-merge protocol in `workspace/kb/general/dotnet.md` → **AppInsights Sampling / `ExcludedTypes` Changes Affect Far More SRE Alerts Than the Docs Imply** (2026-05-18). Enumerate the affected alert families and surface them as a dedicated risk in Phase 4's "Risks & Mitigations".

### 2e. Plan-phase gates

Before committing to an approach, run the gates that fit the work per `.claude/docs/design-research.md → Part B`. Each is "prove it, or explicitly flag that you couldn't" — skipping silently is the failure mode:

- **Bug-shaped work** → **repro gate** (B1: reliable reproduction / failing test / MRE before designing a fix) and **root-cause gate** (B2: 5 Whys / Fishbone / Fault Tree to the originating cause, not the symptom). Record both in the design's Context.
- **Any assumption about scale / usage / traffic / current behavior** → **prod-data validation gate** (B3): validate against telemetry/logs, or flag the assumption as a Risk / `[NEEDS CLARIFICATION]`.
- **Any code change** → **unit-test-gap analysis** (B4): map existing coverage of the area, name the gaps the change exposes; the implementation plan assigns tests against them.

### 2f. PR Packaging Analysis

Infer the review package before Phase 3. Start with `Target PR count: 1`. Raise the count only when the Reviewability / PR Economy split criteria above are met. If multiple PRs are required, record the smallest count, dependency order, and why a single PR would be harder to review or riskier to merge.

### 2g. Surface Map (ground the plan before decomposing)

Before Phase 4 decomposes the design into steps, produce an explicit **surface map** of the code the design touches: the concrete files, modules, and call paths (entry point → the functions/types that change → downstream callers/tests affected). Each Implementation Plan step in Phase 4 must cite a location from this map — a step whose files were never mapped is inference, not a plan, and is the false-confidence failure mode this guards against. If a needed path can't be located, that gap becomes an Open Question, not a guessed file. Keep the map to the touched surface only; do not inventory the whole repo. (Pattern borrowed from claude-skills' Zero-Hallucination-Coder Map/Decompose phases — see `workspace/kb/general/workflow.md` 2026-04-05 entry.)

## Phase 3: Approach Exploration (all at once)

Always present **2-3 options** — even for seemingly obvious problems. A second option sharpens the reasoning for the first. **Show everything in a single message** — no back-and-forth per option.

**Step 1 — Declare your principle lens.** State which ordering you're applying from the Design Principles Framework and why (1 sentence).

**Step 2 — Present ALL options together** in one message. For each option:

```markdown
### Option {N}: {Name}
**Approach:** {1-2 sentences}
**Pros:** {concrete advantages — quality, simplicity, robustness, scalability, elegance, maintainability; not "faster to build"}
**Cons:** {concrete risks, or runtime/operational/maintenance costs — not development cost}
**Fits KB patterns?** {yes/no + cite the specific KB entry or file:line that backs the claim; if you cannot cite one, mark `gap: {one-line why — no source found}` — never assert alignment from memory, and never score a `gap`-marked option as KB-aligned when comparing/selecting}
**Principle alignment:** {which principles this honors; which it trades off}
**Elegance:** {is the shape coherent and natural, or is it clever/awkward?}
**Review / PR shape:** {target PR count and review cost; default to one PR unless a split criterion is met}
```

**Step 3 — Comparison table** (immediately after options, same message):

```markdown
| | Option A | Option B | Option C |
|---|---|---|---|
| Complexity | Low | Medium | High |
| KB alignment | ✓ | ~ | ✗ |
| Elegance | ✓ | ~ | ✗ |
| YAGNI | ✓ | ~ | ✗ |
| PR count / review cost | 1 / Low | 1 / Medium | 2 / High |
| Risk | Low | Medium | High |
```

Columns: Complexity, KB alignment, Elegance, key principle scores, Risk. Adapt columns to what actually differs. For non-trivial or architecture-level choices, upgrade this to a **weighted decision matrix** per `.claude/docs/design-research.md → Part B5` (weight the criteria, score, run a sensitivity check on the weights, and spike any risky unknown rather than deciding on paper).

**Step 4 — Recommend + Challenge** (same message). Share your recommendation with clear reasoning, including why the leading option is or is not elegant. Then explicitly challenge it:

> "That said — is there a more elegant path? Could Option {X} be simplified to capture the core of Option {Y} without the overhead?"

Push yourself to find at least one concrete way to improve the leading option.

**Step 5 — Ask for final choice** (same message, single AskUserQuestion):

```
question: "Which approach should we go with?"
header: "Approach"
options:
  - label: "{Approach A}"       , description: "{one-line summary + key tradeoff}"
  - label: "{Approach B}"       , description: "{one-line summary + key tradeoff}"
  - label: "Combine elements"   , description: "Mix and match — tell me what you want from each"
```

For **quick fixes**: still present 2 options, but keep them brief (one line each) — skip the comparative table.

**The entire Phase 3 is ONE turn** — options, table, recommendation, and choice question are presented together. Never split across multiple messages.

## Phase 4: Design Presentation

Present the **full design in a single message** — do not pause between sections for feedback. The self-review loop (Phase 4b) handles quality assurance before the user sees it.

The design must be **junior-implementable**: a competent junior engineer (or `/nase:fsd`) can execute it with zero remaining design decisions. Apply `.claude/docs/design-research.md → Part C` for the rules behind each section, and **tier the depth to scope (C7)** — a quick-fix gets a 3-line design, not the full template.

**Always include the `### ETA Estimate`** — derive it from the Implementation Plan steps using `.claude/docs/eta-estimation.md`; the step breakdown already did its work, so the estimate is mostly classifying each step by lane/size and rolling up the confidence range. Tier the depth to scope like everything else: a quick-fix gets a single realistic line, a feature/initiative gets the per-step table and the optimistic/realistic/pessimistic range. Don't write the calibration log line here (that's `/nase:estimate-eta`'s job) — the estimate lives in the effort doc.

### Design Structure

```markdown
## Effort: {Title}

### Context
{Why this effort exists — problem statement, user need, or opportunity}
{Bug-shaped work: repro (or failure to repro) + root cause from Phase 2e gates}

### Goals
- {One measurable goal per line — what changes, and for any metric/perf/cost/coverage/behavior claim, the target number. "Cut dashboard-create p95 from ~50s to <1s", not "make it faster". A goal you can't later measure is a wish; if you can't attach a number or an observable state, say why and how success will otherwise be judged.}

### Non-Goals
- {Reasonable things explicitly cut from scope — NOT negations of goals (C1). The most-omitted, highest-leverage scoping tool.}

### Scope
{What's in and what's out — explicit boundaries}

### Design
{Architecture, components, data flow — reference KB patterns where applicable.}
{Concrete artifacts (C2): exact file paths, function/method signatures with types, data models, API contracts (endpoint/method/request/response/status/errors), pseudocode for non-obvious logic. Numbers not adjectives — every threshold/default/limit as a value. Use MUST/SHOULD/MAY (RFC 2119, C5) to mark binding vs advisory.}

### Success Criteria
{Given-When-Then, one assertion per behavior (C4). Each Then asserts an observable, binary outcome.}
1. Given {precondition}, When {action}, Then {observable outcome}
2. ...

### Validation — how to get the real number
{For each Success Criterion (and each numeric Goal), name the concrete way a future reader obtains the REAL post-change value: the data source + the exact query/command they can run. This is the payoff of the numbers above — it lets `/nase:fsd`'s verify pass and `/nase:effort-rollup` re-derive the real value instead of restating this doc's claim. A criterion with no runnable check is unverifiable; treat that as a design gap to fix now, not a formatting nicety. Match depth to scope — a quick-fix may need one line, an initiative one row per criterion.}
- {Criterion} → {source} : `{exact query/command}` — expect {value}.

Source recipes (use the one that fits; these carry gotchas learned the hard way):
- **App Insights / telemetry counts** — if the component is workspace-based (`az monitor app-insights component show … --query ingestionMode` = `LogAnalytics`), query the backing Log Analytics workspace directly (`az monitor log-analytics query --workspace <customerId-guid>`, tables `AppEvents`/`AppTraces`/`AppRequests`, columns `Name`/`TimeGenerated`) — the classic App Insights query API returns **empty** for workspace-based data. Always pass a window (`--offset 14d` or UTC start/end) or the default minutes-wide span returns a false empty.
- **Snowflake cost/latency** — `snow sql` on `ACCOUNT_USAGE.QUERY_HISTORY` with `TIMEZONE='UTC'` (windows are read in session TZ otherwise); split COMPILATION vs EXECUTION time before attributing scan cost.
- **Coverage %** — the SonarCloud project `component_tree` on the merged branch, not local Cobertura (they diverge; CI-wiring gaps make local ≠ Sonar).
- **PR-level facts** (lines/files/count added) — `gh pr diff <n> --repo <repo>`; cheapest and most definitive.
- **Pipeline timing** — the ADO/GitHub run history for the pipeline, not the estimate.

{If a number can only come from an external or one-time source (a cost-portal CSV export, a pre-deploy prod snapshot), say so explicitly — that flags it up front as not-re-derivable, so nobody later mistakes a projection or a stale figure for a live measurement.}

### Risks & Mitigations
- {Risk} → {Mitigation}

### Implementation Plan
{Vertical-slice steps as a dependency graph (C6). For each step: files touched, tests it needs (level by risk + pyramid), and its definition of done.}
- [ ] **Step 1** — {goal}. Files: {paths}. Tests: {what}. Done when: {verifiable condition}.
- [ ] **Step 2** — {goal}. Files: {paths}. Tests: {what}. Done when: {verifiable condition}.
Dependencies: {which steps are sequential (A before B) vs parallel (no edge)}. Critical path: {longest dependent chain}.

**Step-sizing sanity check** (per `workspace/kb/general/engineering-heuristics.md → Planning`): a single step should stay agent-sized — roughly ≤5 files, acceptance stateable in ≤3 bullets. Subdivide any step that trips a signal: touches 2+ subsystems, needs >~2h, or has "and" in its goal. Classify parallelism explicitly: independent slices/tests/docs run parallel; migrations, shared-state, and dependency chains stay sequential; shared API-contract changes need coordination. Order risk-first — put the most uncertain step early so it fails fast, not after the safe work is sunk.

**Wide-refactor exception** (per `workspace/kb/general/workflow.md 2026-07-10 → to-tickets`): a mechanical change with codebase-wide blast radius (rename, signature change, dep swap) is NOT a vertical slice — forcing it into one produces a giant unreviewable step. Sequence it **expand → migrate → contract**: add the new form beside the old, migrate call sites in blast-radius-sized batches (per package/dir, each independently green), then delete the old form last. Represent each phase as its own step with the contract step blocked by every migrate batch.

### ETA Estimate
Derived from the Implementation Plan steps above per `.claude/docs/eta-estimation.md`. Tag each step with its dominant lane (🤖 AI / 🔌 Env / 🧠 Human / ✅ Verify) and a rough size bucket (S/M/L/XL/XXL), then roll up to a confidence range.

| Step / subtask | Lane | Size | Notes |
|---|---|---|---|
| {step} | 🤖 AI | S | {what drives it} |

- **Where the time goes:** {which lanes dominate; if 🔌 / 🧠 / ✅ dominate, name the real bottleneck — fast code ≠ fast task}
- **Optimistic:** X — **Realistic:** X — **Pessimistic:** X (widen the spread on AI-heavy steps)
- **Estimate risks:** {the unknowns that widen the spread; cross-reference Risks & Mitigations}

### PR Plan
Target PR count: 1
Review package: {single coherent PR by default; if more than one, justify each PR against the split criteria}
Split trigger: {specific condition that would force a split during /nase:fsd, or "none expected"}

### Open Questions
- {Anything unresolved — tracked for follow-up}
- {Inline ambiguities use [NEEDS CLARIFICATION: …] markers (C3); implementation is gated on zero markers remaining}
```

For **initiatives**: include a decomposition section listing sub-efforts with dependency order, then group them into the smallest review package. Each sub-effort carries its own concreteness, acceptance criteria, and step plan. A sub-effort is not automatically a PR.

## Phase 4b: Self-Review Loop (max 3 iterations)

Run an internal quality gate before writing the effort doc.

**Scoring is done by a fresh-context subagent, not the main thread.** Scoring your own draft in the same context that wrote it is self-approval — the same blind spots that produced a gap will score past it. Spawn one read-only subagent per iteration (role `verifier` per `.claude/roles.yaml`, tools: Read/Grep/Glob). Give it ONLY: the draft design text, the Quality Criteria table, and the KB/file references the design cites (so it can spot-check Grounding claims). Do NOT include your design reasoning, prior iteration scores, or which option was chosen over what. It returns per-criterion PASS/WEAK/FAIL plus the specific gap for each non-PASS. The main thread owns revisions.

**For each iteration:**

1. **Score** the draft design via the fresh-context subagent against every row in the Quality Criteria table (see below). For each criterion: PASS, WEAK, or FAIL. Have the subagent read the design through the **persona lenses** in `.claude/docs/design-grill-mode.md → Persona Lenses` (architect / PM / senior-eng / SRE / security) — a gap one persona catches that the criteria table misses still counts as a WEAK/FAIL with the persona named.

2. **If any FAIL or 2+ WEAK**: identify the specific gaps and revise the design in-place. Common fixes:
   - Specificity FAIL → add concrete numbers, file paths, line counts
   - Testability FAIL → rewrite success criteria with verifiable conditions
   - Grounding FAIL → add KB/file references
   - Scope clarity FAIL → add explicit "Out of scope" items
   - Risk coverage FAIL → add missing mitigations
   - KB alignment FAIL → reconcile with documented constraints
   - Elegance FAIL → simplify the design shape, remove awkward glue, reduce moving parts, or choose the option that fits the existing model more naturally
   - Reviewability FAIL → reduce PR count, add a review guide, or justify the split with a real merge/release/owner boundary
   - Implementation readiness FAIL → add concrete file paths/signatures/data models, per-step tests + done-conditions, and resolve or mark `[NEEDS CLARIFICATION]`
   - Research grounding FAIL → add the doc URL / source / issue and pin the version; if still uncitable, mark the claim `gap: {reason}` — abstain by default (a `gap` is better than a fabricated citation), and do not let a `gap`-marked claim serve as evidence for any other claim in the same doc
   - Repro & root cause FAIL → add the repro (or document why it won't reproduce) and trace the fix to the originating cause
   - ETA grounded FAIL → add the `### ETA Estimate`, tie each line to a plan step, classify lane/size, and give a rough confidence range (or a single realistic line for quick-fix)

3. **If all PASS or at most 1 WEAK**: exit the loop and proceed to Phase 5.

4. **After 3 iterations**: proceed regardless — diminishing returns. Note any remaining WEAK items as open questions in the design.

The user never sees the intermediate review scores — they just get a higher-quality design on the first presentation. If the design needed significant revision (2+ iterations), briefly note what was caught: "Self-review caught X and Y — fixed before presenting."

## Phase 5: Write Design Doc + Track

After the design passes self-review (Phase 4b), write the effort doc directly — do not ask for approval first. The user reviews the written artifact, not a verbal presentation. Follow `.claude/docs/effort-lifecycle.md → Design Creation`; build the proposed full `workspace/efforts/{slug}.md` and `workspace/tasks/todo.md` content under `workspace/tmp/`, stage both with `workspace-write-guard.py stage`, show the helper diff, then apply with `workspace-write-guard.py apply`.

**5a. Write design doc:**
Save to `workspace/efforts/{slug}.md` (create `efforts/` dir if missing):
```markdown
---
status: planned
created: {YYYY-MM-DD}
scope: {quick-fix|feature|initiative|exploration}
repo: {repo-name or "multiple"}
# optional (see .claude/docs/effort-lifecycle.md → Dependency & Discovery Fields):
# blocked-by: {effort slug | PR URL | Jira key}   — add + set status: blocked when this waits on something
# discovered-from: {effort slug | PR URL | incident ref}   — add when this was spun off from other work
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

One effort = one file. Never spawn per-phase sidecar docs (`{slug}-phase-N.md`); append all progress to this single doc per `.claude/docs/effort-lifecycle.md → Single-File Invariant`.

**5c. Create Jira ticket** (if user wants — ask via AskUserQuestion):
```
question: "Create a Jira ticket for this effort?"
header: "Jira"
options:
  - label: "Yes"                , description: "Create ticket with design summary"
  - label: "No"                 , description: "Track in workspace only"
```
If yes: use the project key from the repo's KB file (or ask the user). Issue type: Task or Story. Set summary to the effort title, description to the design summary, and add a note linking back to the effort doc path. Set `contentFormat: "markdown"` on the `createJiraIssue` call (per `.claude/docs/jira-write-pattern.md` — the ADF default breaks the token sha) and include it in the payload before hashing. Immediately before calling `createJiraIssue`, write a fresh one-shot token:
```json
{
  "tool_name": "{actual createJiraIssue tool name}",
  "created_at": "{UTC ISO timestamp}",
  "payload_summary": "Create {PROJECT} issue for {Title}",
  "payload_sha256": "{sha256 of canonical createJiraIssue tool_input}"
}
```
`createJiraIssue` may omit `issue_key` because the issue does not exist yet. Do not reuse this token for any follow-up Jira mutation.

**5d. Stop:**

Design doc saved. No follow-up prompt. Effort surfaces in `/nase:today`. User decides next action.

## Lifecycle Updates (by other skills)

Effort lifecycle state is owned by `.claude/docs/effort-lifecycle.md`; this command creates the initial doc, while `/nase:fsd`, `/nase:prep-merge`, and `/nase:wrap-up` follow that shared contract for later updates.

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
| **Elegance** | Design has a coherent shape: minimal moving parts, clear ownership boundaries, natural fit with existing patterns, and no clever workaround where a simpler model exists |
| **Reviewability** | Default to one PR; any multi-PR plan cites the split criterion, dependency order, and why review is easier than one coherent PR |
| **Implementation readiness** | A junior could execute with zero design decisions: exact file paths, signatures, data models, API contracts where applicable; step plan with per-step tests + done-condition; zero unresolved `[NEEDS CLARIFICATION]` markers |
| **Research grounding** | External claims about library/SDK/platform behavior cite a doc URL, dependency source, or issue — not memory; uncited claims are marked `gap` and do not support other claims; versions pinned |
| **Repro & root cause** (bug-shaped only) | A reproduction (or documented failure to reproduce) exists, and the fix targets the originating cause, not the symptom |
| **ETA grounded** | An `### ETA Estimate` exists, ties to the Implementation Plan steps (not a free-floating guess), and gives a rough lane/size-based confidence range — or a single realistic line for quick-fixes |

## Notes

- **KB is the unfair advantage** — always read it before asking the user. The more you know upfront, the fewer questions you need to ask.
- **Scale to scope** — a quick fix gets a 3-line design. An initiative gets decomposition. Don't over-plan small things.
- **Design doc is the durable artifact** — it persists across sessions, visible in `/nase:today`, updated by downstream skills.
- **If things change during implementation** — update the effort doc. It's a living record, not a frozen spec.
- **Language**: use the **conversation language** (from `config.md`) for all interview dialogue. Write the design doc in the **output language**.
