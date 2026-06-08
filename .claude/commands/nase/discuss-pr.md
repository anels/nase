---
name: nase:discuss-pr
description: "Read-only PR analysis — first identifies what problem the PR solves in larger repo/product context, then checks logic correctness, design quality, simpler implementation options, security, and testability before drafting inline comments without posting or changing code. Use when reviewing a PR for the first time, doing a self-review, or preparing comments. Triggers: 'analyze PR', 'self-review', 'prepare review comments', 'review PR #N', PR URL + 'review without posting'. For acting on existing reviewer feedback (fix code + push), use /nase:address-comments instead."
pattern: fan-out
---

## Language

Read `workspace/config.md`: `conversation:` for chat/questions, `output:` for GitHub text.

## Review stance

Default question order:

1. What problem is this PR solving, for which users/components, and why now?
2. Does the implementation actually satisfy that intent across the changed code paths?
3. Does the design fit the larger system boundaries, ownership, and adjacent patterns?
4. Is there a simpler, more coherent implementation that reduces risk or maintenance cost?
5. Are tests, security checks, and PR hygiene sufficient for the risk level?

Keep findings anchored to the PR's intent. Drop unrelated pre-existing issues. Treat "more elegant" as actionable only when the alternative is concretely simpler, safer, easier to test, or a better fit with existing patterns.

## Phase 0 — Input Guard

Follow the PR input guard in `.claude/docs/pr-input-guard.md`. If `$ARGUMENTS` is empty, ask the user for the PR URL instead of printing usage.

## Step 1 — Parse inputs and resolve repo

Note any focus areas the user specifies (e.g. "architecture", "security", "skip nitpicks").

Default focus if none specified: problem fit, logic correctness, design/elegance, architecture, security, testability, code comments.

Parse the PR reference with the shared helper before hand-written extraction:

```bash
python3 .claude/scripts/pr-github-helper.py parse "$PR_URL_OR_ARGUMENTS"
```

If parsing fails, ask for a single GitHub PR URL. Use the helper's `owner`, `repo`, and `number` fields for subsequent GitHub commands so every PR workflow handles URL variants the same way.

Resolve repo from PR URL and load the KB file — see `.claude/docs/repo-resolution.md` (Part 1 + Part 2).

Probe optional CLI tooling once and keep the result in private context:

```
python3 .claude/scripts/tool-availability.py --group baseline --group ci --group review --group security --group diff --format json
```

Follow `.claude/docs/cli-tooling.md`. Missing optional tools never fail this read-only review; record the fallback only when it changes confidence or verification coverage.

## Step 2 — Fetch PR metadata and existing comments

Fetch PR metadata using the helper's **light** variant, which centralizes the field set from `.claude/docs/github-queries.md`:

```bash
python3 .claude/scripts/pr-github-helper.py metadata "$PR_URL" --variant light > "$TMPDIR/pr-metadata.json"
python3 .claude/scripts/pr-github-helper.py size-gate --metadata "$TMPDIR/pr-metadata.json" > "$TMPDIR/pr-size-gate.json"
```

Use `total_lines` and `diff_mode` from the size gate before fetching the diff:

- If `diff_mode` is `stat` (default once the PR exceeds 1500 changed lines): run `gh pr diff {pr_number} --repo {owner}/{repo} --stat`; do not fetch the full diff. Read only the top changed files needed for each finding.
- Otherwise fetch the full diff.

Also run in parallel:

```
gh api "repos/{owner}/{repo}/pulls/{pr_number}/comments" --paginate
gh api "repos/{owner}/{repo}/pulls/{pr_number}/reviews" --paginate
```

Save: title, body, head SHA, changed file list, full diff or diff stat, existing inline comments (with `id`, `path`, `line`, `body`, `user.login`, `in_reply_to_id`), existing reviews (with `id`, `state`, `body`, `user.login`).

**PR size gate:** if `review_warning` is true, warn: "This PR is {N} lines — single-pass review reliability drops significantly. Consider splitting by concern before deep review." User decides whether to proceed.

Group comments into threads: top-level comment + all replies sharing the same `in_reply_to_id`.

## Step 2.5 — Collect context

Before judging the implementation, write a private review frame. Use it to guide the rest of the review and show it in the final answer.

Answer:

- What problem, symptom, risk, or product gap does this PR claim to solve?
- What is the old behavior, and why is it insufficient?
- What is the new approach, and which changed files are core vs incidental?
- What larger workflow, service boundary, data contract, deployment path, or user path does this touch?
- What constraints should shape the solution: compatibility, feature flags, migration order, observability, performance, ownership, or rollout safety?

