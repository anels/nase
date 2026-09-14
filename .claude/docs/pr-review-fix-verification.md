# PR Review Fix Verification Patterns

## Contents

- 1. AI-reviewer assertion-value guard
- 5. Prior-round fix verification
- 6. Suggestion-block re-derivation
- 8. Comment dossier contract
- 9. Review-Thread Resolution Gate

Checks that only apply when a review comment is being **acted on** - a fix about to be
committed, a prior round's claimed fix, a suggestion block being applied, or a thread
about to be replied to and resolved. Used by `/nase:address-comments`.

Read-only review checks live in `.claude/docs/pr-review-verification.md`; `/nase:discuss-pr`
loads that file and never this one. Section numbers here match the numbering both files
shared before the split, so an existing `§5` / `§9` reference still resolves - only the
document path changed.

## 1. AI-reviewer assertion-value guard

When an AI reviewer (Copilot, claude bot, codex bot) changes the *expected value* in a test assertion (e.g. `BeEmpty()` → `BeNull()`, `Be(0)` → `Be(null)`, expected status code, expected serialized form), run the test at the suggested form **before** committing. AI reviewers cannot observe runtime values. A serialization or round-trip detail (e.g. `null` re-serializing as `""`) can invalidate the proposed expected value while leaving the structural critique valid.

## 5. Prior-round fix verification

For any 🔧 needs-fix items that originate from an EARLIER review round (comments that predate the most recent commit), do not auto-classify as ✅ can-resolve based on the author's "addressed" reply alone. Run `git show <sha>` for the commit claimed to address the issue and confirm the fix appears in the diff. If the commit doesn't contain the fix, keep the item as 🔧 needs-fix.

## 6. Suggestion-block re-derivation

A reviewer's ```suggestion fenced code block captures *intent*, not a literal patch — especially when it proposes a different data structure for an existing field. Snippets routinely drop critical wrapping that the original declaration carried: generic args, nullability, equality comparers, modifiers (`readonly`, `init`), `AsReadOnly()` wrappers, type aliases. Read the original declaration's full signature before applying. If the suggestion changes the container type (e.g. `ConcurrentDictionary<string, T?>` with `StringComparer.OrdinalIgnoreCase` → `Dictionary<string, T>.AsReadOnly()`), enumerate: (a) is the comparer still needed? (b) keep nullable value type? (c) widen receiver to `ReadOnlyDictionary<TKey,TValue>`? Restore the dropped wrapping in the final implementation — do not copy-paste the snippet verbatim. Pattern surfaced in a prior dashboarding PR review.

## 8. Comment dossier contract

Before `/nase:address-comments` classifies any unresolved review thread, build the dossier shape from `.claude/docs/ai-code-verification-debt.md → Comment Dossier Contract`.

That shared contract owns the required fields and explicit-only AI provenance rule. `/nase:address-comments` owns the concrete collection commands for comment chain, PR head/base/diff, KB/repo constraints, caller impact, and test/scanner evidence.

Classification is blocked until the dossier exists. If evidence is missing and cannot be collected locally, classify as `ask-user` or draft a reply that names the missing business/intent context. Do not silently downgrade uncertain correctness/security comments to style or out-of-scope.

## 9. Review-Thread Resolution Gate

This gate is unconditional: replying to and resolving someone's review threads is
an outward-facing, hard-to-undo action. The verifier is a local subagent, so there
is no availability branch to skip through.

Spawn one fresh-context read-only subagent (role `verifier` per `.claude/roles.yaml`,
tools: Read/Grep/Glob/Bash — no Edit/Write). Give it ONLY:
- the unresolved review threads from Phase 2 (full comment chains)
- the final post-Phase-4 dossier/action map and drafted replies from Phase 6
- the implementation diff:
  - If code changed: `git -C {worktree_path} diff origin/{pr_branch}` (working tree diff before commit)
  - Also include `git -C {worktree_path} ls-files --others --exclude-standard` and the full content of any task-created untracked files
  - If no code changed: say `No code diff; reply-only / decline verification only`
  - For diffs >2000 lines: use `git diff --stat` plus the 5 most-changed files in full

Ask it to judge independently, per thread:
- does the diff/reply actually address what the reviewer asked?
- is any decline reply factually wrong?
- does any reply contradict the dossier evidence or omit a required verification note?
- does the diff add a code comment that `.claude/docs/code-comment-policy.md` would not earn - restating the code, narrating the change, or an unanchored *why*? Report it; a comment that contradicts the line below it is a FAIL, an unearned one is not.

Do NOT include your own classification reasoning or expected verdict — an independent
read is the only thing this gate buys, and naming your expected answer spends it.
Use the `comment-resolution` mode contract from `.claude/docs/review-mode-comment-threads.md` as the
subagent's instructions verbatim. Log `thread-resolution verify: {VERDICT}`; overrides
use tag `verify-override`.

Expected shape:
```
VERDICT: PASS | FAIL | NEEDS-HUMAN
THREADS NOT ADDRESSED: ...
REPLY / RESOLVE RISKS: ...
SCOPE CREEP: ...
REASONING: ...
```

Decision tree:

- **PASS** → log one line (`thread-resolution verify: PASS`) and proceed to Phase 8. No user prompt. If SCOPE CREEP came back non-empty, print those items first: a PASS verdict does not mean they are absent, and this is the only place they ever surface. Delete an unearned comment it names before committing - a comment-only deletion needs no further gate round.
- **NEEDS-HUMAN** → present the full verifier output and ask via `AskUserQuestion`:
  - Q: "The verifier flagged ambiguity in the review-thread resolution. What now?"
  - Options: `Revise first` / `Proceed — push anyway` / `Show me the diff + replies`
  - Honor the user's choice.
- **FAIL** → do NOT commit or push. Present the full verifier output and ask via `AskUserQuestion`:
  - Q: "The verifier says at least one review thread isn't safely addressed. What now?"
  - Options: `Fix it` / `Override — the verifier is wrong` / `Cancel`
  - On "Fix it": re-enter Phase 6 with the failing thread(s) as requirements, then rerun build/test and this gate.
  - On "Override": log the override to the daily log (tag: `verify-override`) before proceeding.

Malformed output (no `VERDICT:` line) → treat as `NEEDS-HUMAN`, present raw `content`, and ask the user.

This gate checks reviewer intent, not just tests.
