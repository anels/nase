# KB Review - Deep Scan Checklist

> The discovery half of `/nase:kb-review`. That command owns scope, modes, repair authority, and
> the report contract; this doc owns what a deep review looks at. Read it after the deterministic
> preflight and before classifying anything into a repair class.
>
> Mode never narrows discovery. Every check below runs in `--report-only` and `--repair` exactly as
> it runs by default; only what gets *written* changes.

### Content and relationships

- Index headings, explicit links, domain-map entries, age, size, lesson candidates, effort references, and todo entries.
- Classify contradictions, duplicates, healthy overlaps, missing cross-references, stale content, orphans, sparse files, temporary artifacts, one-sided entries, low-signal platitudes, layer mixing, and lesson-promotion candidates.
- Use `.claude/docs/kb-relationship-graph.md`, `.claude/docs/kb-staleness.md`, and `.claude/docs/kb-template.md → Verification triad`. Age alone is not evidence that a fact is obsolete. Separate broken Markdown links from inert code-span references.
- Apply `.claude/docs/kb-lifecycle-layers.md` in full; every rule it states produces findings here.

### Security and propagation

- Treat every credential-like match as P0 until disproved without rendering the value. Trace whether its file enters backups, staged outbound payloads, logs, reports, or already-published comments. Remote checks are read-only.
- A secret in a backup or external comment is a propagation incident, not one local finding. Report each surface separately and name rotation or removal as a gated action.

### Authoritative state

- Validate active, done, and archived effort frontmatter against `.claude/docs/effort-model.md → Status Vocabulary` and file location.
- `workspace/efforts/` is authoritative for initiatives. `workspace/tasks/todo.md` contains independent open work only, with no checked or dropped items, no duplicate initiative state, and no unresolved effort pointer. `bash tests/check-effort-pointer-integrity.sh` enforces this both ways, so run it and repair exactly what it names rather than re-deriving the reconciliation by hand.
- Check durable indexes and manifests for unique keys, referential integrity, and atomic publication. Exercise writers, optimizers, backup, and restore helpers against a copy fixture so duplicate identifiers or a failed second write cannot delete or split state.

### Operational contracts

- Verify each documented command from its exact documented working directory in a fixture or dry-run, including required arguments and claimed output scope.
- Compare recovery claims with what the restore code actually writes. Compare version pins and targets across runbooks, deploy scripts, and live configuration evidence when available.
- Inventory backups by count, logical bytes, recent creation rate, and bounded recent content hashes. Verify content deduplication plus count or size retention; a time-only retention window does not bound repeated Stop-hook backups. Exercise unchanged content, changed content within the same timestamp granularity, and concurrent runs; archive names must be collision-safe.
- Inventory `workspace/tmp/` with a `python3 .claude/scripts/tmp-prune.py --json` dry-run. It counts kept top-level entries under `kept` (`never`, `referenced`, `recent`) and lists the deletable ones in `target_paths`. Treat an entry as disposable only when the script does. Backups exclude `workspace/tmp/`, so a pruned entry has no restore route.
- When both journal and daily log exist, compare freshness and flag lost post-wrap-up entries instead of assuming one source is complete.
