# PR Review Verification Patterns

Checks to run before trusting a claim during PR review. Used by `/nase:discuss-pr` (read-only review) and `/nase:address-comments` (write fixes).

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

## 7. AI-reviewer citation + triage verification

Before echoing or accepting any bot-flagged finding — lint citation, SDK behavior claim, "unused import", cross-pattern asymmetry — run three checks against the file at HEAD. The gate decides whether to echo, accept, or decline. Record the verification command + result in the inline reply so the reviewer can audit.

- (a) **Trigger reachability** — grep call sites / consumer repos for the exact pattern that would trigger the issue. Zero matches → the finding is theoretical; follow-up, not blocker.
- (b) **Runtime contract** — read the installed version's source / types. The installed version is the source of truth, not the bot's generic rule citation.
- (c) **Historical precedent** — grep the codebase for the same pre-existing pattern. If it lives elsewhere since a vendor commit, the asymmetry is informational, not a regression introduced by this PR.

Examples of (b) — installed source vs. cited rule:

- **Lint rule citations** — run the cited linter on the file at HEAD. Bots routinely attach a rule code to patterns that rule doesn't cover. Sanitized pattern: a bot flagged a bash `for` loop as triggering `SC2206/SC2207`, but `shellcheck` exited 0 on the file — those codes only fire on array-assignment patterns, not `for` loops.
- **SDK method behavior** — read the installed version's type definitions / source. Sanitized pattern: a bot suggested `{timeout: 30_000}` on `Playwright.Locator.isVisible()`, but the installed `types.d.ts` marked the option deprecated/ignored. The proposed fix does nothing; the correct shape is `await expect(...).toBeVisible({timeout})`.
- **Unused-using / CS8019** — enumerate types declared in the suspect namespace via `grep -hE "^(public|internal|abstract|sealed)( +(abstract|sealed|partial|static))*( +(class|interface|enum|struct|record))" -- 'path/to/ns-dir/*.cs'`, then `grep -nFwf type-list.txt {flagged-file}`. Any match → the using is needed; decline. Bonus signal: if `build-test` at PR head is already green, CS8019 cannot be triggering on that line; the bot is wrong by construction. Sanitized pattern: bot flagged a transformer's `using …Models` as unused; the file referenced `MetricResponseEntryDto` (defined in that namespace) at multiple lines. Accepting would have broken every call site.

Common failure mode: the bot's *structural* concern is sometimes valid (lint cleanup needed, timeout handling needed) even when the *specific* citation is wrong. Treat citation verification as separate from the underlying concern.

## 8. Comment dossier contract

Before `/nase:address-comments` classifies any unresolved review thread, build the dossier shape from `.claude/docs/ai-code-verification-debt.md → Comment Dossier Contract`.

That shared contract owns the required fields and explicit-only AI provenance rule. `/nase:address-comments` owns the concrete collection commands for comment chain, PR head/base/diff, KB/repo constraints, caller impact, and test/scanner evidence.

Classification is blocked until the dossier exists. If evidence is missing and cannot be collected locally, classify as `ask-user` or draft a reply that names the missing business/intent context. Do not silently downgrade uncertain correctness/security comments to style or out-of-scope.
