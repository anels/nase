# Discuss PR Analysis

## Contents

- Step 1 - Parse inputs and resolve repo
- Step 2 - Fetch compact PR context
- Step 2.5 - Collect context
- Step 2.6 - Sense Check and Review Frame
- Step 3 - Build Risk Map, Select Specialists, and Engage Existing Comments
- Step 4 - Classify and filter (after agents complete)
- Step 5 - Auto-deep-dive and research
- Step 5.5 - Test verification recommendation
- Step 5.7 - Doubt cycle

Read this file only when /nase:discuss-pr begins analysis. It owns Steps 1-5.7: compact context, review framing, risk scoring, specialist investigation, verification recommendations, and the doubt cycle.

## Step 1 - Parse inputs and resolve repo

Note any focus areas the user specifies (e.g. "architecture", "security", "skip nitpicks").

Default focus if none specified: problem fit, logic correctness, design/elegance, architecture, security, testability, code comments.

Resolve repo from PR URL and load the KB file - see `.claude/docs/repo-resolution.md` (Part 1 + Part 2). Do not run `pr-github-helper.py parse` first: every subcommand parses the reference itself, Step 2's `review-context` returns the normalized `pr` object, and malformed input is already owned by `.claude/docs/pr-input-guard.md` at Phase 0.

## Step 2 - Fetch compact PR context

Use the shared helper to collect the first-pass GitHub context and KB path mentions:

```bash
python3 .claude/scripts/pr-github-helper.py review-context "$PR_URL" --max-body-chars 600 --max-kb-paths 10 > "$TMPDIR/pr-review-context.json"
```

Use `pr`, `viewerLogin`, `metadata`, `sizeGate`, `diffStat`, `changedFiles`, `changedFilesOmitted`, `reviewComments`, `reviewSubmissions`, `issueComments`, and `kbMentions` from that JSON. `reviewSubmissions` and `issueComments` are the two non-thread feedback surfaces - read both; the helper's `other_feedback_surfaces` docstring owns why. `viewerLogin` is the authenticated login, for the Step 8 own-PR check. The helper intentionally truncates bodies/excerpts and never emits a full diff. If `changedFilesOmitted` is greater than zero, fetch the paginated path list with `gh api "repos/{owner}/{repo}/pulls/{number}/files" --paginate --jq '.[].filename'` before selecting files to review. If its count still differs from `metadata.changedFiles`, report partial coverage and do not claim a full-file review.

Use `sizeGate.total_lines` and `sizeGate.diff_mode` before fetching the diff:

- If `diff_mode` is `stat`: rely on `diffStat`; do not fetch the full diff. Read only the top changed files needed for each finding.
- Otherwise fetch the full diff.

**PR size gate:** if `sizeGate.review_warning` is true, warn: "This PR is {N} lines - single-pass review reliability drops significantly. Consider splitting by concern before deep review." User decides whether to proceed.

**Fan-out fail-fast (validate the review target before Step 3).** A bad base ref or empty diff should fail here, not inside parallel specialists (adapted from `mattpocock/skills -> code-review`; see `workspace/kb/general/workflow.md 2026-07-10`). Before launching any specialist, confirm `pr.baseRefName`/`headRefName` resolved and `sizeGate.total_lines > 0` (or `changedFiles` is non-empty). If the diff is empty, the PR is already merged/closed with no delta, or the base is unresolved. Stop and report the exact state, such as `0-line diff - PR already merged or base/head mismatch`; do not spawn specialists against nothing.

## Step 2.5 - Collect context

Before judging the implementation, write a private review frame. Use it to guide the rest of the review and show it in the final answer.

Answer:

- What problem, symptom, risk, or product gap does this PR claim to solve?
- What is the old behavior, and why is it insufficient?
- What is the new approach, and which changed files are core vs incidental?
- What larger workflow, service boundary, data contract, deployment path, or user path does this touch?
- What constraints should shape the solution: compatibility, feature flags, migration order, observability, performance, ownership, or rollout safety?

