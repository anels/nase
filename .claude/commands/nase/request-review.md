---
name: nase:request-review
description: Find the right people to review a PR and stage Slack DM drafts. Use when given one or more PR URLs and asked to notify reviewers, request approval, or ping code owners. Reads CODEOWNERS to match file owners, cross-references the project KB for additional context holders, generates a concise DM draft (approval request for simple PRs, review request for complex ones), groups cherry-pick PRs into a single draft per person, and confirms via AskUserQuestion before staging anything.
pattern: pipeline
---

# PR Review Requester

Find the right reviewers for one or more PRs and stage Slack DM drafts.

Follows `.claude/docs/external-mutation-policy.md` — all Slack messages go through `slack_send_message_draft` (never `_send`). This skill only stages Slack drafts; it does not assign reviewers on GitHub. The Slack DM is the request; the reviewer accepts (or declines) by reading the PR. Skipping the GitHub assignment avoids a second mutation that the recipient has to re-acknowledge in their queue.

## Step 0 — Language preflight (MUST run first, non-negotiable)

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Use `conversation:` for chat and AskUserQuestion prompts; use `output:` for Slack drafts and any GitHub-facing text.

## Step 1 — Parse inputs

Parse each PR reference with the shared helper:

```bash
python3 .claude/scripts/pr-github-helper.py parse "$PR_URL"
```

Use the helper's normalized `owner`, `repo`, and `number` fields. Group PRs by repo. If any input cannot be parsed as a single GitHub PR, ask for a corrected URL before fetching metadata.

## Step 2 — Fetch PR metadata (parallel per PR)

Fetch PR metadata using the helper's **light** variant, which centralizes the field set from `.claude/docs/github-queries.md`:

```bash
python3 .claude/scripts/pr-github-helper.py metadata "$PR_URL" --variant light
```

Save: title, url, base branch, changed file paths, additions/deletions count, body.

## Step 3 — Resolve code owners

Use this priority order — stop as soon as you have confident owners. Always reach the KB before going to GitHub.

**3a. Read project KB**

Read `workspace/kb/projects/<repo-name>.md` once. Extract ownership signals in a single pass:
1. Look for the `## Ownership Map` table — match each changed file path to a row (directory prefix or module name); collect Primary Owner and Secondary Owner GitHub handles.
2. Also scan for ownership notes, team sections, or "who to ping for X" annotations anywhere else in the file.

If the KB has no Ownership Map (repo not yet onboarded), skip to 3b.

If the KB yields confident owners for all changed areas → proceed to 3c (skip CODEOWNERS).

**3b. Read CODEOWNERS (fallback)**

Only needed if 3a leaves gaps or no Ownership Map exists. Check if the repo is cloned locally (look in `.local-paths` for the local path). If yes, read the file directly: `cat {repo_path}/CODEOWNERS 2>/dev/null || cat {repo_path}/.github/CODEOWNERS 2>/dev/null`. Otherwise fetch via:
```bash
gh api "repos/{owner}/{repo}/contents/CODEOWNERS" --jq '.content' | base64 --decode
```
(Use `--decode` long form — works on both macOS and Linux; `base64 -d` fails on macOS.)

Before matching, ask GitHub for CODEOWNERS parse errors when the API is available:
```bash
gh api "repos/{owner}/{repo}/codeowners/errors" --jq '.errors[]? | [.line, .kind, .message] | @tsv' 2>/dev/null
```
If errors are returned, report them and avoid treating the fallback matcher as authoritative for affected lines.

Prefer a repo-provided or installed CODEOWNERS parser when one is already available (for example a checked-in script, a package-lock-backed `npx` command, or a language-native parser). If no parser is available, use the documented fallback below and label it `fallback CODEOWNERS match`.

