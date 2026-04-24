---
name: nase:tech-debt-audit
description: "Systematically audit a repository for tech debt, architecture health, best-practices compliance, and modernization opportunities — producing a structured inventory with severity/effort/ROI scoring written to a dedicated KB file. Use when onboarding to a new repo, before a planning cycle, or when asked \"what tech debt do we have?\", \"architecture review\", \"are we following best practices\", or \"what can we modernize\"."
---

Systematically audit a repository for tech debt, architecture health, best-practices compliance, and modernization opportunities — producing a structured inventory with severity/effort/ROI scoring written to a dedicated KB file.

**Input:** $ARGUMENTS — repo name or path (resolved via `.local-paths` and `workspace/kb/.domain-map.md`)

## Input Guard

If $ARGUMENTS is empty or blank:
- Use AskUserQuestion to ask: "Which repo should I audit?" with options from `workspace/context.md` repos, plus "Other — I'll type the path".
- If the user cancels: stop.

## When to use

When you need a comprehensive view of a repo's health — not just "what's messy" but prioritized by impact. Triggers: "audit tech debt", "what should we clean up", "tech debt inventory", "architecture review", "are we following best practices", "what can we modernize", or before a sprint planning session where cleanup work needs justification.

## Steps

1. **Resolve the repo** — follow `.claude/docs/repo-resolution.md` Part 1 to get the local path. Read the repo's existing KB file (from `.domain-map.md`) for known constraints and architecture.

