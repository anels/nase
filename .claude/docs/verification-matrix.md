# Verification Matrix Algorithm

Build a layered, paste-ready verification matrix the author can lift into the PR body verbatim. Every row: exact command + trigger + success criterion (never "run tests" / "deploy and check").

**Used by:**
- `/nase:discuss-pr` Step 5.5 — render in Step 6 chat output; draft an inline PR-comment when the description has no test plan.
- `/nase:fsd` Phase 8.5 — append as a `## Verification` section to the PR body; surface critical-layer + caveat in the Phase 10 report.

---

## Inputs

- **Diff** — file list + changed lines (for detecting touch areas)
- **Repo's CLAUDE.md / KB** — canonical build / test / lint / run commands (never invent commands; mark unknown rather than fabricate)
- **PR body** — if it exists (for plan-presence scan; skip when not yet drafted)
- **CI evidence** — recent commit messages, check runs, linked workflow runs (for `✅ done` status detection)

---

## 1. Detect repo + change context

- **Stack** (from repo CLAUDE.md + diff): .NET / TypeScript / Python / Go / SQL / IaC / Databricks / pipeline.
- **Repo's canonical commands** (from that repo's CLAUDE.md, `README`, `tests/`): the exact lint, build, test, and run commands. **Never invent them.** Unknown → mark `<check {repo}/CLAUDE.md>` rather than fabricate.
- **Config / DI branches**: scan diff for `appsettings.*.json`, `ASPNETCORE_ENVIRONMENT`, env-gated `ServiceCollection` registrations, feature-flag gates, multi-tenant scoping branches, build configs. If services register differently per branch, **each branch is its own matrix row** and must be exercised.
- **Telemetry surface**: scan for `TelemetryClient`, `ILogger` / structured logging, `Activity` / OTel spans, `customEvents` writes, Application Insights / Loki / Datadog emitters. If the change emits or routes telemetry, draft a concrete verification query (KQL for AI, PromQL / LogQL for OTel) and include it in the matching row's `expected`.
- **Already-done evidence**: parse PR body + recent commit messages + the latest checks/CI runs for phrases like "X/X pass", "tests added", "CI green", "verified in alpha {link}". Concrete numbers/links → mark layer ✅ done with the evidence. Vague claims ("tested locally") → keep as required with a `(not evidenced)` note.

---

## 2. Build the layered matrix

Render rows for layers that apply (skip silently if not). One row per branch when DI/config branches exist.

| Layer | When to include | Default status |
|---|---|---|
| **Unit** | any code change | ✅ done (with evidence) / required |
| **Local — config / branch A** | any service-level change with single config | required |
| **Local — config / branch B, C, …** | each additional DI/config/env branch from §1 | required — promote to 🔥 **critical** if this branch is the one the PR's primary fix targets |
| **Pipeline (CI green)** | pipeline-touch OR migrations OR schema changes | required |
| **Cloud-deploy (alpha / PR env)** | customer-facing endpoint, auth, multi-tenant, telemetry routing, infra/IaC | recommended — promote to required for auth / tenant-isolation / OTel-routing changes |
| **E2E / manual UI** | user-visible UI flow change | recommended |
| **Backfill / dry-run** | DB schema migration or pipeline-data change | required |
| **Telemetry verification** | telemetry surface detected in §1 | recommended — paste KQL into PR body and include sample window |

**Critical-layer rule:** mark exactly one row 🔥 **critical** when that layer is the *only* path that exercises the change's primary fix (e.g. a config/DI branch on a resolution-bug fix that registers a no-op there). The critical layer must not be skipped — call it out separately in the consumer's output. If no single layer is uniquely-loaded, omit the 🔥 marker rather than over-assigning it.

**Status taxonomy** (used in the matrix Status column):
- ✅ **done** — concrete evidence in PR body / CI / commits (cite the source)
- **required** — must complete before merge
- **recommended** — strongly suggested; reviewer's call
- **optional** — covers a gap that other layers also cover

---

## 3. Draft per-row fields

For each row fill four fields. Be concrete — paths, env vars, endpoints, query strings, file globs — not "run tests". Unknown → `<unknown — ask author>`, not fabricated.

- **command**: exact CLI. Examples: `dotnet test --filter "{TestFilter}"` · `{ENV_VAR}={value} dotnet run --project {Repo}/src/{App}` · `bun test apps/foo` · `bash tests/check-all.sh` · `/nase:workspace:deploy-alpha {PR}` · `kubectl apply -f manifest.yaml --dry-run=server`.
- **trigger**: how to exercise the changed code. HTTP request (method + path + payload), CLI invocation, scheduled job tick, event publish. Omit if `command` alone is the trigger (pure unit tests).
- **expected**: success criteria — response code, telemetry event name + dimensions, log line, row-count / checksum match, no-500-on-startup, etc. For telemetry rows include the KQL/PromQL directly so the author pastes and runs it.
- **why this layer**: 1 line — what slips through if this row is skipped. Especially important for the 🔥 critical row.

---

## 4. Plan-presence scan (skip when PR body not yet drafted)

Parse the PR body for section headings: `Test plan`, `Testing`, `How tested`, `Verification`, `Validation`, `QA`, `Manual test`, `Smoke test`, `## Tests`. Case-insensitive; checkbox or prose form both count.

Outcomes (informational; strictness is the consumer skill's call):
- Plan present, all required rows covered → ✅
- Plan present but some required rows uncovered → ⚠️ list the missing rows by name
- No plan at all → flag as gap and offer to paste the matrix into the PR body verbatim

---

## 5. Render

Output is a markdown table with columns `Layer | Status | Command | Trigger | Expected`. Drop columns universally empty for this PR (e.g. drop `Trigger` when every row is a pure command).

Always include below the table:
- 🔥 **Critical layer:** {row label} — {why this is the only path that exercises the fix; what slips through if skipped}.
- **Coverage caveat:** {environments that cannot cover some branches, e.g. "alpha only runs one backend — the other branch must be exercised locally pre-merge"}.
- **PR description test plan:** ✅ present and adequate | ⚠️ present but missing rows: {row list} | 🔧 missing — author should add a Verification section matching the matrix above.

If §2 produced no rows (pure docs / comments-only change), the consumer skill omits the entire verification block.
