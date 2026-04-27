---
name: nase:discuss-pr
description: Chat-first deep PR review — posts to GitHub only on explicit request. Runs parallel specialist agents (architecture, bugs, security, testability, DRY/KISS, git history), synthesizes findings, researches open questions via GitHub and Confluence, and produces inline comment drafts ready for manual posting. Use when asked to review a PR without posting, do a self-review, or prepare review comments before publishing.
---

## Language

Read `workspace/config.md` — use the `conversation:` value for all responses in this skill (comments and questions to the user). Use `output:` for anything posted to GitHub.

## Phase 0 — Input Guard

Follow the PR input guard in `.claude/docs/pr-input-guard.md`. If `$ARGUMENTS` is empty, ask the user for the PR URL instead of printing usage.

## Step 1 — Parse inputs and resolve repo

Note any focus areas the user specifies (e.g. "architecture", "security", "skip nitpicks").

Default focus if none specified: architecture, bugs, security, testability, DRY/KISS, code comments.

Resolve repo from PR URL and load the KB file — see `.claude/docs/repo-resolution.md` (Part 1 + Part 2).

## Step 2 — Fetch PR metadata and existing comments

Fetch PR metadata using the **light** variant from `.claude/docs/github-queries.md` (PR Metadata section). Also run in parallel:

```
gh pr diff <PR> --repo <owner/repo>
gh api repos/<owner/repo>/pulls/<PR>/comments --paginate
gh api repos/<owner/repo>/pulls/<PR>/reviews --paginate
```

Save: title, body, head SHA, changed file list, full diff, existing inline comments (with `id`, `path`, `line`, `body`, `user.login`, `in_reply_to_id`), existing reviews (with `id`, `state`, `body`, `user.login`).