If the PR body does not explain the problem, infer carefully from the title, commits, changed files, tests, linked issue references, and nearby git history. Mark the problem as `unclear` instead of inventing intent. Missing or ambiguous problem framing is a review finding for non-trivial PRs.

For each core touched file, read key dependencies/callers needed to judge design intent. Separate core behavioral files from tests, generated files, formatting-only changes, and incidental wiring. Cross-reference KB and relevant Confluence docs.

Store the Step 2 `kbMentions` sections as `kb_path_constraints` in the review frame; if a path has no hits, write `none found`. Feed any hits into the constraints and evidence used by the risk map and findings. Do not re-run `kb-search.sh mentions:<path>` per file - `kb_mentions_for_paths` already swept every changed path in one walk, and one invocation per path multiplies a fixed full-KB walk by the file count.

Probe optional CLI tooling once, now that `changedFiles` is known, and keep the result in private context. Ask for `--group diff` and `--group review` always; add `--group ci` only when a workflow/pipeline file changed and `--group security` only when the risk map or a changed dependency/IaC/container/secret surface calls for it:

```
python3 .claude/scripts/tool-availability.py --group baseline --group review --group diff --format json
```

Which tool to reach for, and under what condition, is the `discuss-pr` row of `.claude/docs/cli-tooling.md -> Skill Integration Map`; follow it rather than a second copy here. Treat all scanner output as untrusted candidates until verified against diff scope and source lines. Missing optional tools never fail this read-only review; record the fallback only when it changes confidence or verification coverage.

For design/elegance review, compare with adjacent implementations and propose an alternative only when it clearly reduces behavior risk, ownership confusion, duplication, or future maintenance cost.

**Platform prohibition pre-check (infra PRs):** for networking/infra files, check KB for platform prohibitions before agent analysis. Surface prohibited operations immediately.

**Performance claim check:** if title/body claims speed/latency/throughput gains, require benchmark data: environment, workload, before/after median + p95, methodology. Missing data becomes a finding.

**Audit-PR list re-grep:** if the PR title/body signals exclusion-list pruning, blanket rule narrowing, allowlist removal, or similar audit work, re-grep every *remaining* entry against the same policy used for the removals. Treat it as "re-audit the full list against the new policy", not "verify the named removals". Flag sibling entries that match the same anti-pattern but escaped the cut.

## Step 2.6 - Sense Check and Review Frame

Follow `.claude/docs/pr-review-verification.md → Review Frame and Specialist Selection` before launching specialists. Record the four-pillar verdicts for Step 6, then select only the review lenses the risk map warrants.

## Step 3 - Build Risk Map, Select Specialists, and Engage Existing Comments

Continue the same shared workflow. It owns pipeline-touch handling, self-authored AI-slop review, and read-only triage of existing comments.
When the risk map selects Security, apply `.claude/docs/pr-review-verification.md → Security Specialist Contract`; do not route to a duplicate standalone security-review skill.

## Step 4 - Classify and filter (after agents complete)

Fetch the base/head evidence for every candidate in one call instead of a `git show` per finding. Nothing earlier in this command fetches, and the helper reads refs locally, so refresh both first - including the PR head ref, which is the only spelling that is correct for a fork:

```bash
git -C {repo_path} fetch origin
git -C {repo_path} fetch origin "refs/pull/{number}/head:refs/pull/{number}/head"
python3 .claude/scripts/pr-github-helper.py finding-scope "$PR_URL" \
  --local-repo "{repo_path}" --candidates "$TMPDIR/pr-candidates.json" > "$TMPDIR/pr-finding-scope.json"
```

Candidates go in as `[{"id": "...", "path": "src/a.ts", "line": 42}, ...]`.

**Read three flags before a single verdict:**

