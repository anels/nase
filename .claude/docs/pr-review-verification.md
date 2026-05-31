# PR review verification patterns

Five checks to run before trusting a claim during PR review. Used by `/nase:discuss-pr` (read-only review) and `/nase:address-comments` (write fixes).

Principle: **prose claims are hypotheses, not evidence**. Always diff-confirm against the file at HEAD before acting (resolve a thread, drop a finding, mark something fixed).

## 1. AI-reviewer assertion-value guard

When an AI reviewer (Copilot, claude bot, codex bot) changes the *expected value* in a test assertion (e.g. `BeEmpty()` → `BeNull()`, `Be(0)` → `Be(null)`, expected status code, expected serialized form), run the test at the suggested form **before** committing. AI reviewers cannot observe runtime values. A serialization or round-trip detail (e.g. `null` re-serializing as `""`) can invalidate the proposed expected value while leaving the structural critique valid.

## 2. Diff-scope verification

For each agent or reviewer finding, verify the flagged line or pattern is genuinely new in this PR — not pre-existing code. Read the base-branch version: `git show origin/{base_branch}:{path}`. Pre-existing issues that the PR did not introduce or modify are not the author's responsibility — drop silently.

## 3. File-vs-description verification

Read the actual file at the referenced line and confirm the reviewer's prose description matches reality. Reviewers (including AI reviewers) misread diffs. If the claim says "missing null check" but the check exists, the suggestion is based on a misread and should be declined regardless of other factors.

## 4. Resolved-thread HEAD verification

Resolved threads (closed by author or `isResolved: true`) are a hypothesis, not evidence. For each resolved thread that touches code-correctness (not pure style/nit), pull the file at HEAD and grep/read the exact filter, branch, condition, or symbol the thread referenced. If the claimed fix is NOT in HEAD, surface as a new 🔧 needs-fix with note `claimed fixed but not in HEAD`.

## 5. Prior-round fix verification

For any 🔧 needs-fix items that originate from an EARLIER review round (comments that predate the most recent commit), do not auto-classify as ✅ can-resolve based on the author's "addressed" reply alone. Run `git show <sha>` for the commit claimed to address the issue and confirm the fix appears in the diff. If the commit doesn't contain the fix, keep the item as 🔧 needs-fix.

## 6. Suggestion-block re-derivation

A reviewer's ```suggestion fenced code block captures *intent*, not a literal patch — especially when it proposes a different data structure for an existing field. Snippets routinely drop critical wrapping that the original declaration carried: generic args, nullability, equality comparers, modifiers (`readonly`, `init`), `AsReadOnly()` wrappers, type aliases. Read the original declaration's full signature before applying. If the suggestion changes the container type (e.g. `ConcurrentDictionary<string, T?>` with `StringComparer.OrdinalIgnoreCase` → `Dictionary<string, T>.AsReadOnly()`), enumerate: (a) is the comparer still needed? (b) keep nullable value type? (c) widen receiver to `ReadOnlyDictionary<TKey,TValue>`? Restore the dropped wrapping in the final implementation — do not copy-paste the snippet verbatim. Pattern surfaced in a prior dashboarding PR review.

## 7. AI-reviewer citation verification

When a bot cites a specific lint rule code (`SC2206`, `SC2207`, ESLint `no-shadow`, pylint codes) or a specific SDK method behavior (option ignored, exception type, deprecation), verify the citation against the local source of truth before accepting the proposed fix:

- **Lint rule citations** — run the cited linter on the file at HEAD. Bots routinely attach a rule code to patterns that rule doesn't cover. Sanitized pattern: a bot flagged a bash `for` loop as triggering `SC2206/SC2207`, but `shellcheck` exited 0 on the file — those codes only fire on array-assignment patterns, not `for` loops.
- **SDK method behavior** — read the installed version's type definitions / source. Sanitized pattern: a bot suggested `{timeout: 30_000}` on `Playwright.Locator.isVisible()`, but the installed `types.d.ts` marked the option deprecated/ignored. The proposed fix does nothing; the correct shape is `await expect(...).toBeVisible({timeout})`.

Common failure mode: the bot's *structural* concern is sometimes valid (lint cleanup needed, timeout handling needed) even when the *specific* citation is wrong. Treat citation verification as separate from accepting the underlying concern.
