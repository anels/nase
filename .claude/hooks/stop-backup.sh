#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# log_status — write timestamped entry to .backup-status and stdout (P1-BAK-03)
# ---------------------------------------------------------------------------
log_status() {
  local level="$1" msg="$2"
  local entry
  entry="$(date +%Y-%m-%dT%H:%M:%S) [$level] $msg"
  echo "[stop-backup] $entry"
  if [ -n "${WORKSPACE:-}" ]; then
    mkdir -p "$WORKSPACE/work/logs"
    echo "$entry" >> "$WORKSPACE/work/logs/.backup-status"
  fi
}

# ---------------------------------------------------------------------------
# Resolve workspace — no hardcoded fallback path (P1-ARCH-02)
# ---------------------------------------------------------------------------
WORKSPACE=$(git rev-parse --show-toplevel 2>/dev/null) || true
if [ -z "$WORKSPACE" ]; then
  echo "[stop-backup] ERROR: not in a git repo — cannot determine workspace" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Locate .backup-target: workspace root first, then work/ (P1-BAK-04)
# Keeping work/ fallback for backward compatibility with existing installs.
# ---------------------------------------------------------------------------
if [ -f "$WORKSPACE/.backup-target" ]; then
  CONFIG="$WORKSPACE/.backup-target"
elif [ -f "$WORKSPACE/work/.backup-target" ]; then
  CONFIG="$WORKSPACE/work/.backup-target"
  log_status "WARNING" ".backup-target found in work/ (legacy location) — move to workspace root to avoid bootstrap paradox"
else
  # No config — nothing to do; exit silently
  exit 0
fi

TARGET=$(tr -d '\r\n' < "$CONFIG")

# ---------------------------------------------------------------------------
# Validate target path (P1-BAK-01 — realpath-based, not length heuristic)
# ---------------------------------------------------------------------------
if [ -z "$TARGET" ]; then
  log_status "ERROR" "backup target path is empty in $CONFIG"
  exit 1
fi

REAL_TARGET=$(realpath -m "$TARGET" 2>/dev/null || readlink -f "$TARGET" 2>/dev/null || echo "$TARGET")
# Denylist for the most obvious dangerous roots
case "$REAL_TARGET" in
  / | "$HOME" | /c | /c/ | /Users | /home | /tmp | /var | /etc | /usr )
    log_status "ERROR" "unsafe target path: $TARGET (resolves to: $REAL_TARGET)"
    exit 1
    ;;
esac
# Depth guard: require at least 3 path components (e.g. /c/Users/me/backup, not /c/Users)
DEPTH=$(printf '%s' "$REAL_TARGET" | tr '/' '\n' | grep -c .)
if [ "$DEPTH" -lt 3 ]; then
  log_status "ERROR" "target path too shallow (depth $DEPTH) — refusing: $REAL_TARGET"
  exit 1
fi
# Ancestor guard: target must not be an ancestor of HOME or WORKSPACE
case "$HOME/" in "$REAL_TARGET/"*) log_status "ERROR" "target is ancestor of HOME: $REAL_TARGET"; exit 1 ;; esac
case "$WORKSPACE/" in "$REAL_TARGET/"*) log_status "ERROR" "target is ancestor of WORKSPACE: $REAL_TARGET"; exit 1 ;; esac

SRC="$WORKSPACE/work"

# ---------------------------------------------------------------------------
# Empty-source guard (P1-BAK-01): refuse if source appears empty.
# Require at least one of: work/context.md  OR  work/kb/
# This prevents a missing/empty work/ from wiping a good backup.
# ---------------------------------------------------------------------------
if [ ! -d "$SRC" ] || ( [ ! -f "$SRC/context.md" ] && [ ! -d "$SRC/kb" ] ); then
  log_status "ERROR" "source work/ is missing or empty (no context.md and no kb/) — aborting to protect backup"
  exit 1
fi

# ---------------------------------------------------------------------------
# Ensure target directory exists
# ---------------------------------------------------------------------------
mkdir -p "$TARGET" || { log_status "ERROR" "cannot create target directory: $TARGET"; exit 1; }

# ---------------------------------------------------------------------------
# Concurrency lock — prevent two simultaneous Stop hooks from corrupting the backup
# mkdir is atomic on all filesystems (including Windows NTFS via Git Bash)
# ---------------------------------------------------------------------------
LOCK_DIR="$TARGET/.backup-lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log_status "WARNING" "another backup is already in progress — skipping this run"
  exit 0
fi
trap 'rm -rf "$LOCK_DIR"' EXIT

