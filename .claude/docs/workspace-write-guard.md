# Workspace Write Guard

Shared guard for skills that write durable workspace files such as `workspace/kb/**`,
`workspace/tasks/**`, `workspace/skills/**`, or other allowed targets listed below.
Temporary reports under `workspace/tmp/` can skip the mtime gate, but still should use
unique filenames when reruns may overlap.

For generated repo docs outside the nase workspace, reuse the read/stage/diff/gate/drift
algorithm manually unless the target is first staged into an allowed workspace path.

## Default Flow

Use `.claude/scripts/workspace-write-guard.py` for full-file durable writes to
allowed workspace targets. The caller still owns producing the complete proposed
target content; the helper owns target allowlisting, staging, diff output, and
final drift rejection.

1. **Read before write.** If the target exists, record both:
   - mtime: `stat -f %m "$file" 2>/dev/null || stat -c %Y "$file"`
   - hash: `shasum -a 256 "$file"`
2. **Stage first.** Write the proposed full replacement or append block to
   `workspace/tmp/staged-{skill}-{slug}-{YYYYMMDD-HHMMSS}.md`.
3. **Show the diff.** Diff target vs staged output before applying:
   ```bash
   diff -u "$target" "$staged" || true
   ```
   For a new file, show the planned path and first 40 lines.
4. **Gate durable writes.** Use `AskUserQuestion` unless the caller explicitly
   passed an accepted auto mode and that skill documents its auto-write criteria.
5. **Check for drift immediately before write.** Re-read mtime/hash. If either
   changed since step 1, stop and report:
   `Target changed while drafting; staged file preserved at {path}`.
6. **Apply narrowly.** Replace or append only the documented target. Do not run
   broad formatters over adjacent files.

## Helper Usage

Prepare the proposed complete target file for an allowed workspace target first,
then run:

```bash
python3 .claude/scripts/workspace-write-guard.py stage \
  --target "$target" \
  --content-file "$proposed" \
  --skill "$skill" > workspace/tmp/write-guard.json
```

Show the diff before applying:

```bash
staged=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["staged"])' workspace/tmp/write-guard.json)
python3 .claude/scripts/workspace-write-guard.py diff \
  --target "$target" \
  --staged "$staged" || true
```

After the user gate or documented auto-write gate, apply with the recorded
metadata:

```bash
mtime_ns=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["target"]["mtime_ns"])' workspace/tmp/write-guard.json)
sha256=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["target"]["sha256"])' workspace/tmp/write-guard.json)
staged_sha256=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["staged_sha256"])' workspace/tmp/write-guard.json)
python3 .claude/scripts/workspace-write-guard.py apply \
  --target "$target" \
  --staged "$staged" \
  --expected-mtime-ns "$mtime_ns" \
  --expected-sha256 "$sha256" \
  --expected-staged-sha256 "$staged_sha256"
```

If the target changed, `apply` exits `3` and prints:
`Target changed while drafting; staged file preserved at {path}`.

For a guarded rename that also replaces file content, use `apply-move` instead
of `apply` followed by `mv`. It rechecks the source and atomically refuses an
existing destination, so a stale `done/{slug}.md` cannot be overwritten. It
publishes the destination before hiding the source, preserves the source mode,
fsyncs the published file and both affected directories before deleting the
last original copy, and rolls back its own intact destination on a caught
failure. If another writer replaces a path, it preserves that entry in place or
moves it to a unique recovery path instead of deleting or overwriting it:

```bash
python3 .claude/scripts/workspace-write-guard.py apply-move \
  --target workspace/efforts/{slug}.md \
  --destination workspace/efforts/done/{slug}.md \
  --staged "$staged" \
  --expected-mtime-ns "$mtime_ns" \
  --expected-sha256 "$sha256" \
  --expected-staged-sha256 "$staged_sha256"
```

Both apply modes acquire the repository workspace-mutation lock. They bind the
reviewed staged bytes by SHA-256, claim the old target before publishing, and
refuse to overwrite a target recreated by another writer. Direct durable writes
that bypass this helper are outside the concurrency contract. The lock rejects
symlink or special-file substitutions for `.nase-locks`, its lock directory,
owner, recovery guard, and stale quarantine paths before reading or mutating
them. Dead-owner recovery only renames and removes a validated lexical lock.

Allowed targets are durable workspace paths under `workspace/kb/`,
`workspace/tasks/`, `workspace/skills/`, `workspace/efforts/`,
`workspace/journals/`, `workspace/logs/`, `workspace/context.md`,
`workspace/communication-style.md`, and generated workspace skill wrappers
under `.claude/commands/nase/workspace/`.
`workspace/tmp/` and arbitrary paths outside the allowlist are intentionally rejected as targets.

## Append-Only Exceptions

Daily logs, journal append sections, and skill-usage JSONL can append without a
diff prompt, but should still create the parent directory and avoid rewriting
existing entries.

### Generated Integrity-Manifest Exception

`workspace-skill-integrity.py write-manifest` may atomically replace only the
ignored `workspace/skills/.nase-manifest.json` after it verifies every local
source and generated wrapper are in sync and no legacy generated native mirror
remains. It writes a source-hash baseline with mode `0600`, never source
content. It must refuse to write on any check failure. This narrow
generator-owned exception does not permit direct writes to other
`workspace/skills/` files.

## Auto-Accept Rules

`--auto-accept` may skip the human prompt only when the skill has an explicit
quality bar and deterministic target selection. It does not skip the final
mtime/hash drift check. If the quality bar fails, save the staged draft under
`workspace/tmp/` and stop without mutating durable workspace files.
