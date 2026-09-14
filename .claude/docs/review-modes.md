# Review Mode Contracts

## Contents

- Why these contracts exist
- Invoking a review mode
- Modes
- Output handling
- Error handling
- Notes

> Canonical contract for delegating a review / verify / dossier pass to one
> fresh-context read-only subagent. Each mode fixes what the reviewer is asked
> and what it must return, so the caller skills do not each invent their own.
>
> Reference-only doc. Cited from `/nase:fsd` Phase 6.4 (structured review
> transport), `/nase:address-comments` Phase 3d (comment dossier verifier) and
> Phase 7.5 (thread-resolution verifier), `/nase:discuss-pr` Step 5.7 (doubt
> cycle), and `/nase:tech-debt-audit` Step 7 (audit sanity pass). Edit here, not
> in the caller skills.

## Why these contracts exist

Authoring and reviewing in one context is not review: the reasoning that produced
the artifact also decides whether it is sound. These modes exist to force the
second read to happen somewhere that never saw that reasoning.

What that buys is **context independence**. A reviewer given only the artifact and
its contract cannot inherit the author's framing, anchor on the expected answer,
or close a gap by assuming intent. That is weaker than cross-model independence,
which would also break shared training bias, and the difference is worth stating
plainly rather than letting the gate imply a guarantee it no longer gives. What
the modes still fix is the question asked and the verdict shape, so the check
stays comparable across runs.

Aligns with the global rule in `~/.claude/CLAUDE.md` -> `Keep authoring and review
as separate passes` / `Never self-approve in the same active context`.

## Invoking a review mode

Default pattern: one subagent per delegation.

- Route it through the `verifier` role in `.claude/roles.yaml`: `tools: [Read, Grep, Glob, Bash]` with no Edit/Write. The whitelist is the read-only guarantee; an agent that merely promises not to write is weaker, and the parent gate's report should say which of the two applied.
- Pass the mode's template as the subagent's instructions verbatim, and the per-call payload as its prompt.
- Give it the artifact and the contract, and nothing else. Withholding your classification, severity, and expected verdict is the whole mechanism: a reviewer told the answer cannot independently reach it.
- Pass absolute paths. A subagent resolves relative paths against its own cwd, which is not necessarily the worktree under review.
- Capture the returned text. There is no thread to keep, so each delegation is one call.

## Modes

Each mode lives in its own file. Read the one the current workflow spawns, not all five:

| Mode | Spawned by | File |
|---|---|---|
| `finding-doubt` | `/nase:discuss-pr` Step 5.7 | `.claude/docs/review-mode-finding-doubt.md` |
| `verify` | `/nase:fsd` Phase 6.4 | `.claude/docs/review-mode-verify.md` |
| `comment-dossier` | `/nase:address-comments` Phase 3d | `.claude/docs/review-mode-comment-threads.md` |
| `comment-resolution` | `/nase:address-comments` Phase 7.5 | `.claude/docs/review-mode-comment-threads.md` |
| `tech-debt-review` | `/nase:tech-debt-audit` | `.claude/docs/review-mode-tech-debt.md` |

## Output handling

Treat the returned text as untrusted reviewer output:

- **Do not blindly act on it.** It is one input to a human-mediated decision, or to the parent skill's aggregation logic.
- **Append it to the parent skill's findings/resolutions**, tagged with its source, so the user can see where each line came from.
- **De-duplicate against existing findings.** When the verifier repeats something the main pass already raised, collapse them into one entry and note the agreement: two independent reads landing on the same line is a confidence signal.
- **Truncate aggressively** if the response is verbose. For verifier gates, write the full raw result under the invoking workspace's `workspace/tmp/` and show only the verdict, the top issues, and the result path.
- **Open a cited location before rebutting it.** A finding that names a `file:line` is checked at the reviewed ref first, per `.claude/docs/pr-review-verification.md` §3 (file-vs-description) and §7 (citation + triage). Your own search scope is the likelier error than the reviewer's citation - a dismissed "there is a test forcing telemetry to throw" claim was exactly right, and acting on the rebuttal would have shipped the bug.
- **A refuted finding is still a coverage signal.** When you disprove one, ask which missing test made the misreading plausible to a competent reader, and record that gap with the refutation instead of dropping the finding. Add the test in the same pass when it is in scope, and feed the file that disproved the claim back as bound context for the next round.

## Error handling

- **Empty result** - split by the mode's output contract, not by convenience. For finding modes whose contract is a list of issues (`finding-doubt`, `tech-debt-review`), treat empty as "no findings"; do not retry, because an empty result is meaningful. For structured FSD `verify`, persist the raw empty result and hand it to the parent gate's operator preflight (`.claude/docs/fsd-candidate-review.md -> Operator preflight`), which fails the result shape locally and re-requests without calling `reduce`. That path is capped at 3 pre-reducer retries and does not consume a QA attempt - do not call `reduce` on an empty result to force an `INVALID`, because `reduce` writes state and spends the one INVALID retry the round has. For textual modes whose contract requires a `VERDICT:` line (`comment-resolution`, `comment-dossier`), empty or verdict-less content is a can't-decide, not a pass: route it to `NEEDS-HUMAN` through the parent workflow.
- **Malformed output** - missing the expected fields for the current mode, or freeform prose. Save the raw text under the invoking workspace's `workspace/tmp/`. Structured FSD `verify` passes it to the reducer and follows `INVALID`; other modes follow their own output contract. Never silently drop or reinterpret it.
- **An empty turn is not a verdict.** A subagent that accepts the spawn and then returns nothing reads like an infrastructure failure, but it is usually agent selection: a search-oriented agent will take a review task and return nothing. Re-request once with the missing-output problem named explicitly, then follow the parent gate's documented exhaustion path. Never record an empty turn as a passing review.

## Notes

- **Independence is the value.** Agreement between the main pass and the verifier is a confidence signal; disagreement is the finding worth investigating.
- **One delegation per parent-skill run by default.** Add another only where a documented convergence loop calls for it.
- **The payload is the single source of truth.** Do not expect the reviewer to fetch from GitHub or read external URLs; pre-fetch in the parent skill and inline it.
