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

### 4. Improve commit message

Skip this step unless the skill's deviation row below explicitly includes it.

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

| Skill | Step 4 (improve) | Push deviation |
|-------|-----------------|----------------|
| `fsd` | Run | Uses `-u origin` on first push (`git -C {worktree} push -u origin {branch}`) |
| `address-comments` | Skip | In "Confirm before push" mode: show staged diff and commit message, prompt user, stop if aborted |
| `prep-merge` | Run | Uses `--force-with-lease`; stop if force-push fails (someone else pushed) |
