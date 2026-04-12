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

Follow `.claude/docs/repo-resolution.md`:
- **Part 1** (Repo Resolution): extract `owner/repo` from the PR URL, look up the repo name in `.local-paths`. If not found, ask the user for the local path and append it.
- **Part 2** (KB File Loading): derive the domain key from the repo name, find the KB file in `workspace/kb/.domain-map.md`, and read it.

## Step 2 — Fetch PR metadata and existing comments

Fetch PR metadata using the **light** variant from `.claude/docs/github-queries.md` (PR Metadata section). Also run in parallel:

```
gh pr diff <PR> --repo <owner/repo>
gh api repos/<owner/repo>/pulls/<PR>/comments --paginate
gh api repos/<owner/repo>/pulls/<PR>/reviews --paginate
```

Save: title, body, head SHA, changed file list, full diff, existing inline comments (with `id`, `path`, `line`, `body`, `user.login`, `in_reply_to_id`), existing reviews (with `id`, `state`, `body`, `user.login`).

Group comments into threads: top-level comment + all replies sharing the same `in_reply_to_id`.

## Step 2.5 — Collect context

For each file touched by the diff, read its key dependencies: interfaces it implements, base classes it extends, and primary callers — anything not in the diff itself that explains how the changed code fits into the larger design. Cross-reference the KB (loaded in Step 1) for architectural constraints relevant to the changed area. If the KB references a Confluence doc for this domain, read it. The goal is to have enough context that agent findings can be evaluated against actual design intent, not just the diff in isolation.

**Platform prohibition pre-check (infra PRs only):** If the PR touches infrastructure or networking files (VNet peering, Private Endpoints, DNS, cluster networking, Terraform/Bicep/ARM templates), check the KB for any platform team prohibitions before proceeding to agent analysis. A technically correct implementation of a prohibited operation is a critical finding that takes priority over code-level analysis — surface it immediately rather than burying it among code review findings.

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

## Step 5 — Research open questions

Before presenting findings, resolve any "needs context" issues:
- **GitHub**: search code, read related PRs, check git history for the same files
- **Confluence**: search for design docs, feature trackers, or onboarding pages relevant to the changed area
- **Result**: either confirm the issue with evidence, or downgrade it to "ask the author"

## Step 6 — Present findings and open discussion

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
- Evidence source (e.g. "confirmed via Confluence AS tracker", "introduced in PR #2345")

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

Append a summary to `workspace/logs/YYYY-MM-DD.md`:
```
### PR Review: <repo>#<number>
- Reviewed <N> files, found <N> issues across <categories>
- Key findings: <1-2 line summary>
```
