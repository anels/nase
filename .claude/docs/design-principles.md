# Design Principles Framework - Shared Reference

Canonical principle set and the **dynamic ordering** that decides which tradeoff to weigh first. Used by `/nase:design` (design-time), `/nase:fsd` Phase 3.6 (implementation-time), and `/nase:simplify` (cleanup-time). One source of truth so the three skills stay aligned.

The principle set is the same everywhere; what changes is the **order** you apply them, because the order changes which tradeoff wins when two principles pull against each other. Lead with the principle that matters most for the work in front of you.

## The principles

| Principle | What it means in practice |
|-----------|--------------------------|
| **First Principles** | Strip back to core requirements. What is the actual problem? Which assumptions can be challenged? |
| **YAGNI** | Build only what is needed now. No speculative extensibility. |
| **KISS** | Prefer the simpler design. Complexity is a liability - justify it. |
| **SOLID** | When modeling components/modules: single responsibility, open/closed, dependency inversion. |
| **DRY** | Reuse what the codebase / KB already has; don't reinvent. Reuse-first before any new construct. |

**Elegance** is a design-phase dimension layered on top of these (a coherent shape: fewer moving parts, clear boundaries, natural fit with existing patterns, no cleverness for its own sake). It is not in the core implementation ordering below; `/nase:design` weaves it in (typically right after KISS) when evaluating design options. Implementation and cleanup work from the five core principles.

## Merge gate for duplicated code

DRY above means reuse what exists. It does not mean merge look-alike code. Duplication is cheap to remove later, and a wrong abstraction is expensive to undo. Copies are one thing only when a single decision by a single owner would change all of them at the same time.

- **Wait for three:** leave the second copy inline and merge once the pattern repeats three times for the same reason. Look-alike code with different owners is coincidental duplication, so leave it.
- **Test:** "who would I consult about this change, and would every copy change together?" Mixed answers mean coincidence, not duplication.
- **Smell:** props or parameters like `mode`, `variant`, `isSpecial`, or one new flag per new requirement. Unrelated things were merged.
- **Recovery:** inline the shared code back into each caller, then extract only the part that shares a reason to change.
- **Share from day one:** primitives, design tokens, accessibility behavior, and logic a standard dictates need no waiting period.

Source: [Stack Overflow blog, 2026-11-05](https://stackoverflow.blog/2026/11/05/don-t-build-the-reusable-component-yet/) - a heuristic from one team's frontend work, not measured.

## Dynamic ordering by scenario

Classify the work, then lead with the matching order:

| Scenario | Examples | Ordering |
|----------|----------|----------|
| **Architecture / requirements analysis (Project Kickoff)** | system redesign, new service, cross-cutting concern | First Principles → YAGNI → KISS → SOLID → DRY |
| **New feature / incremental development** | adding an endpoint, extending a handler, new config option | YAGNI → KISS → SOLID → DRY → First Principles |
| **Small function / utility** | helper, formatter, parser, extension method | KISS → DRY → YAGNI → SOLID → First Principles |
| **Complex business component / OO modeling** | domain entity, stateful service, multi-class hierarchy | First Principles → SOLID → YAGNI → KISS → DRY |

Why the orders differ:

- **Kickoff** leads with First Principles - at this altitude the wrong frame is the expensive mistake; nail the real problem before anything else, then resist gold-plating (YAGNI).
- **Incremental** leads with YAGNI/KISS - the frame already exists; the risk is adding speculative surface to a working system.
- **Small utility** leads with KISS/DRY - the only real questions are "is it simple?" and "does it already exist?"; First Principles is overkill for a formatter.
- **Complex component** leads with First Principles then SOLID - get the model right, then enforce clean responsibility boundaries before simplifying.

## Solution selection

Propose 2-3 materially distinct options. At least one is system-level and fixes the root cause.

A workaround is recognized by these smells:

- swallowed exceptions
- special-case branches
- sleeps or retries that hide timing
- one-off flags
- suppressed lint or test failures
- anything that treats a symptom

A workaround is allowed only with a stated reason it is not treating a symptom, for example legacy-data compatibility. In `--auto` runs and in fsd, choose the best-evidenced option without asking the user to pick. Interactive `/nase:design` keeps its approach-choice checkpoint, and a cross-repo or security-shaped architecture choice is presented as a recommendation for approval. Development cost informs the ETA, not the selection.

## Over-engineering check

Every new abstraction, parameter, file, flag, or branch must trace to a success criterion or the Intent. If it traces to neither, remove it.

## Module shape

Use these four terms when a design adds or reshapes a module, and use them consistently. Prefer them over "component", "service", or "boundary" when you describe that module.

- **Interface** - everything a caller must know, including invariants, ordering, error modes, required config, and performance. It is more than the signature.
- **Depth** - how much behavior sits behind a small interface. A deep module is good. A shallow one has an interface nearly as complex as its body.
- **Seam** - the place where behavior can change without editing there. It is where an interface lives.
- **Adapter** - a thing that fills the interface at a seam.

Checks to run on the chosen option.

- **Deletion test.** Imagine deleting the module. If complexity vanishes, it was a pass-through, so cut it. If complexity reappears in several callers, it earns its place.
- **One adapter is a hypothetical seam, two is a real one.** Add a seam only when something varies across it, such as a production adapter and a test fake. This is YAGNI applied to seams.
- **The interface is the test surface.** A test that must reach past the interface says the module has the wrong shape. Write new tests at the interface and delete the old unit tests they replace, instead of keeping both.
- **The dependency decides the test.** In-process code is tested directly. A dependency with a local stand-in (in-memory filesystem, SQLite) is tested with the stand-in. A remote service you own gets a port with a production adapter and an in-memory one. A true external service gets a port with a mock.

Depth means leverage at the interface, not a ratio of implementation lines to interface lines, which rewards padding.

## How callers use this

- **`/nase:design`** - declare the ordering as the lens before presenting options; evaluate each option by which principles it honors or violates, with Elegance as an explicit dimension. When an option adds or reshapes a module, run the Module shape checks on it.
- **`/nase:fsd` Phase 3.6** - classify `task_type`, store the matching `principle_order`, and apply the lead principle during Green (implement only what the principle requires) and the full order during Refactor.
- **`/nase:simplify`** - use the order to decide what to cut; the reuse-first ladder operationalizes DRY + YAGNI, and the merge gate decides which duplicates to consolidate.
- **`/nase:fsd` Phase 6.4 review** - apply Solution selection and the Over-engineering check to the diff: a workaround without a stated reason, or an addition that traces to no success criterion or the Intent, is a finding.
- **`/nase:address-comments`** - apply the same two checks to each reviewer suggestion before accepting it (cause vs symptom, scope guard).

The classification is a lens, not a cage - if a task genuinely spans two scenarios, lead with the higher-altitude one and note the blend.
