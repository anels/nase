# AI Attribution — Per-Repo Config

## Contents

- Scope
- Storage
- Lookup Algorithm
- First-Time Prompt
- What "On" Means
- Squash + Co-Author Preservation
- Changing Config Later

How to decide whether commits and PR descriptions include AI co-author trailers (`Co-Authored-By: Claude <noreply@anthropic.com>`, `Generated with Claude Code`, etc.).

Used by `commit-push-pattern.md`, `pr-creation-pattern.md`, `/nase:fsd`, `/nase:prep-merge`, `/nase:address-comments`.

---

## Scope

| Surface | Rule |
|---------|------|
| Commit messages | Per-repo config (this doc) |
| PR descriptions | Per-repo config (this doc) |
| Inline PR review comments | Never — global rule, see `~/.claude/CLAUDE.md` |
| Slack messages | Never — global rule, see `~/.claude/CLAUDE.md` |

Per-repo config only governs commits and PR descriptions. Inline review comments and Slack messages stay AI-clean regardless of config.

---

## Storage

Workspace-root `.local-paths` stores one line per repo:

```
{RepoName}-ai-attribution=on
{RepoName}-ai-attribution=off
```

- `on` — include AI attribution (commit trailer + PR description footer)
- `off` — strip AI attribution

`{RepoName}` matches the existing repo key in `.local-paths` (e.g., `Insights`, `service-fabric-packaging`).

---

## Lookup Algorithm

Before creating a commit or PR description:

1. Resolve `{RepoName}` from the current repo path (reverse-lookup against `.local-paths` `RepoName=/path` entries).
2. Grep `.local-paths` for `{RepoName}-ai-attribution=`:
   - Found `on` → include attribution
   - Found `off` → strip attribution
   - Not found → run **First-Time Prompt** below, then proceed with the user's choice
3. If `{RepoName}` cannot be resolved (repo not in `.local-paths`): default to **strip** (safer for unknown repos). Do not prompt.

---

## First-Time Prompt

When `{RepoName}-ai-attribution=` is missing from `.local-paths`, ask once via AskUserQuestion:

```
question: "Include AI attribution in commits and PR descriptions for {RepoName}?"
header: "AI Attribution"
options:
  - label: "On — include attribution (Recommended)"
    description: "Adds Co-Authored-By: Claude trailer to commits and footer to PR descriptions."
  - label: "Off — strip attribution"
    description: "No AI markers in commits or PR descriptions for this repo."
```

After the user answers, append to `.local-paths`:

```
{RepoName}-ai-attribution={on|off}
```

Then proceed with that value. Do not prompt again for this repo.

---

## What "On" Means

When config is `on`:

- **Commit message body** (last line):
  ```
  Co-Authored-By: Claude <noreply@anthropic.com>
  ```
- **PR description footer** (last paragraph, separated by blank line):
  ```
  🤖 Generated with [Claude Code](https://claude.com/claude-code)
  ```

When config is `off`: omit both. Never add other AI markers (no "AI-assisted", no model name in the subject, etc.).

---

## Squash + Co-Author Preservation

When `/nase:prep-merge` squashes multiple commits:

- **Non-AI co-authors**: always preserve `Co-Authored-By` trailers (independent of this config) — those represent real humans.
- **Claude co-author**: include only if `{RepoName}-ai-attribution=on`.

---

## Changing Config Later

User can edit `.local-paths` directly. No tooling needed — the file is plain `key=value` lines.