If the PR body does not explain the problem, infer carefully from the title, commits, changed files, tests, linked issue references, and nearby git history. Mark the problem as `unclear` instead of inventing intent. Missing or ambiguous problem framing is a review finding for non-trivial PRs.

For each core touched file, read key dependencies/callers needed to judge design intent. Separate core behavioral files from tests, generated files, formatting-only changes, and incidental wiring. Cross-reference KB and relevant Confluence docs.

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

## Step 3 — Build risk map, select specialists, and engage existing comments

Before launching any specialist agents, build a private risk map. This avoids running every specialist on every PR.

Risk map rows:

| Area | Signals | Risk | Specialist(s) |
|------|---------|------|---------------|
| Problem fit | unclear body, linked issue mismatch, core path not touched | low/med/high | Problem fit |
| Logic | state transitions, null/default changes, async, retries, persistence | low/med/high | Logic correctness |
| Design | new abstraction, duplicated flow, changed boundary, many files | low/med/high | Design/elegance, Architecture |
| Security | auth, tenant isolation, secrets, external input, telemetry export | low/med/high | Security |
| Verification | non-trivial behavior, missing tests, migration/deploy path | low/med/high | Testability |
| Review history | recurring comments, same files recently reverted, old decisions | low/med/high | Git history |
| Comments/docs | comments changed or code contradicts existing comments | low/med/high | Code comments |
| Pipeline/data | ETL, SQL, EventHub/Queue/Timer, LookerML, Avro/Parquet | low/med/high | Pipeline gates |

Selection rule:
- Always cover `Problem fit`, `Logic correctness`, and `Testability` in the main review pass.
- Spawn a specialist only when its risk row is `med` or `high`, or the user explicitly requested that focus.
- Skip `Security`, `Git history`, `Code comments`, and `Pipeline gates` when their trigger signals are absent.
- Run Codex second-opinion only for high-risk PRs, security-sensitive PRs, large diffs, unfamiliar core areas, or explicit user request.
- Show the selected specialist list in the final output so omissions are auditable.

**Pipeline-touch detection:** if diff touches `*.sql`, ETL/ingestion/aggregation paths, Avro/Parquet, Databricks notebooks, LookerML, or EventHub/Queue/Timer Functions, add the Pipeline gates agent.

| Agent | Focus |
|-------|-------|
| **Problem fit** | Whether the PR solves the framed problem end-to-end without overreaching or leaving the main gap open |
| **Logic correctness** | Branch conditions, state transitions, null/default behavior, async/race risks, idempotency, data loss, bad fallbacks |
| **Design/elegance** | Whether a simpler local pattern, clearer API boundary, smaller abstraction, or less duplicated flow would solve the same problem better |
| **Architecture** | DRY violations, KISS violations, layering issues, SRP violations, abstraction quality |
| **Security** | Input validation, header injection, credential exposure, SSRF, auth bypass risks |
| **Testability** | Missing coverage for new paths, tests that only chase signatures, untestable designs. **Also emit a verification-bar recommendation** (see Step 5.5 classification) and check the PR body for a test plan section — if absent for any non-trivial change, emit a `[MED]` finding tagged `Verification gap`. |
| **Git history** | Patterns rejected in past PRs, recurring comments on the same files, regressions |
| **Code comments** | Violations of guidance in inline comments, stale or contradicted comments |
| **Pipeline gates** (conditional) | Three Meta-style gates for pipeline changes — see below |
| **Codex second-opinion** (conditional) | Cross-model pass via Codex MCP — see below |

**Pipeline gates agent** — spawn only when pipeline-touch detected:

1. **Correctness** — does the PR show evidence of row-count + checksum + business-aggregate comparison vs the prior pipeline on a representative window (≥ 7 days of partitions)? Acceptable evidence: backfill diff log linked in PR body, a comparison query referenced in description, a validation test added. Missing → flag as 🔧 needs-fix with severity proportional to blast radius.
2. **Landing latency** — does the change risk regressing landing latency vs legacy? Look for: new joins on large tables without explicit index, removed parallelism, additional serial waits, new external calls in the hot path. Flag candidates and ask author for evidence (perf test result, EXPLAIN ANALYZE, prior-run timing).
3. **Resource utilization** — does the change increase compute / IO / cost vs legacy? Look for: new full scans, removed pushdown filters, larger shuffle, additional materialization, more aggressive retry. Flag candidates and ask author for evidence (warehouse credit estimate, DBU diff, query profile).

