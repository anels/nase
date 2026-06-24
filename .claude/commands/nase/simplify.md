---
name: nase:simplify
description: Simplify recently-modified code and remove AI-shaped slop while preserving behavior. Part of the standard commit sequence before /nase:improve-commit-message. Use when asked to "simplify", "clean up code", "refactor for clarity", "tidy up", "deslop", "anti-slop", or before any commit. Also invoked by /nase:fsd Phase 6.
pattern: producer-reviewer
category: Git workflow
---

Cleanup pass on recently-modified code: deletion-first anti-slop cleanup plus `code-simplifier` readability refinement, with behavior preserved exactly.

Replaces the retired Anthropic bundled `/simplify` (removed in Claude Code v2.1.147). Uses the `code-simplifier:code-simplifier` subagent when available, with the anti-slop contract embedded in the dispatch prompt.

**Input:** `$ARGUMENTS` — optional scope override (`--scope=<glob>`), `--review`, `--dry-run`, `--verbose`.

## Step 0 — Language preflight (MUST run first, non-negotiable)

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Use `conversation:` for chat. The subagent edits code identifiers and comments — those follow project conventions, not `conversation:`.

## Steps

<workflow>

### 1. Determine scope

Pick the scope source from `$ARGUMENTS` (lowercase, trimmed):

- `--scope=<glob>` → resolve the glob via tracked files and untracked files matching the glob.
- contains `unstaged` → `git diff --name-only` plus untracked files.
- contains `staged` (e.g. "staged files", "staged-only") → `git diff --name-only --cached`.
- contains `last-commit` or `last commit` → `git diff --name-only HEAD~1 HEAD`.
- anything else (default) → all files modified since the merge base with `origin/<default-branch>`, plus staged + unstaged + untracked.

Capture the deduplicated list into `$FILES` so later steps have a concrete handle:

```bash
git fetch origin --quiet
DEFAULT=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
[ -z "$DEFAULT" ] && DEFAULT=main
BASE_REF="origin/$DEFAULT"
MERGE_BASE=$(git merge-base HEAD "$BASE_REF" 2>/dev/null || git rev-parse HEAD)

case "$ARGUMENTS" in
  *--scope=*) GLOB="${ARGUMENTS##*--scope=}"; GLOB="${GLOB%% *}"
              FILES=$({
                git ls-files -- "$GLOB"
                git ls-files --others --exclude-standard -- "$GLOB"
              } | sort -u) ;;
  *unstaged*) FILES=$({
                git diff --name-only
                git ls-files --others --exclude-standard
              } | sort -u) ;;
  *staged*)   FILES=$(git diff --name-only --cached | sort -u) ;;
  *"last-commit"*|*"last commit"*)
              FILES=$(git diff --name-only HEAD~1 HEAD | sort -u) ;;
  *)          FILES=$({
                git diff --name-only "$MERGE_BASE" HEAD
                git diff --name-only
                git diff --name-only --cached
                git ls-files --others --exclude-standard
              } | sort -u) ;;
esac
```

If `$FILES` is empty → output `No modified files in scope. Nothing to simplify.` and stop.

### 2. Protect behavior and inspect the diff

Before editing:
- Identify the behavior that must stay the same for the scoped files.
- Inspect `git diff --stat`, `git diff`, staged diff, and any file-local tests or call sites needed to understand behavior.
- If cleanup risk is meaningful and the test surface exists, prefer adding or preserving the narrowest regression coverage.
- If tests cannot come first, state the verification plan before editing.

Preserve behavior exactly. Do not change features, outputs, public APIs, persistence formats, permissions, side effects, timing, ordering, or error semantics unless the user explicitly asks.

### 3. Classify cleanup targets

Look for concrete smells only:
- Dead code: unused exports, unreachable branches, stale flags, debug leftovers, dead variables, redundant comments.
- Duplication: repeated logic, copy-paste branches, duplicate conditionals, repeated parsing or normalization.
- Needless abstraction: pass-through wrappers, speculative indirection, single-use helper layers, clever one-liners that obscure intent.
  - **Reuse-first ladder test** (operationalizes DRY + YAGNI from `.claude/docs/design-principles.md`; apply after comprehending the existing flow): for each added construct, find the first rung that justifies it — (1) needs to exist? (YAGNI) (2) already in codebase? (3) in stdlib? (4) native platform feature? (5) already-installed dependency? (6) one-liner? (7) only then a new minimal implementation. If a construct is covered by rungs 1–6, cut it. Never cut trust-boundary validation, security, or accessibility regardless of rung.
- Control-flow noise: deeply nested logic, nested ternaries, avoidable branching, broad catches that hide intent.
- Boundary leaks: wrong-layer imports, hidden coupling, misplaced responsibilities, unexpected side effects.
- Weak tests: broad assertions, missing edge cases around changed behavior, cleanup without a practical verification path.
- UI slop: generic spacing, colors, copy, shadows, grids, gradients, or states that look unreviewed rather than intentional.

