# Git Worktree Pattern

Shared worktree creation and cleanup pattern used by nase skills.

---

## Naming Convention

Worktree path is always a sibling directory to the repo:

```
{repo_parent}/{repo_name}-{suffix}
```

If that path already exists, append `-1`, `-2`, etc. until an available path is found.

Each skill uses its own suffix (e.g. `fsd`, `address-comments`, `prep-merge`).

## Creation

```bash
git -C {repo_path} worktree add {worktree_path} {ref}
```

Where `{ref}` is one of:
- `origin/{branch_name}` — existing remote branch (most skills, e.g. address-comments, prep-merge)
- `-b {new_branch} origin/{default_branch}` — create a new branch off default (e.g. fsd)

After creating the worktree, if you need the local branch to track the remote (not detached HEAD):

```bash
git -C {worktree_path} checkout -B {branch_name} origin/{branch_name}
```

## Key Rule

**Do NOT use `EnterWorktree`** — it creates its own worktree and won't adopt one you already created. Use absolute paths to `{worktree_path}` for all subsequent git and file operations instead.

## Recovery: branch already used by another worktree

If `git worktree add origin/{branch}` reports the branch is already checked out elsewhere (typically the main repo on the same branch), the new worktree comes up on **detached HEAD** and `checkout -B {branch} origin/{branch}` will fail with `fatal: '{branch}' is already used by worktree at '...'`.

Do **not** switch the main repo off the branch — that touches the user's working state. Instead:

1. Leave the worktree on detached HEAD.
2. Do all work (rebase, soft-reset, commit) there as usual.
3. Push using the remote branch ref directly, with a SHA-pinned lease:

   ```bash
   git -C {worktree_path} push \
     --force-with-lease={branch}:{expected_remote_oid} \
     origin HEAD:{branch}
   ```

   The lease verifies the remote SHA without needing a local branch ref; `HEAD:{branch}` lands the new commit on the remote branch. The main repo's branch ref auto-updates on next fetch.

4. Cleanup is unchanged (`git worktree remove ... --force`).

## Cleanup

After the branch has been pushed (or work is otherwise complete):

```bash
git -C {repo_path} worktree remove {worktree_path} --force
```