For each changed file, scan CODEOWNERS top-to-bottom and keep the **last** matching rule (GitHub's behavior). Collect all `@handle` entries from matching rules. Skip `@org/team` entries (teams can't be DM'd). If the fallback matcher cannot confidently model a pattern, report the file under `unresolved owner candidates` instead of guessing.

Matching rules (GitHub CODEOWNERS syntax):
- `/path/to/dir/` — matches anything under that directory
- `*.ext` — matches by extension anywhere
- `*` catch-all — matches everything, but more specific rules below it override
- `**` — recursive match (e.g., `docs/**` matches all files under any `docs/` subdirectory)
- Empty owner line — explicitly leaves matching files unowned; GitHub CODEOWNERS does **not** support `!pattern` negation
- Lines using unsupported CODEOWNERS syntax are ignored by GitHub; do not invent owners for those lines
- Trailing `/` — directory-only match
- `@org/team` entries — note these for the report but skip for DM purposes (teams can't be DM'd directly; resolve individual members from KB if possible)

**3c. Exclude the PR author and alumni** — skip the PR author's handle. Also check the KB for an "Alumni" or "no longer on team" section and skip anyone listed there.

## Step 4 — Resolve Slack users

For each GitHub handle:
1. Try to find the real name — check KB file first (often has `@githubhandle` → real name mappings), then infer from the handle itself.
2. Search Slack: `mcp__plugin_slack_slack__slack_search_users`. Pick the query shape based on the given name's commonness (sanitized pattern: org-affixed names returned no matches; bare uncommon given names and full common names resolved cleanly):
   - **Uncommon given name** (`UncommonName`, `RareGiven`, etc.): search the bare given name first — Slack ranks profile-name fuzziness above org-affixed phrases.
   - **Common given name** (`CommonGiven`, etc.): search `"{Given} {Surname}"` without org suffix.
   - **Never** include the corporate suffix (`CorpSuffix`, etc.) — profiles don't store it; it kills the match.
   - If the first form returns 0, fall back to the other form.
3. If unresolvable, note it — don't block the whole flow.

## Step 5 — Classify PR complexity

**Simple PR** (ask for *approval*): ≤ 3 files, total diff ≤ 50 lines, OR changes are clearly mechanical (CODEOWNERS, config values, version bumps, dependency pins).

**Complex PR** (ask for *review*): multiple source files with logic changes, large diffs, architectural impact, or unclear scope.

When in doubt, lean towards "review."

## Step 6 — Detect cherry-pick groups

Cherry-picks share the same intent across different base branches. Group PRs as cherry-picks when:
- Titles are identical or differ only by branch suffix/prefix (e.g. "fix X -> release/v1", "fix X -> release/v2")
- Or commits share the same `Cherry-picked from commit {sha}` trailer in the commit body (more reliable than title matching)
- Or the user explicitly called them cherry-picks

Cherry-pick group → **one combined DM** per person listing all PR links.
Unrelated PRs → **separate DMs** per PR per person.

Follow `.claude/docs/slack-draft-style.md` and `.claude/docs/voice-profile-routing.md` with `surface=slack-dm` — apply when drafting Slack messages in Steps 7–9.

## Step 7 — Draft messages

Write like a colleague asking a quick favour — start with the ask, one line on what the change does, then the link. No bullet points, no markdown, no formal sign-off.

**No "Hey [name]," opener.** A Slack DM is already a 1:1 channel — Slack shows the recipient's name in the header, so naming them again in the body just adds noise. Open with the ask itself ("Could you help review [url] - [TLDR]"). This is purely a Slack-DM convention; if the skill ever drafts to a multi-person channel, an opener that names the target reviewer would be appropriate again.

The TLDR should complete one of these naturally (pick whichever fits):
- "this mainly fixes …"
- "this addresses …"
- "this implements …"
- "this adds …"

Derive it from the PR title and body; don't invent details.

**Important: Slack mrkdwn auto-links URLs with `<>` — if a newline follows a URL, the next word gets swallowed into the link tag. Always put the URL and TLDR on the same line, joined by ` - `.**

**Single PR (approval):**
```
Could you help approve [url] - [TLDR]
```

**Single PR (review):**
```
Could you help review [url] - [TLDR]
```

**Cherry-pick group:**
```
Could you help approve these cherry-picks? [TLDR]
• [url 1] → release/vX
• [url 2] → release/vY
```

Keep it short — people will read the PR description for details. No markdown in the actual DM.

## Step 8 — Confirm recipient list and draft

People move teams or leave companies, and sometimes you want a different reviewer than what git history suggests. Give the user control over the final list before staging any Slack drafts.

Use two `AskUserQuestion` calls:

**Question 1 — select recipients** (`multiSelect: true`):

Present each resolved person as a selectable option (pre-selected = recommended). Include a brief reason for each (e.g., "14 commits to TraceviewController"). The "Other" free-text option lets the user add someone not on the list.

Example options:
- `Alice Smith` — "14 commits to changed files"
- `Bob Lee` — "2 commits to changed files"
- *(any unresolved handles listed in the question text, not as options)*

**Question 2 — message preview** (single-select, only if question 1 returned selections):

Show the drafted message and ask "Stage Slack DM drafts for the selected people?"
- `Stage drafts` — proceed
- `Cancel` — abort

**Handling "Other"**: If the user types a name in the Other field, search Slack for that person (`mcp__plugin_slack_slack__slack_search_users`) and add them to the draft list. If the search is ambiguous, surface the candidates and ask the user to clarify before staging drafts.

Only stage drafts for the people the user confirmed in question 1.

## Step 9 — Stage DM drafts (parallel)

Use `slack_send_message_draft` (never `slack_send_message`) with each person's Slack user ID as `channel_id`. Report which drafts were created and which failed. Then stop — do not also assign the same people on GitHub. Slack ping is the request; the GitHub review queue updates when the reviewer actually leaves a review.
