# Azure Pipeline KB Extraction — Capture + KB-Write Spec

Used by `/nase:onboard` Step 3d (Azure-specific portion) and Step 4.5. Covers (a) what to pull out of each Azure Pipeline YAML file, (b) how to write it into the per-repo KB's `## Azure Pipelines` section.

Skill body cites this doc instead of inlining the rules. Schema for the KB section itself lives in `.claude/docs/kb-template.md → ## Azure Pipelines`.

---

## Capture (during Step 3d scan)

For every Azure Pipeline YAML in the repo (`.pipelines/**/*.yml`, `azure-pipelines.yml`, `azure-pipelines.yaml`), extract:

| Field | Source | Notes |
|---|---|---|
| `parameters:` block | each entry's `name`, `displayName`, `type`, `default`, `values` | Used to populate `### Pipeline Parameters` subsection per pipeline |
| `stages:` | each stage's display name | Goes into the pipelines-table `Stages` column |
| `trigger:` / `pr:` | branch conditions | Goes into the `Trigger` column |
| Top comment line | first `#`-prefixed line of the file | Pipeline purpose, one line |
| `resources.repositories:` | each entry's `ref:` pin | Template references that are easy to miss when bumping versions |

In addition to the YAML-only data above, retain the generic per-pipeline capture from Step 3d's main bullet — trigger, stages→jobs, deploy targets, service connections, secrets / variable groups, external template refs, approval gates, release strategy, median run time when discoverable — so the `(pipeline, env, region, cluster/RG/Function App, approvers)` matrix can be built without re-reading YAML.

---

## KB Write (Step 4.5)

Skip the whole step if no Azure Pipeline YAML was found.

### 4.5a — Write `## Azure Pipelines` to the repo KB

Locate or create an `## Azure Pipelines` section in `workspace/kb/projects/{domain}.md`. Place it after `## CI/CD Pipelines` if that section exists. Use the schema from `.claude/docs/kb-template.md → ## Azure Pipelines` (header comments, pipelines table, parameters table) — do not re-author the schema here.

Fill rows from the captured YAML data:

- One row per pipeline file with `File`, `Trigger`, `Stages`. Leave `definitionId` as `FILL_IN`.
- One `### Pipeline Parameters` subsection per pipeline that has a `parameters:` block.
- For the `<!-- ADO: ... project=... -->` comment, infer `project` from `extends: template@{resource}` in the YAML when possible; otherwise leave `FILL_IN`.

**Idempotency** — if the section already exists with user-filled `definitionId` values, do **not** overwrite those. Only add rows for newly-discovered pipelines and update parameters for existing ones.

### 4.5b — Confirm to user

No per-repo skill generation needed — the per-repo KB section above is consumed by whatever trigger mechanism the user prefers. If a workspace skill named `run-ado-pipeline` exists locally (check `workspace/skills/`), it reads this section directly; otherwise trigger via the ADO UI or `az pipelines run`.

Report shape:

```
Found {N} Azure Pipeline YAML(s) in {RepoName}:
  {yaml_path} — {pipeline-name} [{trigger summary}]
  ...

✓ KB updated → workspace/kb/projects/{domain}.md (## Azure Pipelines section)

⚠ Action required: fill in definitionId value(s) in workspace/kb/projects/{domain}.md → ## Azure Pipelines
  How: ADO UI → Pipelines → click pipeline → URL parameter ?definitionId=NNNN

Trigger via your preferred mechanism once definitionId is filled (workspace skill `run-ado-pipeline` if installed, ADO UI, or `az pipelines run --id NNNN`).
```
