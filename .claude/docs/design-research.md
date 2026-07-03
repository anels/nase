# Design Research & Plan Gates — Shared Reference

Used by `/nase:design` (Phase 1–4), `/nase:fsd` Phase 3.5, `design-auto-mode.md`, and `design-grill-mode.md`.
Three parts: **A. External Research** (look outward before designing), **B. Plan-Phase Gates** (what to prove before committing to an approach), **C. Implementation-Readiness Spec** (what makes a plan junior-implementable). Apply only the parts that fit the scope — a quick-fix touches A lightly and skips most of B.

The contract throughout: **execute, don't narrate. Every technical claim cites a path, URL, or command output — never memory.** A claim you cannot restate in your own words does not enter the design (comprehension gate).

---

## Part A: External Research

The base skill already gathers internal context (codebase, KB, Jira). This part adds the **outward** look the user asked for: official docs, dependency source, issue trackers, forums, blogs, best practices. Run it in Phase 1 after internal context, scaled to scope.

### When to run

- **feature / initiative / exploration**, or any approach that leans on an external library, framework, SDK, API, or platform behavior → run the ladder.
- **quick-fix** in a well-understood area → skip unless an external dependency's behavior is in doubt.

### Source ladder (in priority order)

Authoritativeness decreases as you go down. Stop when you have enough to design with confidence; don't burn the whole ladder on a settled question.

1. **Official documentation** — the vendor/project's own docs at the **version you actually run**. Tool routing:
   - Microsoft / .NET / Azure surface → `ms-learn` MCP (`microsoft_docs_search` → `microsoft_docs_fetch`). See `ms-learn-grounding.md` for the trigger list and match/refine/conflict handling.
   - Any other library / framework / SDK / CLI → `context7` MCP (`resolve-library-id` → `query-docs`). Prefer this over web search for library docs — training data drifts.
   - Anything not in those two → `WebSearch` for the official doc URL, then `WebFetch` it.
2. **Dependency source + changelog** — docs describe intended behavior; source reveals real behavior, edge cases, and version drift. Pin the exact version in use (read the lockfile / package manifest first), then read the relevant source or release notes. Cite `repo@version:path:line` or the changelog entry.
3. **Issue trackers** — GitHub/GitLab issues are the fastest signal for known bugs, gotchas, and "wontfix" decisions. Search the dependency's tracker for the symptom or API name. A linked issue often beats every blog post.
4. **Curated Q&A** (StackOverflow et al.) — useful for concrete patterns, but treat answers as leads to verify against docs/source, not as truth. Cite the question URL and the accepted/high-vote answer.
5. **Engineering blogs / best-practice write-ups** — last and least authoritative; opinionated and often stale. Use for framing and approach ideas, never as the sole basis for a load-bearing decision.

### Grounding discipline

- **Cite or drop.** Every external fact in the design carries a URL or `path:line`. Uncited "X is faster than Y" claims get cut or marked `unverified`.
- **Pin the version.** "The default timeout is N" is meaningless without the version it's true for. State both.
- **Comprehension gate.** If you cannot restate a borrowed pattern / answer in your own words, do not put it in the design. Copying a StackOverflow or AI answer you can't explain is how subtle bugs enter.
- **Debias pass.** Before locking the leading approach, spend one explicit pass on:
  - **Disconfirming evidence** — "what would have to be true for this to be the *wrong* choice?" Check each against what you found.
  - **NIH check** — was an existing library / KB pattern / platform feature evaluated on merit, or dismissed because it's external?
  - **Anchoring** — were ≥2 independent options generated before evaluating any one, or did the first idea set the frame?

### Output

A short **research log** folded into the design's grounding (not a separate artifact unless large): each load-bearing claim → its source. This is what later phases and reviewers spot-check. If research surfaced an unknown that blocks a decision, mark it `[NEEDS CLARIFICATION: …]` per Part C.

---

## Part B: Plan-Phase Gates

Before presenting options (Phase 3) and before committing to a design (Phase 4), run the gates that fit the work. Each gate is "prove it, or explicitly flag that you couldn't." Skipping a gate silently is the failure mode.

