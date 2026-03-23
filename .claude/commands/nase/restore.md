---
name: nase:restore
description: Restore workspace/ from a zip backup. Use after a machine migration, accidental deletion, when workspace/ is out of sync with the backup, or when asked to "sync workspace/", "recover workspace", "restore from backup", or "pull backup".
---

Restores from timestamped zip backups. Creates a pre-restore snapshot before overwriting, so you can always roll back.

## Steps

### 1. Read backup config
- Read `backup-target` from `$NASE_ROOT/.local-paths` (workspace root)
- If `.local-paths` does not exist or has no `backup-target=` entry, tell the user: no backup target configured — run `/nase:init` first

### 2. List available backups
List all zip backups in the target directory:
```bash
ls -1 "$TARGET"/nase-backup-*.zip 2>/dev/null | sort -r
```

For each backup, show:
- Filename (contains timestamp: `nase-backup-YYYYMMDD-HHMMSS.zip`)
- File size: `du -sh "$file" | cut -f1`

If no zip backups found, check if old flat-copy backup exists (`$TARGET/context.md`):
- If yes: "Found legacy flat-copy backup (pre-zip format). This cannot be restored with the current restore command. Copy manually if needed."
- If no: "No backups found at {TARGET}."

### 3. Let user choose a backup
Use AskUserQuestion to let the user pick which backup to restore. Default to the latest (first in reverse-sorted list).

Show the 5 most recent backups as options, plus "Other" for older ones:
```
question: "Which backup do you want to restore?"
header: "Select Backup"
options:
  - label: "nase-backup-YYYYMMDD-HHMMSS.zip (SIZE)" , description: "Latest backup"
  - label: "nase-backup-YYYYMMDD-HHMMSS.zip (SIZE)" , description: "2nd most recent"
  ... (up to 5)
  - label: "Other"                                    , description: "Type a filename or list more"
```

### 4. Confirm with user
Before asking for confirmation, show files that exist in `workspace/` but NOT in the selected backup:
```bash
# List files in the zip
7z l -slt "$ZIP_PATH" | grep "^Path = " | sed 's/^Path = //' | sort > /tmp/backup-files.txt
# List files in current workspace/
(cd "$NASE_ROOT/workspace" && find . -type f | sort) > /tmp/local-files.txt
# Files that will be deleted
comm -23 /tmp/local-files.txt /tmp/backup-files.txt
```
If any such files exist, warn: "The following files exist locally but not in the backup and will be DELETED by the restore."

Then confirm:
```
question: "Restore will overwrite workspace/ with {ZIP_NAME}. Files to be deleted (not in backup): {N or 'none'}."
header: "Confirm Restore"
options:
  - label: "Yes — restore now"  , description: "Overwrites workspace/ with backup; snapshot created first"
  - label: "No — abort"          , description: "No changes made"
```

### 5. Create pre-restore snapshot
Before any changes, create a local snapshot for rollback:
```bash
cp -rp "$NASE_ROOT/workspace" "$NASE_ROOT/workspace-pre-restore-$(date +%Y%m%dT%H%M%S)/"
```
Tell the user: "Snapshot created at `workspace-pre-restore-{timestamp}/`. Delete it once you've verified the restore."

Before proceeding, verify the snapshot was created successfully:
```bash
snapshot_dir=$(ls -d "$NASE_ROOT"/workspace-pre-restore-* 2>/dev/null | tail -1)
snapshot_count=$(find "$snapshot_dir" -type f 2>/dev/null | wc -l)
```
If `$snapshot_dir` does not exist or `$snapshot_count` is 0: abort with "ERROR: Pre-restore snapshot is empty or missing — aborting to prevent data loss. Check disk space and permissions, then retry." Do NOT proceed with deletion.

On a new machine, also suggest `/nase:init` to verify hooks and config.

### 6. Restore
Use the same archive tool that created the backup (check file extension: `.zip` → `unzip`, `.7z` → `7z x`):
```bash
rm -rf "$NASE_ROOT/workspace/"
mkdir -p "$NASE_ROOT/workspace"
# For .zip backups:
unzip -o "$ZIP_PATH" -d "$NASE_ROOT/workspace/"
# For .7z backups:
# 7z x "$ZIP_PATH" -o"$NASE_ROOT/workspace/"
```

### 7. Verify integrity
- Check that `workspace/context.md` exists (sentinel file)
- Count restored files: `find "$NASE_ROOT/workspace" -type f | wc -l`
- If sentinel missing, warn: "context.md not found — backup may be incomplete. Rollback snapshot at workspace-pre-restore-{timestamp}/"

### 8. Report
- Which backup was restored and from where
- Timestamp extracted from filename
- File count before and after
- Path of the pre-restore snapshot (for rollback)
- Reminder: the Stop hook will continue creating zip backups on future session ends
