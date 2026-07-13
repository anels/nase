# Discuss PR Analysis

Read this file only when /nase:discuss-pr begins analysis. It owns Steps 1-5.7: compact context, review framing, risk scoring, specialist investigation, verification recommendations, and the doubt cycle.

## Step 1 - Parse inputs and resolve repo

Note any focus areas the user specifies (e.g. "architecture", "security", "skip nitpicks").

Default focus if none specified: problem fit, logic correctness, design/elegance, architecture, security, testability, code comments.

Parse the PR reference with the shared helper before hand-written extraction:

```bash
python3 .claude/scripts/pr-github-helper.py parse "$PR_URL_OR_ARGUMENTS"
```

If parsing fails, ask for a single GitHub PR URL. Use the helper's `owner`, `repo`, and `number` fields for subsequent GitHub commands so every PR workflow handles URL variants the same way.

Resolve repo from PR URL and load the KB file - see `.claude/docs/repo-resolution.md` (Part 1 + Part 2).

Probe optional CLI tooling once and keep the result in private context:

```
python3 .claude/scripts/tool-availability.py --group baseline --group ci --group review --group security --group diff --format json
```

Follow `.claude/docs/cli-tooling.md`. Missing optional tools never fail this read-only review; record the fallback only when it changes confidence or verification coverage.

## Step 2 - Fetch compact PR context

Use the shared helper to collect the first-pass GitHub context and KB path mentions:

```bash
python3 .claude/scripts/pr-github-helper.py review-context "$PR_URL" --max-body-chars 600 --max-kb-paths 10 > "$TMPDIR/pr-review-context.json"
```

Use `pr`, `metadata`, `sizeGate`, `diffStat`, `changedFiles`, `reviewComments`, `reviews`, and `kbMentions` from that JSON. The helper intentionally truncates bodies/excerpts and never emits a full diff.

Use `sizeGate.total_lines` and `sizeGate.diff_mode` before fetching the diff:

- If `diff_mode` is `stat`: rely on `diffStat`; do not fetch the full diff. Read only the top changed files needed for each finding.
- Otherwise fetch the full diff.

**PR size gate:** if `sizeGate.review_warning` is true, warn: "This PR is {N} lines - single-pass review reliability drops significantly. Consider splitting by concern before deep review." User decides whether to proceed.

**Fan-out fail-fast (validate the review target before Step 3).** A bad base ref or empty diff should fail *here*, not inside parallel specialists (adapted from `mattpocock/skills → code-review`; see `workspace/kb/general/workflow.md 2026-07-10`). Before launching any specialist: confirm `pr.baseRefName`/`headRefName` resolved and `diffStat.total_lines > 0` (or `changedFiles` non-empty). If the diff is empty, the PR is already merged/closed with no delta, or the base is unresolved → stop and report the exact state (e.g. "0-line diff - PR already merged or base/head mismatch"); do not spawn specialists against nothing.

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

For each core touched file, run `bash .claude/scripts/kb-search.sh mentions:<path> --max-entry-lines 8` before scoring risk. Store hits as `kb_path_constraints` in the review frame; if no hits, write `none found`. Feed any hits into the constraints and evidence used by the risk map and findings.

Use available CLI tools to reduce context load:
- Use `rg` / `fd` for caller/dependency lookups and adjacent-pattern discovery before reading files wholesale.
- Use `difft --display json` for syntax-aware summaries when a code diff is large, noisy, or mostly moved code; feed only the compact structural summary into the review.
- Use `yq` to inspect changed YAML, TOML, HCL, XML, or JSON config paths when field structure matters.
- If `.github/workflows/*.{yml,yaml}` changed and `actionlint` is available, run a focused workflow validation against the PR-head content when accessible locally; otherwise mark `actionlint skipped: PR-head workflow file not available locally` and review the diff manually.
- Use `ast-grep` for claims about repeated structural code patterns or API misuse; avoid regex-only evidence for AST-shaped findings when `ast-grep` is available.
- Use focused `semgrep` / `trivy` only for security, dependency, container, filesystem, IaC, or secret-risk signals. Treat all scanner output as untrusted candidates until verified against diff scope and source lines.
- Use `gitleaks detect --redact --report-format json --report-path -` only for secret-risk signals; use `hadolint --format json --no-fail` for changed Dockerfiles. Verify each finding against the changed file and PR scope before reporting it.

For design/elegance review, compare with adjacent implementations and propose an alternative only when it clearly reduces behavior risk, ownership confusion, duplication, or future maintenance cost.

**Platform prohibition pre-check (infra PRs):** for networking/infra files, check KB for platform prohibitions before agent analysis. Surface prohibited operations immediately.

