---
name: nase:restore
description: "Restore workspace/ from a backup. Use after migration or deletion, when local state is out of sync, or for sync workspace, recover workspace, restore backup, or pull backup."
argument-hint: "[backup path]"
pattern: pipeline
category: Backup & restore
---

Restores from timestamped zip backups. Creates a pre-restore snapshot before overwriting, so you can always roll back.

## Steps

### 0. Language preflight (MUST run first, non-negotiable)

Follow `.claude/docs/language-config.md` → Minimum Step 0 block.

### 1. Read backup config
- Resolve workspace root: `NASE_ROOT=$(git rev-parse --show-toplevel)`
- Read `backup-target` from `$NASE_ROOT/.local-paths`
- If `.local-paths` does not exist or has no `backup-target=` entry, tell the user: no backup target configured — run `/nase:init` first

### 2. List available backups
List all backups in the target directory. Current `stop-backup.sh` creates `.zip` archives; keep `.7z` support for older/manual backups:
```bash
ls -1 "$TARGET"/nase-backup-*.7z "$TARGET"/nase-backup-*.zip 2>/dev/null | sort -r
```

For each backup, show:
- Filename (contains timestamp: `nase-backup-YYYYMMDD-HHMMSS.{7z|zip}`)
- File size: `du -sh "$file" | cut -f1`

If no backups found, check if old flat-copy backup exists (`$TARGET/context.md`):
- If yes: "Found legacy flat-copy backup (pre-archive format). This cannot be restored with the current restore command. Copy manually if needed."
- If no: "No backups found at {TARGET}."

### 3. Let user choose a backup
Use AskUserQuestion to let the user pick which backup to restore. Default to the latest (first in reverse-sorted list).

Show the 5 most recent backups as options, plus "Other" for older ones:
```
question: "Which backup do you want to restore?"
header: "Select Backup"
options:
  - label: "nase-backup-YYYYMMDD-HHMMSS.{7z|zip} (SIZE)" , description: "Latest backup"
  - label: "nase-backup-YYYYMMDD-HHMMSS.{7z|zip} (SIZE)" , description: "2nd most recent"
  ... (up to 5)
  - label: "Other"                                       , description: "Type a filename or list more"
```

Resolve the selected backup to a canonical path before using it. The helper canonicalizes both paths, treats a bare name as relative to the backup target, and rejects any selection that escapes the target or is not a `nase-backup-*.{zip,7z}` archive:

```bash
ZIP_PATH=$(python3 "$NASE_ROOT/.claude/scripts/restore-workspace.py" resolve-backup \
  --target "$TARGET" --selection "$SELECTED_BACKUP") || exit 1
```

The `|| exit 1` is load-bearing: command substitution otherwise leaves `ZIP_PATH` empty on a rejected selection and the flow walks into `inspect` with no archive. Report the helper's error and stop — never fall back to the raw selection.

### 4. Inspect and confirm

Create a persisted preview manifest before asking for confirmation. The helper parses only archive member records, validates both supported payload shapes, rejects unsafe paths and link metadata, and binds the preview to the archive bytes and current workspace inventory:

```bash
mkdir -p "$NASE_ROOT/.nase-restore"
MANIFEST="$NASE_ROOT/.nase-restore/preview-$(date +%s)-$$.json"
python3 "$NASE_ROOT/.claude/scripts/restore-workspace.py" inspect \
  --root "$NASE_ROOT" \
  --archive "$ZIP_PATH" \
  --manifest-out "$MANIFEST"
jq -r '.local_only[]? | select(startswith("tmp/") | not)' "$MANIFEST"
jq -r '[.local_only[]? | select(startswith("tmp/"))] | length' "$MANIFEST"
```

`workspace/tmp/` is excluded from the archive by design (`stop-backup.sh` passes `-x!tmp`),
so every `tmp/` path is `local_only` on **every** restore - thousands of them on an active
workspace. Listing them buries the entries that actually matter, so show the non-`tmp/`
paths individually and `tmp/` only as a count.

If the non-`tmp/` list is non-empty, warn: "The following files exist locally but not in the
backup and will be removed from the restored workspace. They remain in the pre-restore
snapshot." Then add one line for the scratch bucket: "Plus {N} files under `workspace/tmp/`,
which no backup contains; they are also retained in the pre-restore snapshot."

Then confirm:
```
question: "Restore will overwrite workspace/ with {ZIP_NAME}. Files to be deleted (not in backup): {N or 'none'}."
header: "Confirm Restore"
options:
  - label: "Yes - restore now" , description: "Atomically replaces workspace/; non-empty workspace is retained as a snapshot"
  - label: "No - abort"        , description: "No changes made"
```

### 5. Apply the inspected transaction

After explicit confirmation, apply the exact manifest. `apply` rechecks the archive and workspace inventory, takes the repository mutation lock, extracts and validates a sibling candidate directory, journals each directory-rename transition, and never overwrites a workspace recreated by another process:

```bash
python3 "$NASE_ROOT/.claude/scripts/restore-workspace.py" apply \
  --root "$NASE_ROOT" \
  --manifest "$MANIFEST"
```

Do not copy, delete, or extract directly into `workspace/`. A missing or empty workspace is valid and does not require a snapshot. A non-empty workspace is renamed to a unique `workspace-pre-restore-{timestamp}-{uuid}/workspace` snapshot and retained after success.

If `apply` reports an existing journal or a prior restore was interrupted, recover it before inspecting another archive:

```bash
python3 "$NASE_ROOT/.claude/scripts/restore-workspace.py" recover --root "$NASE_ROOT"
```

Recovery uses the fsynced state (`prepared`, `old_moved`, or `new_promoted`) to finish or roll back. It never guesses ownership or overwrites a foreign `workspace/`; on such a race it reports and preserves the live workspace, snapshot, and candidate paths.

On a new machine, also suggest `/nase:init` to verify hooks and config.

### 6. Verify integrity

- Read the helper JSON result and report its restored file count.
- Check whether `workspace/context.md` exists. If absent, warn that the selected backup may be incomplete; do not roll back a completed transaction automatically.
- Keep the snapshot until the user verifies the restored workspace.

### 7. Report
- Which backup was restored and from where
- Timestamp extracted from filename
- File count before and after
- Path of the pre-restore snapshot when one was created
- Any candidate, snapshot, or foreign workspace paths retained for manual recovery
- Reminder: the Stop hook will continue creating zip backups on future session ends
