---
name: nase:discuss-pr
description: Chat-first deep PR review — posts to GitHub only on explicit request. Runs parallel specialist agents (architecture, bugs, security, testability, DRY/KISS, git history), synthesizes findings, researches open questions via GitHub and Confluence, and produces inline comment drafts ready for manual posting. Use when asked to review a PR without posting, do a self-review, or prepare review comments before publishing.
---

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

## Step 3 — Launch specialist agents + engage existing comments

**Fire agents immediately** — they only need the diff and KB context from Steps 2–2.5. Do not wait for the comment triage below.

<!-- Model routing is configured in CLAUDE.md — defer to workspace-level settings. -->

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
- **Review state**: `REQUEST_CHANGES` if any confirmed bug or security issue; `APPROVE` if no confirmed bugs or security issues and the PR is ready to merge; `COMMENT` otherwise (findings worth noting but not blocking)
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