**Performance claim check:** if title/body claims speed/latency/throughput gains, require benchmark data: environment, workload, before/after median + p95, methodology. Missing data becomes a finding.

**Audit-PR list re-grep:** if the PR title/body signals exclusion-list pruning, blanket rule narrowing, allowlist removal, or similar audit work, re-grep every *remaining* entry against the same policy used for the removals. Treat it as "re-audit the full list against the new policy", not "verify the named removals". Flag sibling entries that match the same anti-pattern but escaped the cut.

## Step 2.6 - Sense Check and Review Frame

Follow `.claude/docs/pr-review-verification.md → Review Frame and Specialist Selection` before launching specialists. Record the four-pillar verdicts for Step 6, then select only the review lenses the risk map warrants.

## Step 3 - Build Risk Map, Select Specialists, and Engage Existing Comments

Continue the same shared workflow. It owns pipeline-touch handling, self-authored AI-slop review, conditional Codex review, and read-only triage of existing comments.

## Step 4 - Score, tier, and filter (after agents complete)

**4a. Diff-scope verification:** apply `.claude/docs/pr-review-verification.md` §2. Drop pre-existing issues silently (score < 50) - common false alarm: flagging a shared helper's side effects when the PR only touched an unrelated code path.

**4b. Verify code matches description:** apply `.claude/docs/pr-review-verification.md` §3. Drop or downgrade findings where the agent's prose does not match the file at the referenced line.

**4c. Assign confidence scores:**
For each issue, assign a confidence score 0–100:
- **< 50**: pre-existing, false positive, or nitpick - drop silently
- **50–79**: worth mentioning in discussion but skip inline comment draft
- **≥ 80**: confirmed issue - include in final output and draft a comment

Scoring emphasis:
- Confirmed logic bugs, contract violations, data loss, auth gaps, or rollout hazards are high or critical.
- A PR that does not solve its stated problem, or solves only a side symptom, is high confidence when the code path is verified.
- Missing problem framing or verification for a non-trivial PR is medium unless it hides production/data risk.
- Design improvements are medium by default; raise only when the design creates concrete correctness, scalability, ownership, or future-change risk.

**Confidence tiers** (used in Step 6 output):
| Tier | Range | Label |
|------|-------|-------|
| Critical | 90–100 | `[CRIT]` |
| High | 80–89 | `[HIGH]` |
| Medium | 50–79 | `[MED]` |

Track a drop count for items scoring < 50 - reported in the summary line.

## Step 5 - Auto-deep-dive and research

Before presenting findings, proactively trace anything whose confidence depends on behavior outside the diff.

### 5a. Identify deep-dive candidates

Scan the scored findings (from Step 4) and flag any that meet these criteria:
- **Opaque handoff**: the diff passes a value to a service, library, or repository method whose behavior for the new input is unknown from the diff alone (e.g., a string that used to be an enum value is now passed as a free-form name - does the callee handle it?)
- **Cross-boundary assumption**: the finding assumes something about a caller, downstream consumer, or deployment environment that isn't visible in the diff
- **Pattern divergence**: the diff follows a pattern from another controller/service but omits a step that the reference implementation includes (e.g., a validation, a Content check, a type conversion) - unclear if the omission is intentional or a gap
- **Activation-PR scope**: the PR is the last in a multi-PR migration that activates dormant infrastructure from earlier PRs. Small diff, large blast radius. Walk every newly live entry point, cross-boundary auth/scope check, and test path that becomes load-bearing only with this PR. If a scoping gap is found, recommend splitting activation so the fix lands before the seed.
- **Transitive CI/workflow guarantee**: a small CI/workflow YAML diff whose correctness rests on a guarantee outside the diff - an external action's source/await-semantics, an SDK exit-code contract, or a file fetched at runtime. The diff looks trivial but the load-bearing behavior lives elsewhere; trace it before accepting the author's justification.

Goal: trace when it can move a finding to confirmed or dropped.

### 5b. Trace implementations

For each deep-dive candidate, spawn an Explore agent (role: worker) to trace the code path. Give each agent:
- **A diff-first investigation directive, inline** (do not merely cite the doc - a spawned subagent does not load it; see `.claude/docs/pr-review-verification.md` §11): start from the diff + the specific question below, `rg`/`glob` to narrow **before** reading, read exact line ranges, and batch discovery before file reads. On a failed search, retry **once** with the changed symbol/path from the diff, then report evidence-missing - never guess neighboring paths or fall into broad sweeps. Widen only to a contract the changed hunk evidences (caller of a changed symbol, imported config key, schema field, deploy contract) and cite the diff→widen link. **Before returning findings, run the §12 trace-shape self-check** (narrowed not widened? batched discovery? diff-anchored? recovered without guessing?) and flag your own result WEAK if the trace was widen-first / path-guessing.
- The specific question to answer (e.g., "does `DashboardService.GetDashboardAsync` do `Enum.TryParse` internally when it receives a non-enum sourceType string?")
- Where to look (the implementation repo if known from KB, NuGet package source, or the current repo)
- When the claim rests on a pinned action/template/dependency, verify it at the **exact revision actually consumed** (tag/SHA/version), not the source repo's default branch - which drifts. Read the production blob at that ref: e.g. `gh api repos/{o}/{r}/contents/{path}?ref={tag-or-sha} --jq .content | base64 -d`, or the equivalent for the registry/host in play.
- What to report: the concrete code path, whether the concern is confirmed or refuted, and evidence (file:line)