Output exactly the three gates plus per-gate verdict: ✅ evidenced / ⚠️ unclear / 🔧 missing. If any gate is 🔧 missing for a production pipeline, score as `[HIGH]` (≥80) at minimum.

**Codex second-opinion agent** — conditional per the risk-map selection rule above. Gate per `.claude/docs/codex-review.md → Prerequisite`; skip cleanly if MCP is not loaded:

- `cwd` = absolute repo path
- `prompt` = `{repo_name} / PR #{pr_number} — {pr_title}`, PR diff (or diff stat + top changed file snippets for PRs >5000 lines), and one-line summary of each queued Claude finding so Codex looks for new angles without duplicates
- `developer-instructions` = the `review` template verbatim, with `{focus_areas}` set to the same focus list passed to the Claude specialists
- `sandbox` = `read-only`

Run Codex in parallel. Parse `[SEV] file:line — issue. Fix: action.`, score via Step 4, tag `[codex]`; if Claude and Codex flag same file/line, tag `[claude+codex]` and add +10 confidence capped at 100.

**While agents run — triage existing comments** (if any):

Auto-classify unresolved threads and present a confirmation table:

| # | File:Line | Author | Summary | Auto-classification |
|---|-----------|--------|---------|-------------------|
| 1 | `foo.ts:42` | @alice | "null check missing" | 🔧 needs-fix |
| 2 | `bar.ts:10` | @bob | "why not use X?" | 💬 needs-reply |
| 3 | `baz.ts:99` | @alice | "nit: rename" | ✅ can-resolve |

Classification rules:
- 🔧 **needs-fix** — reviewer identified a concrete defect or missing guard; code change required
- 💬 **needs-reply** — a question or design discussion; reply needed, may or may not require code change
- ✅ **can-resolve** — nit/style/already addressed; safe to resolve without action
- 🔍 **needs-research** — unclear without more context; look into code or Confluence before deciding

Ask "Does this look right? Any to change?" Research each 🔍 item before final classification.

Apply `.claude/docs/pr-review-verification.md` §4 and §5 on every classification pass.

**Bot-comment batch-verify (read-only):** when the PR has ≥10 prior bot inline comments with concrete file:line claims, spawn one investigator agent for a single-pass table: `file:line | claim text | state`, where state is `CONFIRMED` / `FIXED` / `WRONG` / `INCONCLUSIVE` for the PR's current head. Cite the table for context; do not echo confirmed claims as net-new findings. This gate stays read-only — reactions, replies, and resolves remain gated by Step 7 / Step 8.

**Duplicate-of-N reframe check:** when a candidate finding would be dismissed as "duplicate of PR #N" or "superseded by #N", open #N's body + commits first. If #N explicitly defers the surface now being changed (`This PR does NOT change X`, unchecked `[ ]` items, "follow-up planned"), the PRs are complementary, not duplicate — the finding stands.

Collect the final classifications. **Do not post reactions or replies yet** — batched into Step 8, posted only on explicit request.

## Step 4 — Score, tier, and filter (after agents complete)

**4a. Diff-scope verification:** apply `.claude/docs/pr-review-verification.md` §2. Drop pre-existing issues silently (score < 50) — common false alarm: flagging a shared helper's side effects when the PR only touched an unrelated code path.

**4b. Verify code matches description:** apply `.claude/docs/pr-review-verification.md` §3. Drop or downgrade findings where the agent's prose does not match the file at the referenced line.

**4c. Assign confidence scores:**
For each issue, assign a confidence score 0–100:
- **< 50**: pre-existing, false positive, or nitpick — drop silently
- **50–79**: worth mentioning in discussion but skip inline comment draft
- **≥ 80**: confirmed issue — include in final output and draft a comment

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

Track a drop count for items scoring < 50 — reported in the summary line.

## Step 5 — Auto-deep-dive and research

Before presenting findings, proactively trace anything whose confidence depends on behavior outside the diff.

### 5a. Identify deep-dive candidates

