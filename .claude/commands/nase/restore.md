---
name: nase:restore
description: Restore workspace/ from a zip backup. Use after a machine migration, accidental deletion, when workspace/ is out of sync with the backup, or when asked to "sync workspace/", "recover workspace", "restore from backup", or "pull backup".
argument-hint: "[backup path]"
when_to_use: "Restore workspace/ from a zip backup. Use after a machine migration, accidental deletion, when workspace/ is out of sync with the backup, or when asked to \"sync workspace/\", \"recover workspace\", \"restore from backup\", or \"pull backup\"."
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

Resolve the selected backup to a canonical path before using it:
```bash
canonicalize_restore_path() {
  local path="$1"
  local py
  py=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
  if [ -n "$py" ]; then
    "$py" - "$path" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).expanduser().resolve(strict=False))
PY
    return
  fi
  realpath "$path" 2>/dev/null || readlink -f "$path" 2>/dev/null || printf '%s\n' "$path"
}

TARGET_REAL=$(canonicalize_restore_path "$TARGET")
case "$SELECTED_BACKUP" in
  /*|~*) SELECTED_PATH="$SELECTED_BACKUP" ;;
  *)     SELECTED_PATH="$TARGET/$SELECTED_BACKUP" ;;
esac
ZIP_PATH=$(canonicalize_restore_path "$SELECTED_PATH")
case "$ZIP_PATH" in
  "$TARGET_REAL"/*) ;;
  *) echo "ERROR: selected backup is outside backup-target" >&2; exit 1 ;;
esac
case "$(basename "$ZIP_PATH")" in
  nase-backup-*.zip|nase-backup-*.7z) ;;
  *) echo "ERROR: selected backup name must be nase-backup-*.zip or nase-backup-*.7z" >&2; exit 1 ;;
esac
```

### 4. Confirm with user
Before asking for confirmation, show files that exist in `workspace/` but NOT in the selected backup:
```bash
mkdir -p "$NASE_ROOT/workspace/tmp"
TMPFILE_BACKUP=$(mktemp "$NASE_ROOT/workspace/tmp/nase-backup-files-XXXXXX.txt")
TMPFILE_LOCAL=$(mktemp "$NASE_ROOT/workspace/tmp/nase-local-files-XXXXXX.txt")
# List files in the zip (try 7z first, fall back to zip listing tools)
if command -v 7z &>/dev/null; then
  7z l -slt "$ZIP_PATH" | grep "^Path = " | sed 's/^Path = //' | sed 's|^workspace/||' | sort > "$TMPFILE_BACKUP"
elif command -v unzip &>/dev/null; then
  unzip -Z1 "$ZIP_PATH" | sed 's|^workspace/||' | sort > "$TMPFILE_BACKUP"
elif command -v zipinfo &>/dev/null; then
  zipinfo -1 "$ZIP_PATH" | sed 's|^workspace/||' | sort > "$TMPFILE_BACKUP"
else
  echo "ERROR: need 7z, unzip, or zipinfo to inspect backup contents" >&2
  exit 1
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
Extract into a temporary directory first, verify it contains a plausible workspace payload, then replace `workspace/`. Current backups are created by running the archive tool from inside `workspace/`, so archive entries are usually `context.md`, `kb/...`, etc. Older/manual backups may include a top-level `workspace/` folder; handle both shapes.

Before extraction, validate the archive member list. Do not extract if any member is absolute, contains parent traversal (`..`), or uses a Windows drive / UNC path:
```bash
ARCHIVE_LIST=$(mktemp "$NASE_ROOT/workspace/tmp/nase-restore-list-XXXXXX.txt")
case "$ZIP_PATH" in
  *.7z)  7z l -slt "$ZIP_PATH" | sed -n 's/^Path = //p' > "$ARCHIVE_LIST" ;;
  *.zip)
    if command -v 7z &>/dev/null; then
      7z l -slt "$ZIP_PATH" | sed -n 's/^Path = //p' > "$ARCHIVE_LIST"
    elif command -v unzip &>/dev/null; then
      unzip -Z1 "$ZIP_PATH" > "$ARCHIVE_LIST"
    elif command -v zipinfo &>/dev/null; then
      zipinfo -1 "$ZIP_PATH" > "$ARCHIVE_LIST"
    else
      echo "ERROR: need 7z, unzip, or zipinfo to inspect backup contents" >&2
      exit 1
    fi
    ;;
  *)     echo "ERROR: unsupported backup extension: $ZIP_PATH" >&2 ; exit 1 ;;
esac

if grep -Eq '(^[\\/]|(^|[\\/])\.\.([\\/]|$)|^[A-Za-z]:[\\/]|^\\\\)' "$ARCHIVE_LIST"; then
  echo "ERROR: backup archive contains unsafe absolute or parent-traversal paths" >&2
  rm -f "$ARCHIVE_LIST"
  exit 1
fi
rm -f "$ARCHIVE_LIST"
```

```bash
RESTORE_TMP=$(mktemp -d "$NASE_ROOT/workspace-restore-XXXXXX")
trap 'rm -rf "$RESTORE_TMP"' EXIT
case "$ZIP_PATH" in
  *.7z)  7z x "$ZIP_PATH" -o"$RESTORE_TMP" ;;
  *.zip)
    if command -v 7z &>/dev/null; then
      7z x "$ZIP_PATH" -o"$RESTORE_TMP"
    elif command -v unzip &>/dev/null; then
      unzip -oq "$ZIP_PATH" -d "$RESTORE_TMP"
    else
      echo "ERROR: need 7z or unzip to extract zip backup" >&2
      exit 1
    fi
    ;;
  *)     echo "ERROR: unsupported backup extension: $ZIP_PATH" >&2 ; exit 1 ;;
esac

RESTORE_SRC="$RESTORE_TMP"
if [ -d "$RESTORE_TMP/workspace" ] && [ ! -f "$RESTORE_TMP/context.md" ]; then
  RESTORE_SRC="$RESTORE_TMP/workspace"
fi

if [ ! -f "$RESTORE_SRC/context.md" ] && [ ! -d "$RESTORE_SRC/kb" ]; then
  echo "ERROR: backup payload does not look like workspace/ (missing context.md and kb/)" >&2
  exit 1
fi
if find "$RESTORE_TMP" -type l -print -quit | grep -q .; then
  echo "ERROR: backup payload contains symlinks; refusing restore to avoid copying links outside workspace/" >&2
  exit 1
fi

rm -rf "$NASE_ROOT/workspace/"
mkdir -p "$NASE_ROOT/workspace"
cp -Rp "$RESTORE_SRC"/. "$NASE_ROOT/workspace/"
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
