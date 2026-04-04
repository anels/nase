# KB File Template

Use this structure for `workspace/kb/projects/{domain}.md`:

```markdown
# Knowledge Base — {RepoName} (Project-Specific)

## Overview
<!-- Last updated: {YYYY-MM-DD} -->
- Repo path: `{full path}`
- Purpose: {one-line description}
- Stack: {languages, frameworks, runtimes, build tools}
- Target branch: `{main branch}`

## Data Flow / Architecture
{High-level description: modules/layers, dependency graph, API boundaries, data flow}

### Module/Project Graph
{How internal projects/packages reference each other}

### API Surface
{REST endpoints, gRPC services, GraphQL schemas, message queue topics}

### Data Layer
{ORM, migrations, database type, storage abstractions, caching}

### Design Patterns
{Prominent patterns — only if clearly used}

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
  - Stages: {build → test → lint → deploy}
  - Deploy targets: {environments, regions}
  - Notable: {external template refs, required secrets, release strategy}

## Related Repos
- **{repo name}** — {relationship + specific integration point}
```