Scan the scored findings (from Step 4) and flag any that meet these criteria:
- **Opaque handoff**: the diff passes a value to a service, library, or repository method whose behavior for the new input is unknown from the diff alone (e.g., a string that used to be an enum value is now passed as a free-form name — does the callee handle it?)
- **Cross-boundary assumption**: the finding assumes something about a caller, downstream consumer, or deployment environment that isn't visible in the diff
- **Pattern divergence**: the diff follows a pattern from another controller/service but omits a step that the reference implementation includes (e.g., a validation, a Content check, a type conversion) — unclear if the omission is intentional or a gap
- **Activation-PR scope**: the PR is the last in a multi-PR migration that activates dormant infrastructure from earlier PRs. Small diff, large blast radius. Walk every newly live entry point, cross-boundary auth/scope check, and test path that becomes load-bearing only with this PR. If a scoping gap is found, recommend splitting activation so the fix lands before the seed.

Goal: trace when it can move a finding to confirmed or dropped.

### 5b. Trace implementations

For each deep-dive candidate, spawn an Explore agent (role: worker) to trace the code path. Give each agent:
- The specific question to answer (e.g., "does `DashboardService.GetDashboardAsync` do `Enum.TryParse` internally when it receives a non-enum sourceType string?")
- Where to look (the implementation repo if known from KB, NuGet package source, or the current repo)
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

## Step 5.5 — Test verification recommendation

Follow the matrix algorithm in `.claude/docs/verification-matrix.md` — context detection (§1), layered rows (§2), per-row fields (§3), plan-presence scan (§4).

Skill-specific outputs:
- Render the resulting matrix + critical-layer + caveat + plan-status as the **Verification block** in Step 6 (right after the summary line, before the scorecard).
- If §4 reports "no plan at all" for any non-trivial change: emit a `[MED]` finding under Testability tagged `Verification gap`, with the full matrix pasted into the inline-comment draft so the author can lift it into the PR body verbatim.
- Strictness ceiling: `[MED]`. Always informational — never block-before-merge. Reviewers decide whether to gate.

## Step 6 — Present findings and open discussion

**Mandatory de-duplication filter (apply before presenting):** map each candidate finding against the existing comment set already fetched in Step 2; do not re-fetch. Drop candidates whose `(file, line, claim)` overlaps an existing open or resolved thread from a human or bot reviewer. If every candidate drops out, output `0 inline + 0 top-level` and state that prior reviewers already covered the diff.

**Output discipline:** chat only, no file write. Narrative uses `conversation:`; GitHub drafts/posts use `output:`. Keep paths, lines, symbols, identifiers in English.

Order in chat:
1. Summary line — counts per tier + dropped count
2. Problem framing table with rows: `Problem`, `Larger context`, `Core change`, `Verdict`
3. Risk map — selected specialist list + one-line reason for any skipped optional specialist
4. **Verification block** (from Step 5.5) — recommended bar + PR-description plan status
5. PR Quality Scorecard (table below)
6. Findings grouped by confidence tier (Critical / High / Medium)
7. Triage classifications from Step 3 — if any unresolved comments existed
8. Inline open questions — one bullet each for domain inputs code tracing cannot answer.

### Verification block

Render after summary, before scorecard. Shape follows `verification-matrix.md §5`.

If §2 produced no rows (pure docs / comments-only change), omit the entire block.

### PR Quality Scorecard

Rate each dimension 1-5 from diff/tests/PR description. One phrase per row; average rounded.

| Dimension | Score | Justification |
|------|------|------|
| Problem fit | N/5 | clarity of intent and whether the implementation solves it |
| Logic | N/5 | correctness of branches, state, contracts, and edge cases |
| Design | N/5 | simplicity, local patterns, abstraction quality, maintainability |
| Code quality | N/5 | naming, conventions, cleanliness |
| Tests | N/5 | coverage, case quality, edge cases; recommended verification bar met (see Step 5.5); PR-description test plan present |
| Security | N/5 | input validation, auth, no leaked secrets |
| PR hygiene | N/5 | description clarity, size, commit quality |
| **Overall** | **N/5** | **one-sentence verdict** |

Score guide: 5 exemplary, 4 solid, 3 adequate, 2 needs work, 1 significant gaps. N/A dimensions excluded.

**Internal only — never post this scorecard to GitHub.**

---

**Summary line** — one line showing the count per tier and how many were dropped:
```
Found: {N} critical, {N} high, {N} medium ({N} dropped below threshold)
```

**Findings — group by confidence tier**, not just severity category. Within each tier, order by category: bugs → security → architecture → testability → other.