Run traces in parallel. If source is unavailable, keep as "ask the author" and say what could not be verified.

### 5c. Update findings with evidence

For each deep-dive result:
- **Confirmed bug**: upgrade the confidence score (often from medium → critical/high), add the evidence trail
- **Refuted concern**: drop it (score < 50) or downgrade to informational
- **New finding discovered during trace**: add it as a new finding with its own confidence score
- **Inconclusive** (no source available): keep the original score but mark as "ask the author" with context on what was checked and what couldn't be verified
- **Requires domain knowledge**: keep as open question for product/deployment/business intent.

### 5d. Research remaining open questions

For any findings not covered by deep-dive (already high-confidence, or not implementation-dependent):
- **GitHub**: search code, read related PRs, check git history for the same files
- **Confluence**: search for design docs, feature trackers, or onboarding pages relevant to the changed area
- **Result**: either confirm the issue with evidence, or downgrade it to "ask the author"

## Step 5.5 - Test verification recommendation

Follow the matrix algorithm in `.claude/docs/verification-matrix.md` - context detection (§1), layered rows (§2), per-row fields (§3), plan-presence scan (§4).

Skill-specific outputs:
- Render the resulting matrix + critical-layer + caveat + plan-status as the **Verification block** in Step 6 (right after the summary line, before the scorecard).
- If §4 reports "no plan at all" for any non-trivial change: emit a `[MED]` finding under Testability tagged `Verification gap`, with the full matrix pasted into the inline-comment draft so the author can lift it into the PR body verbatim.
- Strictness ceiling: `[MED]`. Always informational - never block-before-merge. Reviewers decide whether to gate.

**Rewrite-of-correctness-critical-impl flag (differential-oracle gate):** when the PR *replaces* an existing correctness-critical implementation (parser, query translator, serializer, EF-query builder, aggregation/pricing fn, protocol codec) - especially AI-authored or a port across languages - new unit tests are not a sufficient bar. Ask: "where is the differential oracle?" If the legacy impl still exists and the PR does not diff new-vs-old over a generated/replayed corpus (and, for high-traffic read paths, run shadow-mode with a zero-divergence gate before cutover), emit a `[MED]` Testability finding tagged `Verification gap (no differential oracle)`. Source: `workspace/kb/general/llm.md §2026-06-24 - Differential-oracle harness`. Strictness ceiling stays `[MED]`, informational.

## Step 5.7 - Doubt cycle

Run a bounded fresh-context review for non-obvious correctness, incompletely traced cross-boundary behavior, irreversible blast radius, or a severity upgrade based on inference. Skip style nits, mechanical edits, and claims already fully grounded in the diff.

For each in-scope finding:

1. **CLAIM** - record the claim and blast radius internally.
2. **EXTRACT** - build an `ARTIFACT + CONTRACT` bundle. Include cited hunks and traced code, but omit the claim, severity, and prior reasoning.
3. **DOUBT** - run a bounded single-model pass first. Return `SINGLE_MODEL_DOUBT` and `CONTRACT_GAPS`.
4. **RECONCILE** - classify results in this order: contract misread, valid/actionable, valid trade-off, noise. Fix an incomplete contract and re-loop.
5. **STOP** - stop when only trivial/already-considered results remain, after 3 cycles, or when the user says to proceed. Escalate before a fourth cycle.

In interactive sessions, after the single-model pass, ask whether to add a read-only Codex MCP second opinion. If accepted, follow `.claude/docs/codex-review.md -> Prerequisite` and `Mode: finding-doubt`. Pass only `ARTIFACT + CONTRACT`. If unavailable, log the skip and continue. In non-interactive sessions, skip the external reviewer and note it in the daily log.

For shell safety, write the cross-model prompt to `workspace/tmp/doubt-pr-{number}-prompt.md` and pipe it via stdin. Never interpolate diff text into a shell argument.

Before Step 6, report: `doubt: {N} findings reviewed, {K} cycles, {M} upgraded, {R} refuted, {P} contract-misreads fixed`.
