# CLI Tooling

Use CLI tools in nase skills only when they improve evidence quality, reduce
context volume, or make verification more deterministic.

## Selection Rules

- Prefer stable structured output: `--json`, `-o json`, JSONL, or output that
  can be piped to `jq` / `yq`.
- Prefer non-interactive commands. TUI-first tools should not appear in skill
  contracts unless they also have a scriptable mode.
- Guard optional binaries with `command -v` or `.claude/scripts/tool-availability.py`.
- Missing optional tools warn or skip; they must not block unrelated workflows.
- Scanner output is not authoritative. `semgrep` and `trivy` findings must be
  verified against file, line, and diff-scope evidence before becoming review or
  audit findings.
- For large logs, CSVs, JSONL, or command outputs, use aggregation tools first
  and feed only summaries into the model.
- Keep install recommendations small. Prefer the daily set (`ast-grep`,
  `gitleaks`, `difftastic`, `duckdb`, `ccusage`) plus task-specific tools over
  recommending every detectable binary.

## Availability Probe

Use the shared probe instead of open-coded `command -v` loops:

```bash
python3 .claude/scripts/tool-availability.py --group baseline --format table
python3 .claude/scripts/tool-availability.py --all --format json
python3 .claude/scripts/tool-availability.py --missing --install brew
```

The probe records the user-facing tool name, executable name, Homebrew formula,
availability status, resolved path, and workflow impact.

## Tool Groups

| Group | Tools | Use |
|-------|-------|-----|
| `baseline` | `rg`, `fd`, `yq`, `shellcheck`, `shfmt` | Fast repo exploration and common local verification. `/nase:doctor` checks these as warning-only. |
| `ci` | `actionlint` | GitHub Actions validation only when workflow files are in scope. Not part of the default install recommendation. |
| `review` | `ast-grep`, `semgrep`, `trivy` | Structural code claims and focused security/dependency/container/IaC review. |
| `security` | `gitleaks`, `hadolint` | Secret scanning plus Dockerfile-only linting. `hadolint` is advanced and not part of the default install recommendation. |
| `diff` | `difft` | Syntax-aware diff summaries when raw diffs are too noisy or token-heavy. |
| `repo` | `rga`, `just`, `ctags` | Search non-text docs, discover canonical project commands, and optionally build symbol inventories. |
| `data` | `duckdb`, `qsv`, `jc`, `mlr` | Local aggregation over logs, CSV, JSON, JSONL, or Parquet. Prefer `duckdb`; use `qsv` for CSV sampling; treat `jc`/`mlr` as advanced fallbacks. |
| `usage` | `ccusage` | Coding-agent token and cost summaries for stats/recap context. |
| `api` | `http`, `grpcurl`, `websocat` | REST and gRPC smoke checks. Use `websocat` only for WebSocket-specific tasks. |
| `docs` | `lychee`, `pandoc`, `pdftotext`, `qpdf`, `magick` | Link checks, document/PDF inspection, or conversion. Use `lychee` only for docs/link QA and `magick` only for image-specific work. |
| `perf` | `hyperfine` | Advanced local command benchmarks when a performance claim matters. |

## Skill Integration Map

| Skill | Tooling rule |
|-------|--------------|
| `discuss-pr` | Use `rg`/`fd` for focused context gathering; use `difft` for syntax-aware diff summaries; use `yq` for YAML diffs; use `actionlint` only for changed GitHub Actions workflows when installed; use `ast-grep` for structural pattern claims; use focused `semgrep`/`trivy`/`gitleaks` only when risk signals justify it. Use `hadolint` only for changed Dockerfiles when it is already installed. |
| `fsd` / `address-comments` | Run optional post-edit gates by changed file type: shell -> `shellcheck` and optional `shfmt`; GitHub Actions -> `actionlint` only when installed; secret-risk or staged diff -> `gitleaks`; YAML/config -> `yq`; repeated code-pattern edits -> `ast-grep`; Dockerfile -> `hadolint` only when already installed. |
| `onboard` | Use `rg`/`fd` for inventory, `rga` only for docs-heavy repos or archives, `just` only when a Justfile exists, optional `ctags` only for very large or unfamiliar repos where symbol inventory would reduce later searches, and `yq` for config/pipeline parsing. Do not write local tool availability into repo KB. |
| `tech-debt-audit` | Optional `semgrep`, `trivy`, and `gitleaks` passes can seed candidates, but verified evidence remains required. Use `actionlint` only for GitHub Actions-heavy repos and `hadolint` only for Dockerfile-heavy repos when already installed. |
| `skill-audit` | Native pattern scan stays canonical; `semgrep` may supplement injection or exfiltration checks when installed. |
| `stats` / `recap` | Prefer `duckdb` for large JSONL/CSV/log aggregation, use `qsv` for quick CSV sampling, and use `ccusage` for coding-agent token/cost summaries. Return compact summaries only. |

## Integration Contracts

- Skills that mutate code (`fsd`, `address-comments`) run optional post-edit
  gates only after normal build/test evidence exists and only for changed file
  types.
- Skills that write KB or recap artifacts (`onboard`, `tech-debt-audit`,
  `recap`) may mention skipped optional tooling in the transient report, but
  must not make local tool availability part of durable repo facts.
- Security scanners (`semgrep`, `trivy`, `gitleaks`) produce leads, not
  conclusions. Every accepted finding needs a source file, line, and scope
  check. Run `gitleaks` with `--redact` and JSON output; secret values must
  stay redacted. Treat `hadolint` as an advanced Dockerfile-only lint, not a
  general security scanner.
- Aggregation tools (`duckdb`, `qsv`, and advanced fallbacks such as `mlr` or
  `jc`) should reduce token use by producing counts, top-N tables, and compact
  CSV/JSON summaries before model analysis.
- Repo inventory tools (`rga`, optional `ctags`) may generate local caches or
  indexes; do not commit those artifacts or write machine-local paths into KB.