Skip formatting-only churn, broad rewrites, new dependencies, public API renames, unrelated files, and speculative abstractions.

### 4. Review mode

If `--review` is present in `$ARGUMENTS`, do not edit files.

Review the scoped files, current diff, and verification evidence. Return:
- Verdict: `pass`, `needs cleanup`, or `risky`.
- Concrete leftovers: dead code, duplication, needless wrappers, boundary leaks, weak tests, or likely accidental behavior changes.
- Required follow-ups, ordered by safest deletion first.

Stop after the review report unless the user explicitly asks this same pass to switch to writer mode.

### 5. Plugin availability check

If the `code-simplifier:code-simplifier` subagent is not available (plugin not installed), fall back to self-review:
- Check each file against the cleanup targets in Step 3.
- Apply minimal, behavior-preserving fixes only. Prefer deletion, then duplication consolidation, then clearer names/control flow/error handling.
- Skip anything that needs a broad rewrite, changes behavior, or cannot be validated.
- Emit `WARN: code-simplifier subagent unavailable — ran self-review anti-slop fallback. Install claude-plugins-official for the full pass.`

Otherwise continue to Step 6.

### 6. Dispatch subagent

Launch the `code-simplifier:code-simplifier` subagent via the Agent tool. Pass:
- The deduplicated file list from `$FILES` (Step 1)
- Instruction:
  - Refine each file for clarity, consistency, maintainability, and anti-slop cleanup following the project's CLAUDE.md conventions.
  - Preserve behavior exactly. Do not change features, outputs, public APIs, persistence formats, permissions, side effects, ordering, timing, or error semantics.
  - Keep scope to `$FILES`; do not expand to the rest of the repo.
  - Prefer deletion over addition.
  - Reuse local utilities and patterns before introducing any abstraction. Do not add dependencies. For each added construct apply the reuse-first ladder (codebase → stdlib → platform → installed dep → one-liner → only then new code); cut anything an earlier rung already covers. Never cut trust-boundary validation, security, or accessibility.
  - Run one smell-focused pass at a time: delete dead code first, consolidate duplication second, improve names/control flow/error handling third, reinforce tests last only when needed.
  - Keep useful abstractions. Do not inline code merely because it is shorter if the abstraction carries meaning or isolates change.
  - Replace nested ternaries and dense one-liners with explicit conditionals when that improves readability.
  - Avoid cosmetic-only churn, large abstractions for one-off code, broad renames, and combining unrelated concerns.
  - If validation is practical, run the narrowest useful check: file-local tests, syntax checks, lint, typecheck, or project-specific checks.
  - Report what changed, why it is behavior-preserving, and what validation ran.
- If `--dry-run` in `$ARGUMENTS`: ask the subagent to return proposed changes only, do not write.

Wait for the subagent to complete before summarizing.

### 7. Validate

If files changed and validation did not already run:
- Run the narrowest useful validation available for touched code.
- If a gate fails because of the cleanup, fix it or back out the risky part.
- If validation cannot be run, explain why and name the remaining risk.

Do not force through a cleanup that weakens behavior confidence.

### 8. Summarize to chat

Per `.claude/docs/skill-contract.md` — chat output ≤ 5 lines:

```
Simplified N files (M changes).
- {file}: {one-line summary of biggest change}
Validation: {command or "not run: reason"}
Risks/follow-ups: {none or short note}
```

If `--verbose` in `$ARGUMENTS`: dump the subagent's full report inline as well.

### 9. Hand off

The commit-sequence next step is `/nase:improve-commit-message`. This skill does not stage, commit, or push.

</workflow>

## Notes

- **Behavior preservation is mandatory** — the subagent must never change functionality. If you suspect it did, run the project's tests before committing.
- **Scope discipline** — only recently-modified files. Don't expand to the rest of the repo even if obvious wins are visible there; that's a separate task.
- **Deletion first** — remove dead code and debug leftovers before introducing helpers or abstractions.
- **Regression confidence beats tidiness** — if a simplification cannot be verified, leave it alone or report it as a follow-up.
- **`/code-review` is orthogonal** — `/code-review` (Claude Code 2.1.147+) reports correctness bugs at low/med/high effort and optionally posts inline PR comments. `/nase:simplify` does cleanup. They don't replace each other.

## Attribution

The `code-simplifier:code-simplifier` subagent is provided by the `claude-plugins-official` marketplace (`plugins/code-simplifier/agents/code-simplifier.md`) under Apache License 2.0, Copyright Anthropic. This skill dispatches it without vendoring the agent prompt.

Anti-slop criteria are adapted from Codex `ai-slop-cleaner` / `code-simplifier`; this skill dispatches only `code-simplifier` and embeds anti-slop checks in the prompt/fallback.