- `refsResolved: false` - a ref is missing locally, so every field below came from a failed `git diff` that returns empty. Stop and report which ref; do not drop findings on this JSON.
- `headFromPullRef: false` with `crossRepo: true` - the pull ref was not fetched, so the helper fell back to `origin/{headRefName}`, which for a fork does not name the PR's head at all. When that name collides with a branch this origin already has (`main` and `develop` collide constantly) the ref resolves, base and head land on the same commit, and **every** candidate reads `touchedByPr: false`. Fetch the pull ref and re-run rather than trusting the result.
- Either condition unhandled ends the same way: a confident `0 inline + 0 top-level` on a PR nobody actually reviewed.

**4a. Diff-scope verification:** apply `.claude/docs/pr-review-verification.md` §2, reading `touchedByPr` and `inBase` from that JSON rather than re-deriving them. `touchedByPr: false` means the PR did not touch the path at all; `inBase: true` with an unchanged line means the issue pre-dates this PR. A candidate with `inBase: false` **and** `inHead: false` names a path at neither ref - that is a bad citation, not a new file, so drop the finding as unverifiable rather than as pre-existing. Drop genuine pre-existing issues silently (score < 50) - common false alarm: flagging a shared helper's side effects when the PR only touched an unrelated code path.

**4b. Verify code matches description:** apply `.claude/docs/pr-review-verification.md` §3 against `headExcerpt`. Drop or downgrade findings where the agent's prose does not match the file at the referenced line.

### 4c. Build the private outgoing-comment record

Every candidate that might become a GitHub inline draft gets one compact private record:

```text
Claim:
Diff evidence:
Introduced by this PR:
Why / consequence:
Authority:
Caller / dependency impact:
Verification performed:
Existing-comment dedupe:
Confidence:
Severity:
Kind:
Disposition:
safe_defer:
must_not_merge_reason:
Publish decision:
```

Use `not applicable` when a field genuinely does not apply; never invent caller impact, a project rule, or verification. The record stays private. GitHub text receives only the minimum non-sensitive evidence needed to explain the claim. Never copy tokens, credentials, secret values, unredacted scanner matches, private Confluence excerpts, or unnecessary internal URLs into a draft.

Authority order has two layers:

1. **Binding behavior and facts:** acceptance criteria; security, privacy, correctness, data, and public-contract invariants; exact-version API/platform behavior; executable compiler, linter, formatter, and schema rules.
2. **Style and design guidance:** explicit review focus; mandatory repo instructions and documented project conventions; relevant adjacent patterns and KB decisions; official general best practice; reviewer preference.