### B1. Bug-repro gate (bug-shaped work only)

If the work is fixing a defect: **you cannot design a fix for a bug you cannot reproduce.**

- Establish a reliable reproduction — ideally a **failing automated test** or a **minimal reproducible example** (MRE): minimal, complete, self-contained, triggers the bug unmodified. Pin environment (exact versions, OS, config) and record expected-vs-actual including error text.
- Building the MRE is itself a root-cause tool — stripping noise often surfaces the cause.
- If the bug is intermittent/non-reproducible: capture richer state (logs, traces, timing, concurrency), vary one factor at a time to make it deterministic before designing. If it still won't reproduce, say so explicitly and treat the fix as a hypothesis, not a known cure.
- Record the repro (or the failure to get one) in the design's Context section.

### B2. Root-cause gate (bug-shaped work only)

Design the fix for the **originating** cause, not the surface symptom — symptom-patching guarantees recurrence.

- Pick the technique that fits the shape: **5 Whys** for linear causation; **Fishbone/Ishikawa** when many factors span categories (system / code / data / process / environment); **Fault Tree** for interconnected or safety-critical failures.
- Reach a cause whose removal prevents recurrence. Look for systemic factors (missing test, weak invariant, process gap), not individual blame.
- Record the root cause and the contributing factors before proposing the fix.

### B3. Prod-data / validation gate

Decide, explicitly, whether this design needs evidence from production before committing — don't optimize for assumed behavior.

- Ask: does the design rest on an assumption about **scale, usage, traffic shape, or current behavior**? If yes, validate against telemetry / logs / metrics (App Insights, Kusto, dashboards, prod queries) before locking the approach.
- Confirm the assumed consumer/usage actually exists. "In use" ≠ "needs this change" — a feature may be live yet have no real consumer for your specific change.
- If no data is available, **flag the assumption** (`[NEEDS CLARIFICATION]` or a Risk) rather than designing on a guess.
- For telemetry/sampling-touching designs, also run the AppInsights pre-merge protocol the base skill's Phase 2d already names.

### B4. Unit-test-gap analysis

Before deciding what tests the change needs, know what exists.

- Map current coverage of the area being changed: which behaviors are tested, which are not. Run coverage on the diff/area if available; otherwise read the test files.
- Name the gaps the change exposes or creates. The Implementation Plan (Part C) will assign tests per step against these gaps.
- A coverage *number* is not the goal — map coverage to behavioral risk, then target the high-risk untested branches.

### B5. Weighted decision matrix (when ≥2 real options compete)

Upgrade plain pros/cons to a structured comparison so the choice is auditable, not gut-feel.

- Options as rows; **weighted criteria** as columns (e.g. quality, simplicity/complexity, robustness, scalability, KB/pattern alignment, elegance, maintainability, performance, security, review/PR cost, risk). Weight by what matters for *this* design. **Do not add a "development cost / effort / time-to-build" column** — build cost is not a decision weight (see `/nase:design` → *What a technical decision optimizes for*). Runtime/operational/maintenance cost belongs under robustness/maintainability; review/PR cost stays as a reviewability concern.
- Score each cell; the recommendation is the weighted result — but state it, don't hide behind the math.
- For architecture-level choices, prefer an **ATAM-style utility tree**: turn quality goals into testable scenarios, surface risks / sensitivity points / explicit trade-offs.
- **Spike the unknowns.** If an option hinges on a risky unknown, prototype/spike it rather than deciding on paper.
- Run a quick **sensitivity check**: would a reasonable re-weighting flip the winner? If yes, the decision is fragile — say so.

---

## Part C: Implementation-Readiness Spec

This is what makes a design **junior-implementable**: a competent junior engineer (or `/nase:fsd`) can execute it with zero remaining design decisions. Apply the depth that fits the tier (see C7).

### C1. Goals AND Non-Goals (separate, required)

State Goals, then **Non-Goals** — reasonable things explicitly cut from scope (not negations of goals). Non-goals are the highest-leverage scoping tool and the most-omitted. A silent omission becomes an implementer's wrong guess.

