# Commit & Push Pattern

Shared sequence used by `fsd`, `address-comments`, and `prep-merge`.

---

## Base Sequence

### 1. Stage explicitly

```bash
git -C {repo_or_worktree} add {each_changed_file}
```

Never use `git add -A` or `git add .` — staging by name prevents accidentally committing secrets or unrelated files.

Verify the staged diff looks correct:

```bash
git -C {repo_or_worktree} diff --cached --stat
```

### 2. Secrets scan

Glance at the staged files for hardcoded tokens, passwords, `.env` content, or personal credentials. If anything looks suspicious, stop and ask the user before proceeding.

### 3. Commit

Create an initial commit with a conventional commit message.

### 4. Improve

```
/nase:improve-commit-message --auto-accept
```

This polishes the message without pausing for confirmation.

### 5. Push

```bash
git -C {repo_or_worktree} push origin {branch}
```

---

## Rules That Apply to All Skills

- **No AI attribution**: never add `Co-Authored-By: Claude` or `Generated with Claude Code` to commits or PRs.

---

## Deviations by Skill

| Skill | Deviation |
|-------|-----------|
| `fsd` | Uses `-u origin` on first push (`push -u origin {branch}`) |
| `address-comments` | In "Confirm before push" mode: show staged diff and commit message, prompt user, stop if aborted |
| `prep-merge` | Uses `--force-with-lease` instead of normal push; stop if force-push fails (someone else pushed) |
