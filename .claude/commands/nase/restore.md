---
name: nase:restore
description: Restore workspace/ from a zip backup. Use after a machine migration, accidental deletion, when workspace/ is out of sync with the backup, or when asked to "sync workspace/", "recover workspace", "restore from backup", or "pull backup".
---

Restores from timestamped zip backups. Creates a pre-restore snapshot before overwriting, so you can always roll back.

## Steps

### 1. Read backup config
- Resolve workspace root: `NASE_ROOT=$(git rev-parse --show-toplevel)`
- Read `backup-target` from `$NASE_ROOT/.local-paths`
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
mkdir -p "$NASE_ROOT/workspace/tmp"
TMPFILE_BACKUP="$NASE_ROOT/workspace/tmp/nase-backup-files-$$.txt"
TMPFILE_LOCAL="$NASE_ROOT/workspace/tmp/nase-local-files-$$.txt"
# List files in the zip (try 7z first, fall back to unzip)
if command -v 7z &>/dev/null; then
  7z l -slt "$ZIP_PATH" | grep "^Path = " | sed 's/^Path = //' | sed 's|^workspace/||' | sort > "$TMPFILE_BACKUP"
else
  unzip -l "$ZIP_PATH" | awk 'NR>3 && /\// {print $NF}' | sed 's|^workspace/||' | sort > "$TMPFILE_BACKUP"
fi
# List files in current workspace/ — strip leading ./ so paths are comparable
(cd "$NASE_ROOT/workspace" && find . -type f | sed 's|^\./||' | sort) > "$TMPFILE_LOCAL"
# Files that exist locally but not in the backup (will be deleted by restore)
comm -23 "$TMPFILE_LOCAL" "$TMPFILE_BACKUP"
# Cleanup temp files
rm -f "$TMPFILE_BACKUP" "$TMPFILE_LOCAL"
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
Before any changes, capture the timestamp once and create a local snapshot for rollback:
```bash
TS=$(date +%Y%m%dT%H%M%S)
SNAPSHOT_DIR="$NASE_ROOT/workspace-pre-restore-$TS"
cp -rp "$NASE_ROOT/workspace" "$SNAPSHOT_DIR/"
```
Tell the user: "Snapshot created at `workspace-pre-restore-$TS/`. Delete it once you've verified the restore."

Before proceeding, verify the snapshot was created successfully:
```bash
snapshot_count=$(find "$SNAPSHOT_DIR" -type f 2>/dev/null | wc -l)
```
If `$SNAPSHOT_DIR` does not exist or `$snapshot_count` is 0: abort with "ERROR: Pre-restore snapshot is empty or missing — aborting to prevent data loss. Check disk space and permissions, then retry." Do NOT proceed with deletion.

On a new machine, also suggest `/nase:init` to verify hooks and config.

### 6. Restore
Use the same archive tool that created the backup (check file extension: `.zip` → `unzip`, `.7z` → `7z x`):
```bash
rm -rf "$NASE_ROOT/workspace/"
# For .zip backups (extracts workspace/ from the archive into $NASE_ROOT):
unzip -o "$ZIP_PATH" -d "$NASE_ROOT/"
# For .7z backups:
# 7z x "$ZIP_PATH" -o"$NASE_ROOT/"
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
