# KB File Template

## Contents

- Writing Conventions (apply to every KB write)
- Project KB Structure
- Overview
- Architecture Map
- Data Flow / Architecture
- Ownership Map
- Key Files
- Build & Run Commands
- Code Standards
- Critical Constraints
- Brittle Boundaries
- Change Playbook
- Deployment
- CI/CD Pipelines
- PR Gates
- Azure Pipelines
- Related Repos
- Cross-Validation Notes
- Knowledge Hygiene

## Writing Conventions (apply to every KB write)

Applies to project KBs and general KB entries written by `/nase:learn`, `/nase:kb-update`, `/nase:onboard`. Borrowed from `codealmanac` `.almanac/README.md` notability discipline.

**Prose rules**
- Every sentence contains a specific fact. If it doesn't, cut it.
- "is", not "serves as". No vague attribution, no hedging.
- Prose first. Bullets for genuine lists. Tables only for structured comparison.
- No formulaic conclusions. End with the last substantive fact.
- Reference env vars and config paths exactly: `ANTHROPIC_API_KEY`, not "the API key"; `~/.claude/settings.json`, not "the settings file".
- No speculative content ("chosen for scalability" when reason is unknown).

**Notability bar — write an entry when:**
- A decision that took discussion, research, or trial-and-error
- A gotcha discovered through failure
- A cross-cutting flow that spans multiple files
- A constraint or invariant not visible from the code
- A subsystem or third-party integration referenced by multiple places

**Do not** restate what code already says. **Silence is acceptable** — if nothing meets the bar, write nothing.

**Page shapes** — use as section types within KB files:
- **Entity** — a stable named thing (a library, subsystem, third-party service)
- **Decision** — "why we chose X" — include rejected alternatives and their cost
- **Flow** — a multi-step process spanning files
- **Gotcha** — a specific surprise, constraint, or invariant to preserve

See `workspace/kb/general/workflow.md → KB Writing Conventions (2026-05-13)` and `memory/feedback_kb-writing-conventions.md` for the full rationale.

---

## Project KB Structure

Use this structure for `workspace/kb/projects/{domain}.md`:

```markdown
# Knowledge Base — {RepoName} (Project-Specific)

## Overview
<!-- Last updated: {YYYY-MM-DD} -->
- Repo path: `{full path}`
- Purpose: {one-line description}
- Stack: {languages, frameworks, runtimes, build tools}
- Target branch: `{main branch}`

## Architecture Map

### Entrypoints
| Type | Entrypoint | Runtime / Host | Notes |
|------|------------|----------------|-------|
| {HTTP/worker/CLI/job/function/UI} | `{file or command}` | {runtime} | {auth, schedule, queue, port, or caller} |

### Runtime Topology
{Short current-state topology: process boundaries, deployment units, dependency direction, and primary request/event paths.}

### Data Ownership
| Data / Resource | Owner in this repo | Source of truth | Consumers |
|-----------------|--------------------|-----------------|-----------|
| {table/topic/package/config} | `{module}` | {DB/EventHub/blob/package registry/etc.} | {repos/services/jobs} |

### Async / Background Work
| Trigger | Handler | State touched | Failure / retry behavior |
|---------|---------|---------------|--------------------------|
| {timer/queue/event/schedule} | `{file:line}` | {tables/topics/files} | {retry/DLQ/idempotency} |

### Observability / Debug Hooks
| Signal | Where to look | Notes |
|--------|---------------|-------|
| {log/metric/event/dashboard/query} | `{path or dashboard}` | {dimensions, alert names, common filters} |

## Data Flow / Architecture
{High-level description: modules/layers, dependency graph, API boundaries, data flow}

### Module/Project Graph
{How internal projects/packages reference each other}

### API Surface

The two tables below feed cross-repo contract validation — every inbound endpoint and every outbound call site goes in one row each.

#### Inbound Endpoints
<!-- Used by cross-repo contract validation (.claude/docs/cross-repo-validation.md §6c) -->
| Method/Type | Route / Topic / Queue | Auth | Caller(s) | Notes |
|-------------|----------------------|------|-----------|-------|
| {GET/POST/gRPC/EventHub/Queue} | `{/api/v1/foo}` or `{topic-name}` | {JWT/MSI/Anonymous/SAS} | {known callers, "—" if unknown} | {idempotency, rate-limit, breaking-change history} |

#### Outbound Calls
<!-- Used by cross-repo contract validation (.claude/docs/cross-repo-validation.md §6c). One row per distinct call site. -->
| Target Repo | Method/Type | Route / Topic | Auth | Source File:Line | Retry/Timeout |
|-------------|-------------|--------------|------|------------------|---------------|
| `{repo-name}` | {GET/POST/Queue} | `{/api/v1/bar}` | {JWT/MSI} | `{src/path/Client.cs:42}` | {N retries, Tms timeout} |

### Contract Index
| Relationship | Kind | Source | Target / Consumer | Validation |
|--------------|------|--------|-------------------|------------|
| {API/event/package/pipeline/shared-infra} | {HTTP/gRPC/EventHub/NuGet/npm/template/base image/generated client} | `{file or pipeline}` | {repo/service/team} | {contract test, version bump, cross-repo onboard, manual check} |

### Data Layer

#### Storage Inventory
| Store | Tech | Tables / Containers / Keys | Partition / Index | Migration Tool |
|-------|------|---------------------------|------------------|----------------|
| {primary db} | {Snowflake/SQL/Cosmos/Postgres} | {comma-separated names, link to schema file} | {partition key, key indexes} | {Flyway/EF/schemachange} |

#### Schema Hot Spots
{Tables touched by 3+ services, recent migrations (last 90d), columns with non-obvious semantics — same convention used in `workspace/kb/ops/oncall-alert-patterns.md → readDB-dbCount` entry}

#### Caching & Sync
{Redis/in-mem cache layers, cache-aside vs write-through, invalidation triggers, eventual-consistency windows}

### Design Patterns
{Prominent patterns — only if clearly used}

### Config Schema
| Key | Type | Default | Where consumed | Secret? |
|-----|------|---------|----------------|---------|
| `{Setting:Path}` | {bool/int/string} | {value or "—"} | `{Service.cs:120}` | {yes/no} |

Group secrets at the top. For feature flags, link to the flag-management UI (LaunchDarkly, ConfigCat) or config file.

## Ownership Map
<!-- Updated by /nase:onboard — based on git log analysis (last 6 months) -->
| Area / Module | Primary Owner | Secondary Owner | Notes |
|---------------|--------------|-----------------|-------|
| `{dir/module}` | {name} (@{github_handle}) | {name or —} | {active/dormant/onboarding} |

### Coverage Gaps
- {directories with no clear owner or no recent commits}

### Discrepancies
- {git ownership vs declared focus conflicts}

## Key Files
- `{path}` — {purpose}

## Build & Run Commands
```{shell}
# {command}
```

## Code Standards
### Linting & Formatting
{Active linters/formatters, config files, key non-default rules}

### Code Analysis & Quality Gates
{SonarQube, codecov thresholds, TreatWarningsAsErrors, Nullable, etc.}

### Git Hooks & Pre-commit
{Husky, pre-commit-config, lefthook}

### Naming Conventions
{File naming, test naming patterns, PascalCase vs camelCase}

### Dependency Management
{Central package management, lockfile strategy, renovate/dependabot}

## Critical Constraints
1. {constraint}

## Brittle Boundaries
<!-- Top-3 high-risk integration / contract / data boundaries an AI agent should know about BEFORE touching code. Refreshed by /nase:onboard Step 3h. Rationale: change-absorption capacity comes from explicit contracts at brittle boundaries (CATS framework — see workspace/kb/general/llm.md → AI Code Quality & Velocity). -->
| Boundary | Why brittle | Last incident / drift | Touch protocol |
|----------|------------|----------------------|----------------|
| `{path or interface}` | {auth shape change risk / cross-repo contract / schema lock-in / etc} | {date + ref} | {what to verify before editing — e.g. "run contract tests against insights-monitoring", "check Looker partition before COALESCE", "validate Avro schema vs LogExport target"} |

## Change Playbook
| Change type | Inspect first | Minimum verification | Cross-repo checks | Release concerns |
|-------------|---------------|----------------------|-------------------|------------------|
| {API route/auth} | `{controller/client/spec}` | {focused tests + contract check} | {consumer KB / generated clients} | {versioning, rollout, docs} |
| {schema/data model} | `{migration/model/job}` | {migration + read/write tests} | {downstream jobs/dashboards} | {backfill, partition, retention} |
| {pipeline/deploy} | `{yaml/terraform/helm}` | {pipeline dry-run/lint} | {template/base image consumers} | {rings, approvals, freeze} |

## Deployment
### Container & Orchestration
{Dockerfile, Helm charts, K8s manifests, docker-compose}

### Environments & Rollout
{Dev/staging/prod, ring-based/blue-green/canary rollout, regions}

### Cloud Resources
{Terraform, ARM, Bicep — provisioned infra}

### Local Dev Setup
{How developers run the project locally}

## CI/CD Pipelines
- **{pipeline name}** (`{file path}`)
  - Trigger: {push/PR/tag to which branches}
  - Stages → Jobs: {stage A → [jobs], stage B → [jobs]}
  - Deploy targets: {env names → regions; link to deployment matrix table below}
  - Service connections: {ARM connections, GitHub PATs, ACR connections referenced}
  - Required secrets / variable groups: {variable group names; flag rotation owners if known}
  - External template refs: {`extends: template@resource` with pinned version + repo}
  - Approval gates: {which environments require approver groups; list groups}
  - Release strategy: {ring-based / blue-green / canary / direct + cadence}
  - Median run time: {minutes; capture from last 10 builds when available}

### Pipeline → Environment Matrix
<!-- One row per (pipeline, environment) pair so cross-repo validation can answer "what pipeline ships RTM to NE prod?" -->
| Pipeline | Environment | Region(s) | Cluster / RG / Function App | Approvers | Notes |
|----------|-------------|-----------|----------------------------|-----------|-------|
| {name} | {alpha/staging/prod} | {ne, eus, jp} | `{RG or cluster name}` | {group} | {gates, freeze windows} |

## PR Gates
<!-- Refreshed by /nase:onboard Step 3d.1. Captures every check a PR must clear so commit/fsd/prep-merge sessions don't push work that CI rejects. -->

### Branch-protection required checks
<!-- Authoritative blocker list — derived from `required_status_checks.contexts[]` and `required_status_checks.checks[].context`. These exact context names block merge. -->
| Protected branch | Required check (context name) | Source workflow / system |
|------------------|------------------------------|--------------------------|
| `{develop}` | `{exact context string}` | `{.github/workflows/foo.yml or external system}` |

### Pull-request workflows
<!-- Every `.github/workflows/*` with `on: pull_request`. "Required?" = `yes` if name matches a branch-protection context; `advisory` if `continue-on-error: true`; `visible` otherwise. -->
| Gate | Workflow file | Trigger | What it checks | Fail mode | Fix recipe | Skip mechanism | Required? |
|------|---------------|---------|----------------|-----------|------------|----------------|-----------|
| {Commit Lint} | `.github/workflows/commitlint.yml` | PR → `{develop}` | {conventional-commit format; blocks `fixup!` commits} | {`Lint commits` step exits non-zero on non-conventional subject} | {use `<type>(<scope>): <subject>`; run `/nase:improve-commit-message`} | {none} | {visible} |
| {PR Description Check} | `.github/workflows/pr-description-check.yml` | PR → `{develop}` | {`## What` ≥ 20 chars, `## Testing` ≥ 15 chars, no lazy-only content} | {`::error::"What" is too short`, etc.} | {fill PR template `## What` + `## Testing` sections} | {`skip-description-check` label; exempt `renovate[bot]` / `dependabot[bot]`} | {visible} |
| {PR Size Check} | `.github/workflows/pr-size-check.yml` | PR → `{develop}` | {production lines changed; large >400, xl >800; xl requires `## How to Review`} | {`PR has N production lines but "How to Review" is empty`} | {fill `## How to Review` for large PRs; split into smaller PRs} | {`skip-size-check` label} | {visible} |

### Third-party action pins
<!-- Pinned refs for debugging version-drift incidents. -->
- `{action@version}` — used by `{workflow file}` for `{purpose}`

### Companion config files
<!-- Sidecar config the gates read. Paths only — do not inline. -->
- `{path/to/.commitlintrc.json}` — commitlint rules
- `{.github/labels.json}` — super-labeler rules
- `{.github/linters/}` — super-linter rule overrides

## Azure Pipelines
<!-- definitionId: ADO UI → Pipelines → select pipeline → URL parameter ?definitionId=NNNN -->
<!-- ADO: org=https://dev.azure.com/your-org  project=FILL_IN -->

| Pipeline | File | definitionId | Trigger | Stages |
|----------|------|-------------|---------|--------|
| {name} | `{yaml_relative_path}` | `FILL_IN` | {trigger summary} | {stage names} |

### Pipeline Parameters
#### {name} (`{yaml_path}`)
| Param | Type | Default | Options | Description |
|-------|------|---------|---------|-------------|
| {param.name} | {param.type} | {param.default or —} | {param.values or —} | {param.displayName} |

## Related Repos
<!-- Outbound integration claims; cross-validated against target repo's `## API Surface → Inbound Endpoints` -->
- **{repo name}** — {relationship + specific integration point + link to source file or pipeline}

## Cross-Validation Notes
<!-- Updated by /nase:onboard cross-validation pass (.claude/docs/cross-repo-validation.md). Read-only summary — do not edit by hand. -->
- Last cross-validated: {YYYY-MM-DD}
- Ownership drift: {none / N issues — see report}
- Contract drift: {none / N drift / N partial / N unknown}
- Tracker sync: {in sync / N cells differ — see report}

## Knowledge Hygiene
<!-- Updated by /nase:onboard using .claude/docs/kb-hygiene.md and .claude/scripts/kb-hygiene-scan.py. -->
- Last hygiene scan: {YYYY-MM-DD}
- Last deep scan: {YYYY-MM-DD}
- Auto-fixed: {none / N items}
- Stale-marked: {none / N items}
- Needs human review: {none / N items}
```
