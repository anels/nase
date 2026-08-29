# Anti-Rationalization — Excuse → Rebuttal Catalog

Shared reference for nase gates where agents often skip verification or scope checks. Skills reference the relevant block at the gate; keep the table here instead of duplicating it inline.

Source pattern: [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) anti-rationalization tables; see `workspace/kb/general/claude-prompting.md` (2026-06-12 entry).

## Universal

| Excuse | Rebuttal |
|---|---|
| "Tests pass, ship it." | Passing tests are evidence, not proof. Verify runtime behavior + the actual goal, not just green CI. |
| "I'm confident, skip the verify gate." | Confidence correlates poorly with correctness on novel code. The gate is cheap; the prod bug is not. |
| "I already reviewed it, a second pass is redundant." | Self-review in the same context validates your own conclusions. Use a fresh-context reviewer that never saw your reasoning. |
| "It's a small change, scope check is overkill." | Scope creep is the single biggest determinant of whether a PR stays mergeable. Touch only what was asked. |
| "I know the SHA / line / count, I'll type it." | A value you typed is a claim. Read it from a command and paste the output. A truncated display (a short SHA, `head` output, a table cell) is not the value. |
| "The verifier refuted it / the gate failed / the search returned nothing." | A negative verdict is evidence about the run, not about the claim. Check what the harness actually read: which source, which ref, which toolset. Then drop the claim, or not. |

## `/nase:fsd` — Phase 6.5 Pre-Push Verification Gate

| Excuse | Rebuttal |
|---|---|
| "Codex is unavailable, skip the gate." | The gate is mandatory; only the cross-model variant is optional. Run the single-model fallback. |
| "I wrote it and it looks right, self-approve." | Do not self-approve in the same active context. Spawn the `verifier` with CONTRACT + ARTIFACT only — not your reasoning (strip-the-CLAIM). |

## `/nase:address-comments` — Phase 6 Execute / Phase 3 Verify-First

| Excuse | Rebuttal |
|---|---|
| "Reply looks resolved, mark the thread done." | A reply is not a fix. Resolve only after the change lands AND matches what the reviewer asked at HEAD. |
| "The reviewer is probably right, just apply it." | Verify the premise first (file-vs-description, conditional premise). A wrong premise = `decline` with the missed evidence, not a silent accept-then-revert. |
| "Every named malformed case is handled, close it." | If any reviewer-named value lands in `silent`, the fix is not done. Check each case reaches its intended branch. |

## `/nase:prep-merge` — Phase 2b Block / Phase 4 Branch State

| Excuse | Rebuttal |
|---|---|
| "Only one thread left, squash and push anyway." | Any unresolved human/non-declined thread blocks prep-merge. Resolve or route to `/nase:address-comments` first. |
| "Branch is probably current, force-push." | Verify branch state vs upstream + prior-abort signature first. `--force-with-lease` only, after warning. |