2. **Scan the codebase** — read key files (entry points, core services, config, CI pipelines, package manifests). Look for:
   - Dead code / unused dependencies
   - Duplicated logic (copy-paste patterns across files)
   - Hardcoded values that should be config
   - Missing error handling at system boundaries
   - Outdated dependencies with known CVEs or major version gaps
   - Inconsistent patterns (e.g., some endpoints use middleware, others don't)
   - TODO/FIXME/HACK comments with context
   - Test gaps in critical paths
   - Silently skipped parameterized tests: for .NET repos, compare `dotnet test --list-tests | wc -l` against `[TestMethod]`/`[Fact]` attribute count. MSTest `[DataRow]` configurations can silently skip execution — CI stays green but tests never run.
   - CI stale binary patterns: check install/download steps in pipeline YAML for existence-only guards (e.g. `if (Test-Path binary)` or `test -f binary`) instead of version guards (`binary --version`). Stale binaries persist on self-hosted agents between runs and cause silent version drift.
   - Pipeline inefficiencies (redundant stages, unpinned refs)

3. **Architecture review** — step back from individual files and evaluate structural health:
   - **Layering violations** — does business logic leak into controllers/API handlers? Do data access patterns bypass the intended service layer?
   - **Dependency direction** — do lower-level modules depend on higher-level ones? Are there circular dependencies between projects/packages?
   - **Separation of concerns** — are there "god classes" or "god functions" that do too much? Are cross-cutting concerns (logging, auth, validation) scattered instead of centralized?
   - **API surface** — are internal types exposed publicly? Are DTOs reused as domain models (or vice versa)?
   - **Scaling bottlenecks** — single-threaded processing where parallelism is possible, in-memory state that prevents horizontal scaling, missing queue/async patterns for heavy work
   - **Configuration sprawl** — settings scattered across env vars, appsettings, code constants, and DB rows with no single source of truth

4. **Best practices compliance** — check whether the repo follows its own documented standards and ecosystem conventions:
   - **Repo-level docs**: read `CLAUDE.md`, `CONTRIBUTING.md`, `docs/`, and any `best-practices.md` or `coding-guidelines.md` in the repo. Compare actual code against what these docs prescribe — gaps between documented standards and reality are high-value findings.
   - **Framework/ecosystem conventions**: for .NET repos check alignment with Microsoft's recommended patterns (Options pattern, dependency injection, middleware pipeline). For Node/TS check ESLint/Prettier config consistency, module structure. For Go check standard project layout, error handling idioms.
   - **KB-documented patterns**: read the repo's KB file for established patterns and constraints — verify the codebase still follows them (e.g., KB says "all queries go through repository layer" — grep for direct DB access in controllers).

5. **Modernization opportunities** — identify where newer tools, libraries, or language features could replace legacy approaches:
   - **Language features**: older C# missing nullable reference types, pattern matching, records, or `IAsyncEnumerable`. Older TypeScript missing satisfies, const assertions, or template literal types. Older Python missing `match`, `TypeAlias`, or `dataclasses`.
   - **Library upgrades**: check package manifests for libraries with newer major versions that offer meaningful improvements (e.g., EF Core 6→8 for compiled queries, Serilog structured logging replacing `Console.WriteLine`, Polly v8 circuit breaker patterns).
   - **New ecosystem tools**: could `pnpm` replace `npm` for faster installs? Could `Aspire` simplify local dev orchestration? Could `testcontainers` replace mocked integration tests? Would `OpenTelemetry` auto-instrumentation replace manual tracing?
   - **Infrastructure**: could a multi-stage Docker build reduce image size? Could GitHub Actions caching cut CI time? Is there a managed service that replaces self-hosted infrastructure?
   - **Deprecation risk**: flag libraries that are unmaintained, archived, or have announced EOL — these are ticking time bombs even if they work today.

   Note: only flag opportunities with a concrete benefit (faster builds, fewer bugs, reduced maintenance) — not "this is newer so use it." Each suggestion should state what it replaces and why the switch is worth the effort.

6. **Categorize findings** — group by area:
   - **Security** — vulnerabilities, missing auth checks, secret handling
   - **Reliability** — error handling gaps, missing retries, race conditions
   - **Architecture** — layering violations, circular dependencies, god classes, scaling bottlenecks
   - **Maintainability** — duplication, dead code, unclear abstractions, best-practices drift
   - **Modernization** — outdated libraries, missed language features, infrastructure improvements
   - **Performance** — N+1 queries, missing caching, unoptimized pipelines
   - **Developer Experience** — CI speed, test reliability, onboarding friction

7. **Score each finding** — for every item, assess:
   - **Severity** (1-5): how bad is this if left unfixed?
   - **Effort** (S/M/L/XL): how long to fix?
   - **ROI** (high/medium/low): severity relative to effort — high-severity + low-effort = high ROI

8. **Write to KB** — create or update `workspace/kb/projects/tech-debt/{repo}-tech-debt.md`:
   ```markdown
   # {Repo Name} — Tech Debt Audit
   <!-- Last updated: YYYY-MM-DD -->

   ## Summary
   {2-3 sentence overview: total findings, top concerns, recommended priority}

   ## Architecture Assessment
   {Brief structural health summary — layering, dependency direction, key bottlenecks}

   ## Best Practices Compliance
   {Which documented standards are followed vs. drifted — cite the source doc}

   ## Modernization Opportunities
   {Top upgrades/replacements with concrete benefits — libraries, language features, infra}

   ## High ROI (fix first)
   ### {Finding title}
   **Severity:** N/5 | **Effort:** S/M/L/XL | **Category:** {category}
   {Description + specific file/line references}

   ## Medium ROI
   ...

   ## Low ROI (track but defer)
   ...
   ```

9. **Register in domain map** — if this is a new KB file, add an entry to `workspace/kb/.domain-map.md`:
   ```
   - {repo}-tech-debt → workspace/kb/projects/tech-debt/{repo}-tech-debt.md (tech debt audit YYYY-MM-DD)
   ```

10. **Report** — summarize: total findings by category, top 3 high-ROI items, modernization highlights, and the KB file path.

## Notes
- This is a point-in-time snapshot — re-run periodically (quarterly) or after major refactors
- Don't duplicate findings already tracked in Jira — cross-reference existing tickets
- Focus on patterns, not individual style nits — a single missing null check isn't tech debt, but 15 endpoints missing input validation is
- The KB file is the deliverable — it should be useful standalone for sprint planning discussions

## Error Handling

- **Repo path not found**: if the resolved path doesn't exist or `.local-paths` has no match, ask the user for the correct path via AskUserQuestion.
- **Git commands fail**: if the repo isn't a git repository, report the error and stop.
- **KB write failure**: if `workspace/kb/projects/tech-debt/` can't be created, fall back to `workspace/tmp/` and note the alternative path.
- **Scope control**: if the repo has >500 source files, ask the user to narrow scope (specific directories or categories) before starting. A full unbounded audit of a large repo consumes excessive context.