**PR size gate:** Check `additions + deletions` from PR metadata. If > 1500 lines, flag to user before proceeding: "This PR is {N} lines — single-pass review reliability drops significantly at this size. Consider recommending the author split by concern (e.g. API surface vs data layer vs migrations) before deep review." The user decides whether to proceed or ask for a split. This prevents discovering mid-review that the PR is too large to hold in context reliably (lesson from Insights#4290: 3k+ lines required double-review with different findings each pass).

Group comments into threads: top-level comment + all replies sharing the same `in_reply_to_id`.

## Step 2.5 — Collect context

For each file touched by the diff, read its key dependencies: interfaces it implements, base classes it extends, and primary callers — anything not in the diff itself that explains how the changed code fits into the larger design. Cross-reference the KB (loaded in Step 1) for architectural constraints relevant to the changed area. If the KB references a Confluence doc for this domain, read it. The goal is to have enough context that agent findings can be evaluated against actual design intent, not just the diff in isolation.

**Platform prohibition pre-check (infra PRs only):** If the PR touches infrastructure or networking files (VNet peering, Private Endpoints, DNS, cluster networking, Terraform/Bicep/ARM templates), check the KB for any platform team prohibitions before proceeding to agent analysis. A technically correct implementation of a prohibited operation is a critical finding that takes priority over code-level analysis — surface it immediately rather than burying it among code review findings.

**Performance claim check:** Scan the PR title and body for performance claims ("X% faster", "reduces latency", "N× throughput", "improves performance"). If found, check whether the PR body includes a benchmark table with: test environment, workload description, before/after median + p95, and measurement methodology. If missing, add a finding: "Performance claim without benchmark data — the first reviewer will ask for it, adding 1-3 days of review latency. Recommend author add a benchmark table to the PR body." (Lesson from Insights-LookerML#1197 review cycle.)

## Step 3 — Launch specialist agents + engage existing comments

**Fire agents immediately** — they only need the diff and KB context from Steps 2–2.5. Do not wait for the comment triage below.

| Agent | Focus |
|-------|-------|
| **Architecture** | DRY violations, KISS violations, layering issues, SRP violations, abstraction quality |
| **Bugs** | Logic errors, null/undefined risks, race conditions, incorrect async usage, data loss |
| **Security** | Input validation, header injection, credential exposure, SSRF, auth bypass risks |
| **Testability** | Missing coverage for new paths, tests that only chase signatures, untestable designs |
| **Git history** | Patterns rejected in past PRs, recurring comments on the same files, regressions |
| **Code comments** | Violations of guidance in inline comments, stale or contradicted comments |

**While agents run — triage existing comments** (if any):

Auto-classify each unresolved thread into one of four buckets, then present a triage table for the user to confirm or override:

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

After presenting the table, ask: "Does this look right? Any to change?" Then for each 🔍 item — research the code, check Confluence or git history, and give your own take before finalizing classification.

**Prior-round fix verification:** For any 🔧 needs-fix items that originate from an EARLIER review round (comments that predate the most recent commit), do not auto-classify as ✅ can-resolve based on the author's "addressed" reply alone. Verify the fix was actually applied: run `git show <sha>` for the commit claimed to address the issue and confirm the fix appears in the diff. If the commit doesn't contain the fix, keep the item as 🔧 needs-fix. This prevents silently re-approving unaddressed findings — Insights-monitoring pattern: bot + prior CHANGES_REQUESTED both flagged cache mutation; verification of commit 48e856dd confirmed fix before APPROVE (lesson: 2026-04-15).

Collect the final classifications. **Do not post reactions or replies yet** — batched into Step 8, posted only on explicit request.

## Step 4 — Score, tier, and filter (after agents complete)

**4a. Diff-scope verification (before scoring):**
For each agent finding, verify it is genuinely NEW in the diff — not pre-existing code. Check whether the flagged line or pattern existed before this PR by reading the base branch version of the file (`git show origin/{base_branch}:{path}`). Pre-existing issues that the PR did not introduce or modify are not the PR author's responsibility — drop them silently (score < 50). This prevents false alarms like flagging a shared helper's side effects when the PR only touched an unrelated code path.

**4b. Verify actual code against agent descriptions:**
For each remaining finding, read the actual file at the referenced line to confirm the agent's description matches reality. Agent analysis can misread diffs — the prose description of what the code looks like may not match the actual code. If the agent's claim is inaccurate (e.g., "missing null check" but the check exists), drop or downgrade the finding.

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

Before presenting findings, **proactively investigate** anything whose confidence depends on behavior outside the diff. Don't ask the user whether to deep dive — decide and do it.

### 5a. Identify deep-dive candidates

Scan the scored findings (from Step 4) and flag any that meet these criteria:
- **Opaque handoff**: the diff passes a value to a service, library, or repository method whose behavior for the new input is unknown from the diff alone (e.g., a string that used to be an enum value is now passed as a free-form name — does the callee handle it?)
- **Cross-boundary assumption**: the finding assumes something about a caller, downstream consumer, or deployment environment that isn't visible in the diff
- **Pattern divergence**: the diff follows a pattern from another controller/service but omits a step that the reference implementation includes (e.g., a validation, a Content check, a type conversion) — unclear if the omission is intentional or a gap

The goal: never present a finding as "medium, worth discussing" when code tracing would resolve it to either "confirmed critical" or "dropped."

### 5b. Trace implementations

For each deep-dive candidate, spawn an Explore agent (role: worker) to trace the code path. Give each agent:
- The specific question to answer (e.g., "does `DashboardService.GetDashboardAsync` do `Enum.TryParse` internally when it receives a non-enum sourceType string?")
- Where to look (the implementation repo if known from KB, NuGet package source, or the current repo)
- What to report: the concrete code path, whether the concern is confirmed or refuted, and evidence (file:line)

Run these in parallel. If the implementation lives in a separate repo listed in `.local-paths`, the agent can read it directly. If it's in a NuGet package with no local source, note the gap and keep the finding as "ask the author" with an explanation of what couldn't be verified.

### 5c. Update findings with evidence

For each deep-dive result:
- **Confirmed bug**: upgrade the confidence score (often from medium → critical/high), add the evidence trail
- **Refuted concern**: drop it (score < 50) or downgrade to informational
- **New finding discovered during trace**: add it as a new finding with its own confidence score
- **Inconclusive** (no source available): keep the original score but mark as "ask the author" with context on what was checked and what couldn't be verified
- **Requires domain knowledge**: some questions can't be answered by reading code — product intent, deployment sequencing, business rules, feature scope decisions. Keep these as open questions for the user. The goal of auto-deep-dive is to resolve what code tracing CAN answer, not to eliminate all discussion.

### 5d. Research remaining open questions

For any findings not covered by deep-dive (already high-confidence, or not implementation-dependent):
- **GitHub**: search code, read related PRs, check git history for the same files
- **Confluence**: search for design docs, feature trackers, or onboarding pages relevant to the changed area
- **Result**: either confirm the issue with evidence, or downgrade it to "ask the author"

## Step 6 — Present findings and open discussion

**Show quality scorecard first**, then the findings.

### PR Quality Scorecard

Rate each dimension 1–5 based on evidence from the diff, tests, and PR description. One phrase of justification per row. Finish with an overall score (average, rounded) and a one-sentence verdict.

| 维度 | 分数 | 说明 |
|------|------|------|
| 代码质量 | N/5 | 命名/约定/清洁度 |
| 架构/设计 | N/5 | DRY/KISS/分层/SRP |
| 测试 | N/5 | 覆盖度、用例质量、边界场景 |
| 安全 | N/5 | 输入验证/auth/无凭证泄漏 |
| PR 规范 | N/5 | 描述清晰度、大小合理、提交质量 |
| **总体** | **N/5** | **一句话总结** |

Score guide: 5 = exemplary, 4 = solid, 3 = adequate, 2 = needs work, 1 = significant gaps. If a dimension is not applicable (e.g. security for a pure refactor), mark N/A and exclude from the average.

**⚠️ Internal only — never post this scorecard to GitHub.** It must not appear in inline comments, review bodies, or any GitHub API call (Steps 7–8). It exists solely as a quick read for the reviewer.

---

**Summary line first** — one line showing the count per tier and how many were dropped:
```
Found: {N} critical, {N} high, {N} medium ({N} dropped below threshold)
```

**Group by confidence tier**, not just severity category. Within each tier, order by category: bugs → security → architecture → testability → other.

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
- File and approximate line
- One-sentence description with consequence if unfixed
- Evidence source (e.g. "confirmed via code trace through DashboardService.cs:332", "confirmed via Confluence AS tracker", "introduced in PR #2345")
- For deep-dived findings: a brief summary of what was traced and what was found (1-2 sentences — enough to show the work, not a full report)

After presenting, use `AskUserQuestion` to open discussion. Bundle any "ask the author" items together with the next-step prompt into a single question — one bullet per open question, followed by the options. Example shape:

```
A few open questions:
• [83] Is X intentional, or should it come from Y?
• [70] Does A deploy atomically with B? (A backward compat fallback would protect the rollout window if not.)

Want me to draft inline comments for posting, or dig into any of these further?
```

If the user provides domain context that changes a finding (e.g. "that endpoint isn't used in AS yet"), update the confidence score and revise accordingly before continuing.

## Step 7 — Draft inline comments (on request)

When the user asks for comments, produce one per confirmed issue:

- **1–2 sentences max** — state the point directly, no preamble or verbose explanation
- Conversational, peer tone — not formal or gatekeeper
- Lead with the specific concern
- Include the fix direction only if unambiguous

Format:
```
**File:** `path/to/file.ts` line <N>
<comment text>
```

Do not post anything to GitHub. The user pastes these manually.

## Step 8 — Post to GitHub (on request)

When the user asks to post, approve, or submit:

- **All text in English** — GitHub reviews are always in English
- **Review state**: determine the appropriate state, then **always confirm with the user before posting** by showing the chosen state and asking "Post as `REQUEST_CHANGES` or prefer `COMMENT`?" — the user gets final say. Guidelines for the initial recommendation: `REQUEST_CHANGES` only if a confirmed issue would cause a production incident (e.g. data corruption, service crash on deploy, security breach) — this is a high bar; `APPROVE` if no confirmed bugs or security issues and the PR is ready to merge; `COMMENT` in all other cases (reviewers will address comments, no need to block)
- **Approve body**: "LGTM" or "LGTM with nits" — never repeat the fix mechanism or summarize the PR
- **Inline comments**: keep minimal — same 1–2 sentence rule as drafts, concise
- **Reactions/replies from Step 3**: post any agreed +1 reactions or "Agreed." replies now
- Create pending review → add inline comments → submit with the review state determined above

For reactions and replies:
```
# Thumbs-up reaction
gh api repos/<owner/repo>/pulls/comments/<comment_id>/reactions \
  --method POST --raw-field content="+1"

# Short reply
gh api repos/<owner/repo>/pulls/<PR>/comments/<comment_id>/replies \
  --method POST --raw-field body="Agreed."
```

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
- To address findings, suggest `/nase:address-comments <PR-URL>`.

## Final — Daily Log

Append to daily log following `.claude/docs/daily-log-format.md` (tag: `review`).
Log: `{repo}#{number} — {N} files, {N} issues ({categories}); key: {1-line summary}`
