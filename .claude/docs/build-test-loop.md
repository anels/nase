# Build & Test Iteration Loop

Shared reference for skills that need to build and test after code changes.

---

## Step 1: Command Discovery

Get build, **lint, typecheck**, and test commands from the repo's KB file (`Build & Run Commands` section) or the repo's `CLAUDE.md`. Lint and typecheck are first-class gates — not optional polish. If they exist for the repo, they must run.

If commands are not documented, infer from project files. Lint/typecheck commands often live alongside build/test in the same config:

| File found | Build | Lint / Typecheck | Test |
|---|---|---|---|
| `package.json` | `npm run build` | `npm run lint`, `npm run typecheck` (or `tsc --noEmit`) | `npm test` |
| `Makefile` | `make build` | `make lint`, `make typecheck` (check targets) | `make test` |
| `*.sln` | `dotnet build` | analyzers run during `dotnet build` (treat warnings as errors when CI does) | `dotnet test` |
| `go.mod` | `go build ./...` | `go vet ./...`, `golangci-lint run` if configured | `go test ./...` |
| `.github/workflows/` | mirror CI's build step | mirror CI's lint/typecheck steps | mirror CI's test step |

Skip a gate cleanly only if you can prove it isn't configured (no script entry, no Make target, no CI step). When unclear, ask the user which gates apply, and record the answer in the repo's `CLAUDE.md` so future sessions don't re-ask.

If no commands can be determined after checking all sources, stop and ask:
```
question: "What commands should I use to build / lint / typecheck / test this repo?"
header: "Build & Test Commands"
```

---

## Step 2: Iteration Loop (max 5)

Each iteration runs every configured gate in this fixed order — fail fast, fix, retry. Do not skip ahead on the first pass even if a gate seems unaffected by the change; later iterations may skip gates that already passed if no relevant files changed since. Gates proven absent in Step 1 are not part of the pass/fail set.

For each iteration:

1. **Build** — on failure: read the error, identify the root cause, fix it. Do not retry the same fix twice — try a different approach.
2. **Lint** — on failure: fix the lint violation in production code. Do not disable the rule or add ignore comments unless the rule is genuinely wrong for the change (in which case explain in the commit).
3. **Typecheck** — on failure: fix the type error. Do not weaken types (`any`, `unknown` cast, nullable suppression) just to pass; if the only fix is widening, surface it as a design question instead.
4. **Test** — on failure: read the failure output, fix production code. **Never modify tests to make them pass.**
5. All configured gates pass → proceed.

---

## Step 2.5: Unrelated-Test Failure — Check Default Branch First

When a CI or local test gate fails on a test path the PR did not touch, do not start with diff-level debugging. Sanitized pattern: a PR failed on an untouched test path; the failure had been introduced on the default branch shortly before the CI run and fixed shortly after; a rebase cleared the red. One `git log` query saved an hours-long detour.

Before tracing into the diff, check the default branch for recent activity on the failing test path:

```bash
git -C {repo_path} log --since="48 hours ago" --oneline origin/{default_branch} -- {test_file_path}
```

If a commit on `origin/{default_branch}` modified the test within ~24-48h around the CI run time, the failure is likely stale. Rebase onto current default and re-run before debugging the diff:

```bash
git -C {worktree_path} fetch origin
git -C {worktree_path} rebase origin/{default_branch}
```

If `git log` on the test path is empty in that window, the failure is real for this PR — proceed with normal diff-level diagnosis.

## Step 2.6: Test-Presence Soft Gate (after all gates pass)

Diff the working tree against the branch base (the consumer skill defines the base: merge-base with the default branch for new work, `origin/{pr_branch}` for review fixes). If the diff changes production code but contains no added or modified test files, print one line:

```
Tests gate: production code changed, no test files in diff — add tests or record a justification.
```

Acceptable justifications (record in the commit body or PR body, not just chat):
- Covered by existing tests — name the exact test file(s) and why they exercise the new behavior.
- Non-testable surface — config, docs, generated files, infra manifests.
- Repo has no test infrastructure for this layer — state which layer.

This gate is advisory — never block on it. Docs/comments/fixture-only diffs skip it silently. When the consumer skill runs strict TDD, the RED gate already enforces this harder; skip the soft gate there.

## Step 3: Escalate After 5 Failures

If still failing after 5 iterations: stop, print the last build/test output in full, and ask the user for guidance. Do not commit broken code.

---

## Concurrent Worktree Builds (.NET)

When `dotnet build` / `dotnet test` may run in 2+ git worktrees of the same solution in parallel (e.g. `fsd` worktree compiling while a sibling `address-comments` worktree rebuilds), MSBuild's persistent node processes (`-nodeReuse:true` default) get shared across worktrees keyed by SDK/version and the worker pool starves — builds wedge at "Determining projects to restore…" for >10 min.

Pass `-m:1 -nodeReuse:false` to every concurrent `dotnet build`/`dotnet test` invocation (or set `MSBUILDDISABLENODEREUSE=1` env). Loses parallel project compile within a single solution, but unblocks cross-worktree concurrency. Recovery if already wedged: `pkill -9 -f MSBuild`, then re-run with the flags. Sanitized pattern: this surfaced during concurrent worktree validation.

## Circuit Breaker Rule (applies to ALL skills with loops)

Any skill that retries, polls, or iterates MUST declare a hard cap and an escalation path. The pattern:

```
max N iterations → on breach: stop, report last state, ask user
```

Never let a loop run unbounded. Even "obvious" retries can spiral — document the limit in the skill's step description. The build-test loop uses N=5; other loops may use different values, but must name them explicitly.