```
### Critical (90-100)
- [95] **Bug** · `path/to/file.ts:42` — description...
- [92] **Security** · `path/to/api.ts:18` — description...

### High (80-89)
- [85] **Architecture** · `path/to/service.ts:100` — description...

### Medium (50-79) — discussion only, no inline drafts
- [62] **Testability** · `path/to/handler.ts:55` — description...
```

For each issue include:
- Confidence score in brackets: `[87]`
- Category tag in bold: `**Bug**`, `**Security**`, `**Architecture**`, `**Testability**`
- File and approximate line (English, paste-ready)
- One-sentence description (in `conversation:` language) with consequence if unfixed
- Evidence source (e.g. "confirmed via code trace through DashboardService.cs:332", "confirmed via Confluence AS tracker", "introduced in {pr_ref}")
- For deep-dived findings: a brief summary of what was traced and what was found (1-2 sentences — enough to show the work, not a full report)

---

Steps 6.5 → 7 → 8 → 9 are the fixed handoff sequence. If preconditions do not apply, say so and move on.

All chat in steps 6.5–8 stays in `conversation:` language. Draft and posted GitHub text stays in `output:` language.

## Step 6.5 — Stage 2: ask about additional deep dives

Collect remaining trace-worthy items:
- Medium-confidence findings (50–79) where more context could move them up or drop them
- Open questions that COULD be answered by code but weren't critical enough to auto-trace
- Cross-file consistency checks the user might want validated

If none, say "No additional deep-dive candidates — auto-dive covered everything." and skip to Step 7.

Otherwise ask via `AskUserQuestion` (`multiSelect: true`, max 4 options):

```
Question: "Anything else worth deep-diving before drafting?"
Header: "Deep dive"
Options (multiSelect):
- "[70] Validate caller assumes X" — Trace MyController.cs to confirm
- "[65] Check downstream consumers of Y" — grep across consuming repos for Y
- "[62] Verify Z is feature-flagged" — check Confluence + flag config
- "Skip — proceed to draft" — no further dives
```

Spawn Explore agents for selected items (same pattern as Step 5b). Update findings with evidence. Then proceed to Step 7.

## Step 7 — Stage 3: draft decision

Ask the user how to handle drafting via `AskUserQuestion`. Three options, always in this order, always with these labels:

```
Question: "Draft inline comments now?"
Header: "Draft choice"
Options (single-select):
- "Draft + post" — I draft inline comments and proceed straight to Step 8 (post flow)
- "Draft + discuss" — I draft inline comments inline in chat, you copy/refine manually, no posting
- "No draft" — End the flow here, no comments drafted
```

Behavior per choice:

**Draft + post** → produce the drafts (format below), then **immediately enter Step 8** without re-asking. Mention in the handoff line: "Drafts ready — moving to post selection."

**Draft + discuss** → produce the drafts (format below) inline in chat. End the flow with: "Drafts above. Paste or refine manually. To post via this skill, re-invoke and pick 'Draft + post'." Do NOT enter Step 8.

**No draft** → End the flow with: "No drafts produced. Re-invoke if you want to act on these later." Do NOT proceed.

**Draft format** (used by Draft+post and Draft+discuss):

- **Voice profile**: before drafting, follow `.claude/docs/voice-profile-routing.md` with `surface=github-review-comment`; read `workspace/communication-style.md` for high-stakes or ambiguous comments. Keep no-blame phrasing, soft prefix when disagreeing with senior reviewers (`"Thanks for the suggestions. I agree with them. 😊 However, ..."`), and no AI-flavor fillers. Also honor `CLAUDE.md → Code Review` — don't over-escalate severity, prefer measured assessments.
- **1–2 sentences max** — state the point directly, no preamble or verbose explanation
- Conversational peer tone — not formal or gatekeeper
- Lead with the specific concern
- Include the fix direction only if unambiguous
- **Language:** `output:` value from `workspace/config.md` (drafts are paste-ready for GitHub)

```
**File:** `path/to/file.ts` line <N>
<comment text>
```

## Step 8 — Stage 4: post action

Only enter this step if Step 7 = "Draft + post". Otherwise this step is skipped.

**Ownership check:** verify the PR is the user's (compare `gh api user --jq .login` against PR `user.login`). If the PR is not the user's, this step posts a review on someone else's PR — confirm once more before proceeding ("PR is owned by @other-user — posting a review will notify them. Proceed?").

**Determine recommended state** by these guidelines (recommend one — the user gets final say):

