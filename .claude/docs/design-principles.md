# Design Principles Framework — Shared Reference

Canonical principle set and the **dynamic ordering** that decides which tradeoff to weigh first. Used by `/nase:design` (design-time), `/nase:fsd` Phase 3.6 (implementation-time), and `/nase:simplify` (cleanup-time). One source of truth so the three skills stay aligned.

The principle set is the same everywhere; what changes is the **order** you apply them, because the order changes which tradeoff wins when two principles pull against each other. Lead with the principle that matters most for the work in front of you.

## The principles

| Principle | What it means in practice |
|-----------|--------------------------|
| **First Principles** | Strip back to core requirements. What is the actual problem? Which assumptions can be challenged? |
| **YAGNI** | Build only what is needed now. No speculative extensibility. |
| **KISS** | Prefer the simpler design. Complexity is a liability — justify it. |
| **SOLID** | When modeling components/modules: single responsibility, open/closed, dependency inversion. |
| **DRY** | Reuse what the codebase / KB already has; don't reinvent. Reuse-first before any new construct. |

**Elegance** is a design-phase dimension layered on top of these (a coherent shape: fewer moving parts, clear boundaries, natural fit with existing patterns, no cleverness for its own sake). It is not in the core implementation ordering below; `/nase:design` weaves it in (typically right after KISS) when evaluating design options. Implementation and cleanup work from the five core principles.

## Dynamic ordering by scenario

Classify the work, then lead with the matching order:

| Scenario | Examples | Ordering |
|----------|----------|----------|
| **Architecture / requirements analysis (Project Kickoff)** | system redesign, new service, cross-cutting concern | First Principles → YAGNI → KISS → SOLID → DRY |
| **New feature / incremental development** | adding an endpoint, extending a handler, new config option | YAGNI → KISS → SOLID → DRY → First Principles |
| **Small function / utility** | helper, formatter, parser, extension method | KISS → DRY → YAGNI → SOLID → First Principles |
| **Complex business component / OO modeling** | domain entity, stateful service, multi-class hierarchy | First Principles → SOLID → YAGNI → KISS → DRY |

Why the orders differ:

- **Kickoff** leads with First Principles — at this altitude the wrong frame is the expensive mistake; nail the real problem before anything else, then resist gold-plating (YAGNI).
- **Incremental** leads with YAGNI/KISS — the frame already exists; the risk is adding speculative surface to a working system.
- **Small utility** leads with KISS/DRY — the only real questions are "is it simple?" and "does it already exist?"; First Principles is overkill for a formatter.
- **Complex component** leads with First Principles then SOLID — get the model right, then enforce clean responsibility boundaries before simplifying.

## How callers use this

- **`/nase:design`** — declare the ordering as the lens before presenting options; evaluate each option by which principles it honors or violates, with Elegance as an explicit dimension.
- **`/nase:fsd` Phase 3.6** — classify `task_type`, store the matching `principle_order`, and apply the lead principle during Green (implement only what the principle requires) and the full order during Refactor.
- **`/nase:simplify`** — use the order to decide what to cut; the reuse-first ladder operationalizes DRY + YAGNI.

The classification is a lens, not a cage — if a task genuinely spans two scenarios, lead with the higher-altitude one and note the blend.
