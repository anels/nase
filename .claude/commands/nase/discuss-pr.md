---
name: nase:discuss-pr
description: Chat-first deep PR review — posts to GitHub only on explicit request. Runs parallel specialist agents (architecture, bugs, security, testability, DRY/KISS, git history), synthesizes findings, researches open questions via GitHub and Confluence, and produces inline comment drafts ready for manual posting. Use when asked to review a PR without posting, do a self-review, or prepare review comments before publishing.
---

## Phase 0 — Input Guard

Follow the PR input guard in `.claude/docs/pr-input-guard.md`. If `$ARGUMENTS` is empty, ask the user for the PR URL instead of printing usage.

## Step 1 — Parse inputs

Note any focus areas the user specifies (e.g. "architecture", "security", "skip nitpicks").

Default focus if none specified: architecture, bugs, security, testability, DRY/KISS.

## Step 2 — Fetch PR metadata and existing comments

Fetch PR metadata using the **light** variant from `.claude/docs/github-queries.md` (PR Metadata section). Also run in parallel:

```
gh pr diff <PR> --repo <owner/repo>
gh api repos/<owner/repo>/pulls/<PR>/comments
gh api repos/<owner/repo>/pulls/<PR>/reviews
```

Save: title, body, head SHA, changed file list, full diff, existing inline comments (with `id`, `path`, `line`, `body`, `user.login`, `in_reply_to_id`), existing reviews (with `id`, `state`, `body`, `user.login`).

Group comments into threads: top-level comment + all replies sharing the same `in_reply_to_id`.

## Step 3 — Engage existing comments + launch specialist agents

If the PR has no existing comments, skip the comment engagement and go straight to the agent results.

**Do both in parallel:**

**A) Present existing comments** — for each unresolved thread, show:
- File + line, author, comment body
- Whether it's a standalone comment or a thread with replies

Then ask the user which comments they agree with, want to discuss, or skip.

When the user wants to discuss a comment, engage directly — research the code, check Confluence or git history for context, and give your own take.

Collect agree/discuss/skip decisions but **do not post reactions or replies yet** — those are batched into Step 9 alongside inline comments, posted only on explicit request.

**B) Launch specialist agents** (do not wait for user comment triage — agents only read the diff):

<!-- Model routing is configured in CLAUDE.md — defer to workspace-level settings. -->

| Agent | Focus |
|-------|-------|
| **Architecture** | DRY violations, KISS violations, layering issues, SRP violations, abstraction quality |
| **Bugs** | Logic errors, null/undefined risks, race conditions, incorrect async usage, data loss |
| **Security** | Input validation, header injection, credential exposure, SSRF, auth bypass risks |
| **Testability** | Missing coverage for new paths, tests that only chase signatures, untestable designs |
| **Git history** | Patterns rejected in past PRs, recurring comments on the same files, regressions |
| **Code comments** | Violations of guidance in inline comments, stale or contradicted comments |

## Step 4 — Score and filter (after agents complete)

For each issue, assign a confidence score 0–100:
- **< 50**: pre-existing, false positive, or nitpick — drop
- **50–79**: worth mentioning in discussion but skip inline comment draft
- **≥ 80**: confirmed issue — include in final output and draft a comment

## Step 5 — Research open questions

Before presenting findings, resolve any "needs context" issues:
- **GitHub**: search code, read related PRs, check git history for the same files
- **Confluence**: search for design docs, feature trackers, or onboarding pages relevant to the changed area
- **Result**: either confirm the issue with evidence, or downgrade it to "ask the author"

## Step 6 — Present findings and open discussion

Group by severity: **confirmed bugs** → **architecture concerns** → **security** → **testability** → **lower confidence / ask the author**.

For each issue include:
- One-sentence description
- File and approximate line
- Why it matters (consequence if unfixed)
- Evidence source (e.g. "confirmed via Confluence AS tracker", "introduced in PR #2345")

After presenting, explicitly invite the user into the discussion:
- List any "ask the author" items and say you can look further if the user can provide context or loop in the author
- Offer to dig into any finding the user wants to explore further
- If the user has domain context (e.g. "that endpoint isn't used in AS yet"), update the confidence and revise the findings accordingly
- Keep the conversation going — the user may know things that flip a suspected bug into intentional design, or vice versa

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
- **Approve body**: "LGTM with nits" or "Approved with nits" — never repeat the fix mechanism or summarize the PR
- **Inline comments**: keep minimal — same 1–2 sentence rule as drafts, concise
- **Reactions/replies from Step 2.5**: post any agreed +1 reactions or "Agreed." replies now
- Create pending review → add inline comments → submit with APPROVE/COMMENT/REQUEST_CHANGES as appropriate

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
- **Oversized diff** (>5000 lines): skip full-diff analysis. Instead, review the `--stat` summary and read only the most changed files individually. Note in the output which files were skipped.
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