# ---------------------------------------------------------------------------
# Auto commit summary — append to today's daily log
# ---------------------------------------------------------------------------
COMMIT_DATE=$(date +%Y-%m-%d)
COMMIT_LOG="$WORKSPACE/work/logs/$COMMIT_DATE.md"
if [ -f "$WORKSPACE/work/context.md" ]; then
  REPOS=$(grep -oiE '`[A-Za-z]:[^`]+`|`/[^`]+`' "$WORKSPACE/work/context.md" 2>/dev/null | tr -d '`' || true)
  COMMITS=""
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    case "$repo" in //*|http*|ftp*) continue ;; esac  # skip UNC/remote paths
    [ -d "$repo" ] || continue                         # skip non-existent paths
    REPO_COMMITS=$(git -C "$repo" log --since="midnight" --oneline --branches 2>/dev/null || true)
    if [ -n "$REPO_COMMITS" ]; then
      REPO_NAME=$(basename "$repo")
      COMMITS+="**[$REPO_NAME]**"$'\n'"$REPO_COMMITS"$'\n'
    fi
  done <<< "$REPOS"
  if [ -n "$COMMITS" ]; then
    # Dedup: compute fingerprint from sorted commit SHAs; skip if unchanged
    FINGERPRINT=$(echo "$COMMITS" | grep -oE '^[a-f0-9]+' | sort | tr '\n' ',')
    FP_FILE="$WORKSPACE/work/logs/.last-commit-fingerprint"
    LAST_FP=""
    if [ -f "$FP_FILE" ]; then
      LAST_FP=$(cat "$FP_FILE")
    fi
    if [ "$COMMIT_DATE:$FINGERPRINT" = "$LAST_FP" ]; then
      echo "[stop-backup] commit summary unchanged — skipping duplicate append"
    else
      printf "\n\n## Commits\n%s\n" "$COMMITS" >> "$COMMIT_LOG"
      echo "$COMMIT_DATE:$FINGERPRINT" > "$FP_FILE"
      echo "[stop-backup] appended commit summary to $COMMIT_LOG"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Remind if today's log has no session notes
# ---------------------------------------------------------------------------
if [ -f "$COMMIT_LOG" ]; then
  SESSION_CONTENT=$(awk '/^## Sessions/{found=1; next} /^## /{found=0} found && /[^[:space:]]/{print; exit}' "$COMMIT_LOG")
  if [ -z "$SESSION_CONTENT" ]; then
    echo "[stop-backup] WARNING: no session notes in today's log — update work/logs/$COMMIT_DATE.md before closing"
  fi
else
  echo "[stop-backup] WARNING: no daily log for today — consider running /nase:wrap-up"
fi

# ---------------------------------------------------------------------------
# Require 7z for zip backup
# ---------------------------------------------------------------------------
if ! command -v 7z &>/dev/null; then
  log_status "ERROR" "7z not found — install with 'scoop install 7zip' for zip backups"
  exit 1
fi

# ---------------------------------------------------------------------------
# One-time migration: clean up old flat-copy backup files (pre-zip era)
# Detects the old format by checking for context.md or kb/ directly in target
# ---------------------------------------------------------------------------
if [ -f "$TARGET/context.md" ] && [ -d "$TARGET/kb" ]; then
  log_status "OK" "migrating: removing old flat-copy backup (replaced by zip archives)"
  find "$TARGET" -mindepth 1 -maxdepth 1 ! -name '.backup-lock' ! -name 'nase-backup-*.zip' -exec rm -rf {} \; 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Create timestamped zip backup
# ---------------------------------------------------------------------------
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ZIP_NAME="nase-backup-${TIMESTAMP}.zip"
ZIP_PATH="$TARGET/$ZIP_NAME"

(cd "$SRC" && 7z a -tzip -mx=1 -bso0 -bsp0 "$ZIP_PATH" .)
rc=$?
if [ "$rc" -ne 0 ]; then
  rm -f "$ZIP_PATH"
  log_status "ERROR" "7z failed (exit $rc) — backup not created"
  exit 1
fi

ZIP_SIZE=$(du -sh "$ZIP_PATH" | cut -f1)
log_status "OK" "created $ZIP_NAME ($ZIP_SIZE)"

# ---------------------------------------------------------------------------
# Retention cleanup — read policy from work/config.md
# Format: backup_retention: count:100  or  backup_retention: days:7
# Default: count:100
# ---------------------------------------------------------------------------
RETENTION="count:100"
if [ -f "$WORKSPACE/work/config.md" ]; then
  CFG_LINE=$(sed -n 's/^backup_retention:[[:space:]]*//p' "$WORKSPACE/work/config.md" 2>/dev/null | tr -d ' ' || true)
  if [ -n "$CFG_LINE" ]; then
    RETENTION="$CFG_LINE"
  fi
fi
RETENTION_TYPE="${RETENTION%%:*}"
RETENTION_VALUE="${RETENTION##*:}"

# Validate retention value is numeric
if ! [[ "$RETENTION_VALUE" =~ ^[0-9]+$ ]]; then
  log_status "WARNING" "invalid retention value '$RETENTION_VALUE' — using default count:100"
  RETENTION_TYPE="count"
  RETENTION_VALUE="100"
fi

# Collect backup zips sorted ascending by name (= chronological order)
mapfile -t BACKUPS < <(ls -1 "$TARGET"/nase-backup-*.zip 2>/dev/null | sort)
DELETED=0

if [ "$RETENTION_TYPE" = "count" ] && [ "${#BACKUPS[@]}" -gt "$RETENTION_VALUE" ]; then
  TO_DELETE=$(( ${#BACKUPS[@]} - RETENTION_VALUE ))
  for ((i=0; i<TO_DELETE; i++)); do
    rm -f "${BACKUPS[$i]}"
    ((DELETED++))
  done
elif [ "$RETENTION_TYPE" = "days" ]; then
  CUTOFF=$(date -d "-${RETENTION_VALUE} days" +%Y%m%d 2>/dev/null || true)
  if [ -n "$CUTOFF" ]; then
    for backup in "${BACKUPS[@]}"; do
      BDATE=$(basename "$backup" | sed -n 's/nase-backup-\([0-9]\{8\}\)-.*/\1/p')
      if [ -n "$BDATE" ] && [ "$BDATE" -lt "$CUTOFF" ]; then
        rm -f "$backup"
        ((DELETED++))
      fi
    done
  fi
fi

if [ "$DELETED" -gt 0 ]; then
  log_status "OK" "retention cleanup: removed $DELETED old backup(s) (policy: $RETENTION)"
fi
