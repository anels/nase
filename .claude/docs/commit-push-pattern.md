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

**Line-ending churn guard.** The Edit/Write tools can normalize a mixed CRLF/LF file to all-CRLF (or flip CRLF→LF), inflating a small change into a large whitespace-only diff. If any staged file may have CRLF/mixed endings, compare the plain stat against an ending-insensitive one:

```bash
git -C {repo_or_worktree} diff --cached --stat
git -C {repo_or_worktree} diff --cached --ignore-cr-at-eol --stat
```

If the two disagree, the save normalized line endings — the real change is buried in churn. Fix by preserving the original endings, not by rebuilding blindly: restore the file's original bytes (`git -C {repo_or_worktree} checkout {base} -- {file}`), then reapply only the intended logical edit matching that region's local `\n`/`\r\n` (byte-exact; assert the replacement hits exactly once). Re-verify that `--ignore-cr-at-eol --stat` now matches the plain `--stat`.

### 2. Secrets scan

Glance at the staged files for hardcoded tokens, passwords, `.env` content, or personal credentials. If anything looks suspicious, stop and ask the user before proceeding.

### 3. Commit

Create an initial commit with a conventional commit message.

When passing the message via a file in a worktree (`git -C {worktree} commit -F {file}`), `{file}` MUST be an absolute path — `-F` resolves it against the worktree cwd, not the caller's, so a nase-workspace-relative path silently fails to read.

### 4. Improve commit message

Skip this step unless the skill's deviation row below explicitly includes it.

```
/nase:improve-commit-message --auto-accept
```

This polishes the message without pausing for confirmation.

### 5. Push

**Verify the commit landed before pushing** (load-bearing for the force-push deviations below). A force-push after an unverified commit can push a `0`-commits-ahead HEAD (e.g. a `commit -F` that silently failed to read its message file, leaving HEAD at the merge-base), which wipes the branch to base — and a `0`-commits-ahead force-push AUTO-CLOSES the PR:

```bash
git -C {repo_or_worktree} rev-list --count {base}..HEAD   # must be >= 1
```

Confirm the HEAD SHA changed from the pre-commit SHA. Never chain `commit && push --force-with-lease` in one unverified block.

```bash
git -C {repo_or_worktree} push origin {branch}
```

---

## Rules That Apply to All Skills

- **AI attribution in commit messages**: per-repo config — see `.claude/docs/ai-attribution.md`. Before Step 3 (commit), resolve `{RepoName}-ai-attribution` from `.local-paths`; prompt once if missing; include or strip the `Co-Authored-By: Claude` trailer per the resolved value.
- **No AI attribution in inline review comments or Slack** — always strip, regardless of repo config.

---

## Deviations by Skill

| Skill | Step 4 (improve) | Push deviation |
|-------|-----------------|----------------|
| `fsd` | Run | Uses `-u origin` on first push (`git -C {worktree} push -u origin {branch}`) |
| `address-comments` | Skip | In "Confirm before push" mode: show staged diff and commit message, prompt user, stop if aborted |
| `prep-merge` | Run | Uses `--force-with-lease`; stop if force-push fails (someone else pushed). Apply the Step 5 "commit landed" assertion first — a `0`-ahead force-push silently closes the PR (prep-merge verifies PR state afterward as a safety net) |