Binding behavior wins over style guidance. Within style/design, repo authority and relevant local patterns win over general guidance; personal preference never produces a comment. General best-practice sources can support only `suggestion (non-blocking)` or `nit (non-blocking)` and must still pass the kind-specific gate; they never justify a blocking issue. Policy basis: [Google review comments](https://google.github.io/eng-practices/review/reviewer/comments.html), [Google review standard](https://google.github.io/eng-practices/review/reviewer/standard.html), [GitLab code review guidelines](https://docs.gitlab.com/development/code_review/), and [Conventional Comments](https://conventionalcomments.org/).

### 4d. Classify independent axes

Keep these independent:

- `confidence`: evidence certainty, 0-100.
  - **< 50:** false positive, pre-existing, unsupported, or preference-only - drop.
  - **50-79:** discussion only, or `question (needs-answer)` after the research ladder is exhausted. Do not draft an assertion.
  - **≥ 80:** assertion is eligible for a draft only after the kind-specific gate below passes.
- `severity`: impact, one of `critical | high | medium | low`.
- `kind`: `issue | suggestion | nit | question`.
- `disposition`: `blocking | non-blocking | needs-answer`.

High confidence does not raise severity. A confidence-95 nit is still low-severity and non-blocking. Only `issue` may be blocking.

Apply explicit review focus before the kind gates. `focus on bugs only` permits GitHub drafts only for `issue` candidates that assert a concrete behavior defect after research; suppress `suggestion`, `nit`, and `question` drafts. A material unresolved question may remain in chat and still affect the verdict, but does not become a GitHub draft. `skip nitpicks` suppresses all nit drafts.

An `issue (blocking)` requires every condition below:

- introduced by this PR
- confidence ≥ 80
- concrete failure mode or binding-policy violation
- `safe_defer: no` with evidence
- explicit `must_not_merge_reason`

Confirmed build/compile failure, broken required acceptance criteria, security/privacy/data-integrity violation, public-contract break, or unsafe deploy/migration/rollback can qualify. Missing tests alone cannot; it becomes blocking only when a risky behavior lacks the minimum evidence required to merge safely.

A `nit (non-blocking)` requires every condition below:

- explicit focus does not say `focus on bugs only` or `skip nitpicks`
- introduced by this PR and anchored to a changed line
- confidence ≥ 80 and low severity
- repo authority, a relevant adjacent pattern, or a concrete readability/maintainability benefit
- not already caught by an available formatter/linter
- local and cheap to fix, not a disguised refactor or personal preference

A `question` is allowed only after code, tests, config, history, and available docs cannot answer a verified premise. Use `question (needs-answer)` when the answer affects the merge verdict; otherwise use `question (non-blocking)`.

Collapse the same root cause or repeated nit pattern into one representative comment and name sibling occurrences briefly. Track dropped candidates for the Step 6 summary.

## Step 5 - Auto-deep-dive and research

Before presenting findings, proactively trace anything whose confidence depends on behavior outside the diff.

### 5a. Identify deep-dive candidates

Scan the classified candidates (from Step 4) and flag any that meet these criteria:
- **Opaque handoff**: the diff passes a value to a service, library, or repository method whose behavior for the new input is unknown from the diff alone (e.g., a string that used to be an enum value is now passed as a free-form name - does the callee handle it?)
- **Cross-boundary assumption**: the finding assumes something about a caller, downstream consumer, or deployment environment that isn't visible in the diff
- **Pattern divergence**: the diff follows a pattern from another controller/service but omits a step that the reference implementation includes (e.g., a validation, a Content check, a type conversion) - unclear if the omission is intentional or a gap
- **Activation-PR scope**: the PR is the last in a multi-PR migration that activates dormant infrastructure from earlier PRs. Small diff, large blast radius. Walk every newly live entry point, cross-boundary auth/scope check, and test path that becomes load-bearing only with this PR. If a scoping gap is found, recommend splitting activation so the fix lands before the seed.
- **Transitive CI/workflow guarantee**: a small CI/workflow YAML diff whose correctness rests on a guarantee outside the diff - an external action's source/await-semantics, an SDK exit-code contract, or a file fetched at runtime. The diff looks trivial but the load-bearing behavior lives elsewhere; trace it before accepting the author's justification.

Goal: trace when it can move a finding to confirmed or dropped.

### 5b. Trace implementations

For each deep-dive candidate, spawn an Explore agent (role: worker) to trace the code path. Give each agent:
- **The spawn directive from `.claude/docs/pr-review-verification.md` §13, copied verbatim into the prompt.** A spawned subagent does not load that doc, so the block has to travel inline; paraphrasing it per site is what let three spawn sites drift. It carries §11 diff-first investigation, the pinned-revision rule, and the §12 trace-shape self-check.
- The specific question to answer (e.g., "does `DashboardService.GetDashboardAsync` do `Enum.TryParse` internally when it receives a non-enum sourceType string?")
- Where to look (the implementation repo if known from KB, NuGet package source, or the current repo)
- What to report: the concrete code path, whether the concern is confirmed or refuted, and evidence (file:line)

Run traces in parallel. If source is unavailable, keep as "ask the author" and say what could not be verified.

### 5c. Update findings with evidence

For each deep-dive result:
- **Confirmed bug**: raise confidence and severity independently when the evidence supports each, then add the evidence trail
- **Refuted concern**: drop it (score < 50) or downgrade to informational
- **New finding discovered during trace**: add it as a new candidate with its own outgoing-comment record
- **Inconclusive** (no source available): mark it `question (needs-answer)` only when the answer affects the verdict; otherwise keep it in chat as non-blocking or drop it
- **Requires domain knowledge**: keep as a `question` for product/deployment/business intent

### 5d. Research remaining open questions

For any findings not covered by deep-dive (already high-confidence, or not implementation-dependent):
- **GitHub**: search code, read related PRs, check git history for the same files
- **Confluence**: search for design docs, feature trackers, or onboarding pages relevant to the changed area
- **Result**: either confirm the issue with evidence, or downgrade it to "ask the author"

## Step 5.5 - Test verification recommendation

Follow the matrix algorithm in `.claude/docs/verification-matrix.md` - context detection (§1), layered rows (§2), per-row fields (§3), plan-presence scan (§4).

Skill-specific outputs:
- Render the resulting matrix + critical-layer + caveat + plan-status as the **Verification block** in Step 6 (right after the summary line, before the scorecard).
- If §4 reports "no plan at all" for any non-trivial change: emit a medium-severity `suggestion (non-blocking)` under Testability tagged `Verification gap`, with the full matrix pasted into the inline-comment draft so the author can lift it into the PR body verbatim.
- Strictness ceiling: medium severity and non-blocking. Reviewers decide whether to gate.

**Rewrite-of-correctness-critical-impl flag (differential-oracle gate):** when the PR *replaces* an existing correctness-critical implementation (parser, query translator, serializer, EF-query builder, aggregation/pricing fn, protocol codec) - especially AI-authored or a port across languages - new unit tests are not a sufficient bar. Ask: "where is the differential oracle?" If the legacy impl still exists and the PR does not diff new-vs-old over a generated/replayed corpus (and, for high-traffic read paths, run shadow-mode with a zero-divergence gate before cutover), emit a medium-severity `suggestion (non-blocking)` under Testability tagged `Verification gap (no differential oracle)`. Source: `workspace/kb/general/llm.md §2026-06-24 - Differential-oracle harness`. The strictness ceiling stays medium severity and non-blocking.

## Step 5.7 - Doubt cycle

Run a bounded fresh-context review for every blocking candidate plus non-obvious correctness, incompletely traced cross-boundary behavior, irreversible blast radius, or a severity upgrade based on inference. Skip style nits, mechanical edits, and claims already fully grounded in the diff.

For each in-scope finding:

1. **CLAIM** - record the claim and blast radius internally.
2. **EXTRACT** - build an `ARTIFACT + CONTRACT` bundle. Include cited hunks and traced code, but omit the claim, severity, and prior reasoning.
3. **DOUBT** - run one bounded independent pass. Return `DOUBT_RESULT` and `CONTRACT_GAPS`.
4. **RECONCILE** - classify results in this order: contract misread, valid/actionable, valid trade-off, noise. Fix an incomplete contract and re-loop.
5. **STOP** - stop when only trivial/already-considered results remain, after 3 cycles, or when the user says to proceed. Escalate before a fourth cycle.

Run the DOUBT pass as `Mode: finding-doubt` - read `.claude/docs/review-mode-finding-doubt.md` plus the shared contract in `.claude/docs/review-modes.md` in a fresh-context read-only subagent, passing only `ARTIFACT + CONTRACT`. Omitting the claim and the severity is the whole mechanism: a reviewer that already knows the expected answer cannot independently doubt it.

Write the bundle to a file and pass the path. Never interpolate diff text into a shell argument - the diff carries whatever a contributor wrote.

The DOUBT pass runs in the background, so keep working in the same turn instead of waiting on it. None of the Step 6 preparation depends on its verdict: the Jira fetch and four-pillar Sense Check, the Step 5.5 verification matrix, and the scorecard all read the diff, the ticket, and the repo. Doing them while the verifier runs is what keeps the review one continuous pass rather than a status line and a dead turn.

Before Step 6, report: `doubt: {N} findings reviewed, {K} cycles, {M} upgraded, {R} refuted, {P} contract-misreads fixed`.
