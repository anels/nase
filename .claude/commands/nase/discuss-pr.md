---
name: nase:discuss-pr
description: "Read-only PR analysis — runs parallel specialist agents (architecture, bugs, security, testability, DRY/KISS) and drafts inline comments without posting or changing code. Use when reviewing a PR for the first time, doing a self-review, or preparing comments. Triggers: 'analyze PR', 'self-review', 'prepare review comments', 'review PR #N', PR URL + 'review without posting'. For acting on existing reviewer feedback (fix code + push), use /nase:address-comments instead."
---

## Language

Read `workspace/config.md`: `conversation:` for chat/questions, `output:` for GitHub text.

## Phase 0 — Input Guard

Follow the PR input guard in `.claude/docs/pr-input-guard.md`. If `$ARGUMENTS` is empty, ask the user for the PR URL instead of printing usage.

## Step 1 — Parse inputs and resolve repo

Note any focus areas the user specifies (e.g. "architecture", "security", "skip nitpicks").

Default focus if none specified: architecture, bugs, security, testability, DRY/KISS, code comments.

Resolve repo from PR URL and load the KB file — see `.claude/docs/repo-resolution.md` (Part 1 + Part 2).

## Step 2 — Fetch PR metadata and existing comments

Fetch PR metadata using the **light** variant from `.claude/docs/github-queries.md` (PR Metadata section). Use `additions + deletions` from that metadata before fetching the diff:

- If total diff lines > 5000: run `gh pr diff <PR> --repo <owner/repo> --stat`; do not fetch the full diff. Read only the top changed files needed for each finding.
- Otherwise fetch the full diff.

Also run in parallel:

```
gh api repos/<owner/repo>/pulls/<PR>/comments --paginate
gh api repos/<owner/repo>/pulls/<PR>/reviews --paginate
```

Save: title, body, head SHA, changed file list, full diff or diff stat, existing inline comments (with `id`, `path`, `line`, `body`, `user.login`, `in_reply_to_id`), existing reviews (with `id`, `state`, `body`, `user.login`).

**PR size gate:** if `additions + deletions` > 1500, warn: "This PR is {N} lines — single-pass review reliability drops significantly. Consider splitting by concern before deep review." User decides whether to proceed.

Group comments into threads: top-level comment + all replies sharing the same `in_reply_to_id`.

## Step 2.5 — Collect context

For each touched file, read key dependencies/callers needed to judge design intent. Cross-reference KB and relevant Confluence docs.

**Platform prohibition pre-check (infra PRs):** for networking/infra files, check KB for platform prohibitions before agent analysis. Surface prohibited operations immediately.

**Performance claim check:** if title/body claims speed/latency/throughput gains, require benchmark data: environment, workload, before/after median + p95, methodology. Missing data becomes a finding.

## Step 3 — Launch specialist agents + engage existing comments

**Pipeline-touch detection:** if diff touches `*.sql`, ETL/ingestion/aggregation paths, Avro/Parquet, Databricks notebooks, LookerML, or EventHub/Queue/Timer Functions, add the Pipeline gates agent.

| Agent | Focus |
|-------|-------|
| **Architecture** | DRY violations, KISS violations, layering issues, SRP violations, abstraction quality |
| **Bugs** | Logic errors, null/undefined risks, race conditions, incorrect async usage, data loss |
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

**Codex second-opinion agent** — gate per `.claude/docs/codex-review.md → Prerequisite`; skip cleanly if MCP is not loaded:

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

Collect the final classifications. **Do not post reactions or replies yet** — batched into Step 8, posted only on explicit request.

## Step 4 — Score, tier, and filter (after agents complete)

**4a. Diff-scope verification:** apply `.claude/docs/pr-review-verification.md` §2. Drop pre-existing issues silently (score < 50) — common false alarm: flagging a shared helper's side effects when the PR only touched an unrelated code path.

**4b. Verify code matches description:** apply `.claude/docs/pr-review-verification.md` §3. Drop or downgrade findings where the agent's prose does not match the file at the referenced line.

**4c. Assign confidence scores:**
For each issue, assign a confidence score 0–100:
- **< 50**: pre-existing, false positive, or nitpick — drop silently
- **50–79**: worth mentioning in discussion but skip inline comment draft
- **≥ 80**: confirmed issue — include in final output and draft a comment

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

**Output discipline:** chat only, no file write. Narrative uses `conversation:`; GitHub drafts/posts use `output:`. Keep paths, lines, symbols, identifiers in English.

Order in chat:
1. Summary line — counts per tier + dropped count
2. **Verification block** (from Step 5.5) — recommended bar + PR-description plan status
3. PR Quality Scorecard (table below)
4. Findings grouped by confidence tier (Critical / High / Medium)
5. Triage classifications from Step 3 — if any unresolved comments existed
6. Inline open questions — one bullet each for domain inputs code tracing cannot answer.

### Verification block

Render after summary, before scorecard. Shape follows `verification-matrix.md §5`.

If §2 produced no rows (pure docs / comments-only change), omit the entire block.

### PR Quality Scorecard

Rate each dimension 1-5 from diff/tests/PR description. One phrase per row; average rounded.

| Dimension | Score | Justification |
|------|------|------|
| Code quality | N/5 | naming, conventions, cleanliness |
| Architecture | N/5 | DRY / KISS / layering / SRP |
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

- **Voice profile**: before drafting, read `workspace/communication-style.md` — no blame phrasing, soft prefix when disagreeing with senior reviewers (`"Thanks for the suggestions. I agree with them. 😊 However, ..."`), no AI-flavor fillers. Also honor `CLAUDE.md → Code Review` — don't over-escalate severity, prefer measured assessments.
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
- Inline comments: same 1–2 sentence rule as drafts, concise, in `output:` language, voice profile per `workspace/communication-style.md`
- Create pending review → add inline comments → submit with the chosen state
- Also post any Step 3 batched reactions/replies the user agreed to (Step 3 collected the classifications; this is where they go to GitHub)

```
# Thumbs-up reaction
gh api repos/<owner/repo>/pulls/comments/<comment_id>/reactions \
  --method POST --raw-field content="+1"

# Short reply
gh api repos/<owner/repo>/pulls/<PR>/comments/<comment_id>/replies \
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
