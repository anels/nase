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

## Cleanup

After the branch has been pushed (or work is otherwise complete):

```bash
git -C {repo_path} worktree remove {worktree_path} --force
```
