# Workspace Write Guard

Shared guard for skills that write durable workspace files such as `workspace/kb/**`,
`workspace/tasks/**`, `workspace/skills/**`, generated repo docs, or Confluence drafts.
Temporary reports under `workspace/tmp/` can skip the mtime gate, but still should use
unique filenames when reruns may overlap.

## Default Flow

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

## Append-Only Exceptions

Daily logs, journal append sections, and skill-usage JSONL can append without a
diff prompt, but should still create the parent directory and avoid rewriting
existing entries.

## Auto-Accept Rules

`--auto-accept` may skip the human prompt only when the skill has an explicit
quality bar and deterministic target selection. It does not skip the final
mtime/hash drift check. If the quality bar fails, save the staged draft under
`workspace/tmp/` and stop without mutating durable workspace files.
