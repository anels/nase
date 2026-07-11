# PR Gates Consumption — Shared Reference

Consumers (`fsd`, `address-comments`, `prep-merge`) read the repo's `## PR Gates` KB section so the commit subject, PR title, PR body, size, and local lint gates they draft already satisfy the repo's merge-blocking checks. Gates like conventional-commit format, Jira key in title, required PR-body sections, and size labels fail *fast* — but only after a push round-trip, so satisfying them up front saves a full push/fail/fix cycle.

**Producer:** `/nase:onboard` Step 3d.1 writes the `## PR Gates` section (branch-protection required checks, every `on: pull_request` workflow, what each checks, fail mode, fix recipe, skip mechanism, `Required?`, action pins, config files). Section shape lives in `.claude/docs/kb-template.md → ## PR Gates`.

This doc is the *consumer* side. It never writes the KB — if the section is stale it points the user back at `/nase:onboard`.

---

## 1. Load the gate profile

Inputs: `{repo_path}`, `{kb_file}` (the repo's `workspace/kb/projects/{domain}.md`), `{owner}/{repo}`, and the target `{base_branch}`.

Read the `## PR Gates` section from `{kb_file}` and extract a `gate_profile`:

- **commit_format** — allowed `type` set, whether a `scope` is required, subject rules, banned markers (`fixup!`/`squash!`). Source: the Commit-Lint row + `.commitlintrc*` / `commitlint.config.*` companion file.
- **pr_title** — ticket/Jira-key requirement and its placement (prefix vs suffix), length or prefix rules. Often the same gate as commit_format when the repo lints the PR title.
- **pr_body** — required sections and their minimum lengths (from the PR Description Check row, e.g. `## What` ≥ 20 chars, `## Testing` ≥ 15 chars).
- **size** — line thresholds and which bucket requires a filled `## How to Review` (from the PR Size Check row).
- **lint_gates** — the subset of PR workflows that map to a *locally runnable* linter/formatter/analyzer (super-linter, eslint, golangci-lint, dotnet format, etc.). These become pre-push local gates.
- **required_checks** — the exact branch-protection required context strings + the protected branch (the authoritative merge blockers).
- **skip_labels** — label / exempt-actor / branch-prefix exemptions. Read-only knowledge; never auto-apply them to bypass a gate.
- **config_files** — sidecar config paths (commitlintrc, `.github/labels.json`, `.github/linters/`). Read only when a specific rule value is needed.

If a field has no corresponding gate, leave it empty — a repo with no commit-lint gate imposes no commit_format constraint.

## 2. Freshness / empty fallback (live-fetch)

The `## PR Gates` section is **stale or empty** when: the section header is absent, the repo was onboarded before Step 3d.1 existed, or every data cell still holds a template placeholder (value wrapped in `{...}`). Detect placeholder rows with `^\s*\|?\s*\{.*\}` on the data cells.

When stale/empty, do a **bounded live read** at consume-time. Do not write the KB here.

```bash
# Required checks (authoritative blocker list)
gh api "repos/{owner}/{repo}/branches/{base_branch}/protection" \
  --jq '((.required_status_checks.contexts // []) + ((.required_status_checks.checks // []) | map(.context))) | .[]' 2>/dev/null
```

- **PR template** — discover via `.claude/docs/pr-creation-pattern.md` Step 1.
- **Commit format** — look for `.commitlintrc*`, `commitlint.config.*`, or a `.github/workflows/*commit*` workflow in `{repo_path}`; read the type/scope rules only if present.

If the branch-protection call fails (no admin scope), note it and fall back to the PR-template + commitlint findings alone. If KB *and* live read both yield nothing (no protection, no template, no commit lint), set `gate_profile = generic` and proceed with default `pr-creation-pattern.md` behavior — the repo simply has no discoverable gates to satisfy.

Whenever the live path is used, add one line to the caller's final report: `KB \`## PR Gates\` was empty/stale — used a live read. Run \`/nase:onboard {repo}\` to persist.`

## 3. Apply to drafted artifacts

Shape the drafted commit / title / body to satisfy `gate_profile` **before** the push or force-push. Be deterministic where the rule is mechanical; where a value can't be known, shape what you can and surface the gap — never invent a value to satisfy a gate.

- **Commit subject** — conform to `commit_format`: `<type>(<scope>): <subject>`, using only the documented type set; include a scope when it's required and derivable from the touched paths; strip `fixup!`/`squash!`. `/nase:improve-commit-message` polishes prose but does not know the repo's scope/type rules — pass the `commit_format` constraints into it (or verify the subject against them after it runs).
- **PR title** — if `pr_title` requires a ticket key, ensure it is present in the documented position. Never invent a key: if unknown, keep the template placeholder and flag it (the placeholder-preservation rules in `pr-creation-pattern.md → 2a` and prep-merge's placeholder strip already cover the surfacing).
- **PR body** — ensure every required section from `pr_body` exists and meets its minimum length, filled from the diff / task context. If a required section genuinely can't be determined, leave the heading and flag it rather than fabricating.
- **Size** — if the diff crosses a `size` threshold that mandates `## How to Review`, ensure that section is filled (this composes with fsd's own Phase 5.5 diff-size guardrail; the gate profile only adds the repo-specific *requirement*, not a second size opinion).
- **Skip labels** — never auto-apply a skip label to dodge a gate. If bypassing is genuinely warranted, surface it as an explicit user choice.

## 4. Required-check status read (prep-merge, report-only)

Before finalizing, read the live status of the required checks so the user sees what still has to go green — **report-only: warn, never block, never wait/poll.**

```bash
gh pr checks {pr_number} --repo {owner}/{repo} 2>/dev/null
```

`gh pr checks` exits non-zero when not all checks pass — that is expected signal, not a fatal error; parse the table rather than treating the exit code as failure. Cross-reference each row against `required_checks` from the gate profile and render:

```
Required checks:
  ✓ {check} — success
  ✗ {check} — failure
  … {check} — pending
  ⚠ {check} — required by branch protection but not reported yet
```

Only the `required_checks` set gates merge; advisory/visible checks can be listed separately or omitted. Do not force-push-block on a failing required check and do not wait for pending ones — surface them and let the user decide.

---

## Consumer wiring summary

| Consumer | Load profile (§1–2) | Apply to artifacts (§3) | Required-check read (§4) |
|----------|--------------------|--------------------------|---------------------------|
| `fsd` | Phase 1 (KB already loaded there) | Phase 7 commit subject, Phase 8 PR title/body/size | — (draft PR; not finalizing merge) |
| `address-comments` | Phase 1 | Phase 8 commit subject, Phase 8b PR body | — |
| `prep-merge` | Phase 1/2 | Phase 6 squash subject, Phase 7 title/body/size | Phase 10 report |

Surface the §2 stale-KB note (when triggered) in each consumer's final report.
