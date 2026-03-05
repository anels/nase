Restore `work/` from the configured backup location.

## Steps

### 1. Read backup config
- Look for the backup target in this order:
  1. `$WORKSPACE/.backup-target` (workspace root — preferred location)
  2. `work/.backup-target` (legacy location — backward compatible)
- If neither file exists, tell the user: no backup target configured — run `/onboard` first
- If the legacy location is used, note: "Consider moving `.backup-target` to the workspace root."

### 2. Inspect backup
- List the backup directory contents (top-level)
- Show last-modified timestamp of key files (e.g. `work/tasks/lessons.md`, `work/kb/`)
- Report backup size

### 3. Confirm with user
Before asking for confirmation, show files that exist in `work/` but NOT in the backup (these will be removed):
```bash
# Files in current work/ not in backup (will be removed by restore)
comm -23 <(cd "$WORKSPACE/work" && find . -type f | sort) <(cd "$TARGET" && find . -type f | sort)
```
If any such files exist, warn: "The following files exist locally but not in the backup and will be DELETED by the restore."

Then ask:
> Restore will overwrite your current `work/` with the backup at `{TARGET}`.
> Last backup: {timestamp of most recently modified file}
> Files to be deleted (not in backup): {N files listed above, or "none"}
> Proceed? (yes/no)

If user says no — abort with no changes.

### 3b. Create pre-restore snapshot (before any changes)
Before running the restore, create a local snapshot so the user can roll back if needed:
```bash
cp -rp "$WORKSPACE/work" "$WORKSPACE/work-pre-restore-$(date +%Y%m%dT%H%M%S)/"
```
Tell the user: "Snapshot created at `work-pre-restore-{timestamp}/`. Delete it once you've verified the restore."

### 4. Restore
Run (using bash-format paths):
```bash
rm -rf "$WORKSPACE/work/"
cp -rp "$TARGET/" "$WORKSPACE/work/"
```

### 5. Verify integrity
After the restore completes, verify it succeeded:
- Check that `{WORKSPACE}/work/context.md` exists (sentinel file — if missing, restore may be incomplete)
- Count restored files: `find "$WORKSPACE/work" -type f | wc -l`
- Report: "Restored N files from {TARGET}."
- If the sentinel file is missing, warn: "context.md not found in restored work/ — backup may be incomplete. Your pre-restore snapshot is at work-pre-restore-{timestamp}/ for rollback."

### 6. Confirm
Report:
- What was restored and from where
- Timestamp of the backup used
- File count before and after
- Path of the pre-restore snapshot (for rollback if needed)
- Reminder: the Stop hook will continue syncing on future session ends
