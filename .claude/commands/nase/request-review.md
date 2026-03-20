---
name: nase:request-review
description: Find the right people to review a PR and send them Slack DMs. Use when given one or more PR URLs and asked to notify reviewers, request approval, or ping code owners. Reads CODEOWNERS to match file owners, cross-references the project KB for additional context holders, generates a concise DM (approval request for simple PRs, review request for complex ones), groups cherry-pick PRs into a single message per person, and confirms via AskUserQuestion before sending anything.
---

# PR Review Requester

Find the right reviewers for one or more PRs and DM them on Slack.

## Step 1 — Parse inputs

Extract `owner/repo` and PR number from each URL. Group PRs by repo.

## Step 2 — Fetch PR metadata (parallel per PR)

```bash
gh pr view <PR> --repo <owner/repo> \
  --json number,title,url,additions,deletions,changedFiles,files,baseRefName,body
```

Save: title, url, base branch, changed file paths, additions/deletions count, body.

## Step 3 — Resolve code owners

Use this priority order — stop as soon as you have confident owners. Always reach the KB before going to GitHub.

**3a. Read project KB**

Read `work/kb/projects/<repo-name>.md` once. Extract ownership signals in a single pass:
1. Look for the `## Ownership Map` table — match each changed file path to a row (directory prefix or module name); collect Primary Owner and Secondary Owner GitHub handles.
2. Also scan for ownership notes, team sections, or "who to ping for X" annotations anywhere else in the file.

If the KB has no Ownership Map (repo not yet onboarded), skip to 3b.

If the KB yields confident owners for all changed areas → proceed to 3c (skip CODEOWNERS).

**3b. Read CODEOWNERS (fallback)**

Only needed if 3a leaves gaps or no Ownership Map exists. Check if the repo is cloned locally (look in `work/context.md` for the local path). If yes, read directly. Otherwise fetch via:
```bash
gh api repos/<owner>/<repo>/contents/CODEOWNERS --jq '.content' | base64 -d
```

For each changed file, scan CODEOWNERS top-to-bottom and keep the **last** matching rule (GitHub's behavior). Collect all `@handle` entries from matching rules. Skip `@org/team` entries (teams can't be DM'd).

Matching rules (simplified gitignore-style):
- `/path/to/dir/` — matches anything under that directory
- `*.ext` — matches by extension anywhere
- `*` catch-all — matches everything, but more specific rules below it override

**3c. Exclude the PR author and alumni** — skip the PR author's handle. Also check the KB for an "Alumni" or "no longer on team" section and skip anyone listed there.

## Step 4 — Resolve Slack users

For each GitHub handle:
1. Try to find the real name — check KB file first (often has `@githubhandle` → real name mappings), then infer from the handle itself.
2. Search Slack: `mcp__plugin_slack_slack__slack_search_users` with the real name or inferred name.
3. If unresolvable, note it — don't block the whole flow.

## Step 5 — Classify PR complexity

**Simple PR** (ask for *approval*): ≤ 3 files, total diff ≤ 50 lines, OR changes are clearly mechanical (CODEOWNERS, config values, version bumps, dependency pins).

**Complex PR** (ask for *review*): multiple source files with logic changes, large diffs, architectural impact, or unclear scope.

When in doubt, lean towards "review."

## Step 6 — Detect cherry-pick groups

Cherry-picks share the same intent across different base branches. Group PRs as cherry-picks when:
- Titles are identical or differ only by branch suffix/prefix (e.g. "fix X -> release/v1", "fix X -> release/v2")
- Or the user explicitly called them cherry-picks

Cherry-pick group → **one combined DM** per person listing all PR links.
Unrelated PRs → **separate DMs** per PR per person.

## Step 7 — Draft messages

Write like a colleague asking a quick favour — casual opener, one line on what the change does, then the link. No bullet points, no markdown, no formal sign-off.

The TLDR should complete one of these naturally (pick whichever fits):
- "this mainly fixes …"
- "this addresses …"
- "this implements …"
- "this adds …"

Derive it from the PR title and body; don't invent details.

**Important: Slack mrkdwn auto-links URLs with `<>` — if a newline follows a URL, the next word gets swallowed into the link tag. Always put the URL and TLDR on the same line, joined by ` — `.**

**Single PR (approval):**
```
Hey [first name], could you help approve this? [url] — [TLDR]
```

**Single PR (review):**
```
Hey [first name], could you help review this? [url] — [TLDR]
```

**Cherry-pick group:**
```
Hey [first name], could you help approve these cherry-picks? [TLDR]
[url 1] (→ release/vX)
[url 2] (→ release/vY)
```

Keep it short — people will read the PR description for details. No markdown in the actual DM.

## Step 8 — Confirm recipient list and send

People move teams or leave companies, and sometimes you want a different reviewer than what git history suggests. Give the user control over the final list before sending anything.

Use two `AskUserQuestion` calls:

**Question 1 — select recipients** (`multiSelect: true`):

Present each resolved person as a selectable option (pre-selected = recommended). Include a brief reason for each (e.g., "14 commits to TraceviewController"). The "Other" free-text option lets the user add someone not on the list.

Example options:
- `Alice Smith` — "14 commits to changed files"
- `Bob Lee` — "2 commits to changed files"
- *(any unresolved handles listed in the question text, not as options)*

**Question 2 — message preview** (single-select, only if question 1 returned selections):

Show the drafted message and ask "Send this message to the selected people?"
- `Send` — proceed
- `Cancel` — abort

**Handling "Other"**: If the user types a name in the Other field, search Slack for that person (`mcp__plugin_slack_slack__slack_search_users`) and add them to the send list. If the search is ambiguous, surface the candidates and ask the user to clarify before sending.

Only send to the people the user confirmed in question 1.

## Step 9 — Send DMs (parallel)

Use `slack_send_message_draft` (never `slack_send_message`) with each person's Slack user ID as `channel_id`. Report which drafts were created and which failed.