### C2. Concreteness — replace intent with artifacts

The Design / Implementation Plan names, concretely:

- **Exact file paths** to create or change (not "the auth module" — `src/auth/middleware.ts`).
- **Function / method signatures** for new or changed surfaces (name, params + types, return type).
- **Data models** — schema/struct/type changes with field names and types.
- **API contracts** — endpoint, method, request/response shape, status codes, error modes.
- **Pseudocode** for any non-obvious logic.
- **Numbers, not adjectives** — every threshold, default, format, limit, and target stated as a value ("p99 < 200ms", "$29/mo", "retries 3×") — never "fast", "scalable", "competitive".

### C3. `[NEEDS CLARIFICATION]` markers + proceed-gate

Mark every unresolved ambiguity inline: `[NEEDS CLARIFICATION: question]`. **Implementation is gated on zero markers remaining.** In `--auto`, unresolved markers become the end-of-run `AskUserQuestion` batch / Human Input Required rows, so ambiguity is resolved before implementation.

### C4. Acceptance criteria — Given-When-Then, one assertion per behavior

Write success criteria as testable scenarios: `Given {precondition}, When {action}, Then {observable outcome}`. The *Then* asserts an observable, binary result ("returns 200", "balance is £42") — never a vague qualifier. Declarative, domain language, 3–5 steps. Each maps directly to a test. Keep the AC-vs-DoD split clear: AC are per-step conditions; DoD is the design-wide done bar (build/lint/test green, docs updated, etc.).

### C4b. Validation — the runnable way to get the real number

An acceptance criterion states *what* the outcome is; validation states *how a future reader obtains the real value* — the data source plus the exact query/command. This is the difference between a design that can be verified and one whose claims can only be restated. Downstream (`/nase:fsd` verify, `/nase:effort-rollup`) re-derives real numbers from this section; without it they fall back to trusting the doc, which is how projections and stale figures get reported as measured fact. For each numeric goal / metric or behavior criterion, give `{source} : {exact query/command} — expect {value}`. Prefer the source of truth over a proxy (query the LAW that backs a workspace-based App Insights, not the classic API that returns empty for it; SonarCloud `component_tree`, not local Cobertura; `ACCOUNT_USAGE.QUERY_HISTORY` with `TIMEZONE='UTC'`; `gh pr diff` for PR-level facts). If a value can only come from a one-time or external source (a portal CSV, a pre-deploy prod snapshot), say so — flagging "not re-derivable" up front is itself the honest validation. A criterion with no runnable check is a design gap, not a formatting choice.

### C5. RFC 2119 normative keywords

Use **MUST / SHALL** (binding), **SHOULD / RECOMMENDED** (justify exceptions), **MAY / OPTIONAL** (advisory), in caps, to disambiguate which parts of the design are required vs. advisory. Stops a reader from treating a hard constraint as a suggestion.

### C6. Step plan as a dependency graph

Not just an ordered list:

- Decompose into **vertical slices** (each cuts through layers to deliver observable value and is independently testable) — not one task per layer.
- Model dependencies as a **DAG**: mark which steps are **sequential** (edge: producer before consumer) and which can run **in parallel** (no edge between them). Note the **critical path** (longest dependent chain = true minimum duration); non-critical branches have slack and are the parallelizable ones.
- For **each step**: the files it touches, the **tests it needs** (level chosen by risk + test pyramid: many unit, fewer integration, few E2E; contract tests at shared/external seams), and its **definition of done** (the concrete, verifiable condition that closes it).
- This feeds `/nase:fsd`'s phase decomposition directly (`fsd-phase-decomposition.md`) — write it so fsd can lift phases out without re-deriving them.

### C7. Tier the depth to scope

Don't force a heavy spec on a small change:

- **quick-fix** → a few lines: what, where (file:line), the one acceptance check. Skip the full template.
- **feature** → full template, C1–C6 applied at normal depth.
- **initiative** → full template + sub-effort decomposition with dependency order; each sub-effort carries its own C2/C4/C6.