- `APPROVE` — no confirmed bugs or security issues, PR ready to merge
- `REQUEST_CHANGES` — confirmed issue that would cause a production incident (data corruption, service crash on deploy, security breach). High bar.
- `COMMENT` — default for everything else (reviewers address comments, no need to block)

Then ask via `AskUserQuestion`:

```
Question: "Submit review as which state? (recommended: <STATE>)"
Header: "Review state"
Options (single-select):
- "APPROVE" — LGTM / LGTM with nits
- "COMMENT" — non-blocking review with inline comments
- "REQUEST_CHANGES" — block merge until fixed
```

Put the recommended option first and append `(recommended)` to its label.

**Post sequence** once user picks:

- Approve body: "LGTM" or "LGTM with nits" — never repeat the fix mechanism or summarize the PR
- Inline comments: same 1–2 sentence rule as drafts, concise, in `output:` language, voice profile per `.claude/docs/voice-profile-routing.md` with `surface=github-review-comment`
- Create pending review → add inline comments → submit with the chosen state
- Also post any Step 3 batched reactions/replies the user agreed to (Step 3 collected the classifications; this is where they go to GitHub)

```
# Thumbs-up reaction
gh api "repos/{owner}/{repo}/pulls/comments/{comment_id}/reactions" \
  --method POST --raw-field content="+1"

# Short reply
gh api "repos/{owner}/{repo}/pulls/{pr_number}/comments/{comment_id}/replies" \
  --method POST --raw-field body="Agreed."
```

## Step 9 — Stage 5: completion message

Reached only if Step 8 posted successfully. Emit a single chat block with this exact shape (in `conversation:` language for the labels, English for the URL and counts):

```
✅ Posted.

- Review: <full review URL, e.g. https://github.com/owner/repo/pull/N#pullrequestreview-XXXXXX>
- State: <APPROVE | COMMENT | REQUEST_CHANGES>
- Inline comments: <N>
- Reactions: <N>  (omit line if 0)
- Replies: <N>    (omit line if 0)
- Daily log: <appended | skipped>
```

Get the review URL from the API response (`html_url` from the `gh api ... /pulls/<PR>/reviews` POST, or build `https://github.com/<owner>/<repo>/pull/<N>#pullrequestreview-<id>` from the returned `id`).

If the post partially failed (e.g. review submitted but a reaction failed), use ⚠️ instead of ✅ and list the failures explicitly.

## Error Handling

- **Auth failure** (`gh` not authenticated or 403): report the error and stop — do not retry or guess credentials.
- **Oversized diff** (>5000 lines based on `additions + deletions` from PR metadata): skip `gh pr diff` and use `gh pr diff --stat` instead. Read only the top N most-changed files individually. Note in the output which files were skipped.
- **Private repo / 404**: verify the repo exists and the user has access. Suggest `gh auth status` if unclear.
- **Rate limit (HTTP 429)**: wait and retry once. If still limited, report and stop.

## Ongoing — KB update (on confirmed findings)

During any discussion — whether from your own analysis or from engaging with existing comments — watch for moments where something is **confirmed and non-obvious**:
- Author clarifies an intentional design decision that isn't obvious from the code
- A pattern is confirmed as the team's convention (e.g. "we always separate these types for call-site safety")
- A bug is confirmed to exist or not to exist with a concrete reason

When this happens, immediately offer: _"This seems worth capturing in the KB — want me to run `/nase:kb-update`?"_

If the user agrees (or proactively says "add this to KB"), run `/nase:kb-update [domain]` with a concise summary of what was learned. Don't wait until the end of the session.

## Notes

- Always confirm feature flag scope issues against product docs (Confluence) before flagging — what looks like a missing path may be intentionally out of scope
- Git history agent is often the most valuable — prior PR comments on the same files frequently repeat
- Skip your own findings for anything already raised in existing comments
- Next-step hint at end of flow: if the PR is the user's own, suggest `/nase:address-comments <PR-URL>`. If the PR is someone else's, drop that suggestion entirely or suggest `/nase:request-review` if drafts went out. Never blanket-suggest `/nase:address-comments` on PRs the user does not own.

## Final — Daily Log

Append to daily log following `.claude/docs/daily-log-format.md` (tag: `review`). Runs at the end of every invocation regardless of whether Step 7/8 fired (so a "No draft" exit still gets a one-line entry). Step 9's `Daily log:` field reports the actual outcome (`appended` / `skipped`).

Log: `{repo}#{number} — {N} files, {N} issues ({categories}); key: {1-line summary}`
