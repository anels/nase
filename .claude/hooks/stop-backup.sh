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
  if [ -n "${NASE_ROOT:-}" ]; then
    mkdir -p "$NASE_ROOT/workspace/logs"
    echo "$entry" >> "$NASE_ROOT/workspace/logs/.backup-status"
  fi
}

canonicalize_path() {
  local path="$1"
  local py
  local resolved
  py=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
  if [ -n "$py" ]; then
    "$py" - "$path" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).expanduser().resolve(strict=False))
PY
    return
  fi
  if resolved=$(realpath "$path" 2>/dev/null); then
    printf '%s\n' "$resolved"
    return
  fi
  if resolved=$(readlink -f "$path" 2>/dev/null); then
    printf '%s\n' "$resolved"
    return
  fi
  printf '%s\n' "$path"
  return 1
}

# ---------------------------------------------------------------------------
# Resolve workspace — no hardcoded fallback path (P1-ARCH-02)
# ---------------------------------------------------------------------------
NASE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || true
if [ -z "$NASE_ROOT" ]; then
  echo "[stop-backup] ERROR: not in a git repo — cannot determine workspace" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Read backup target from .local-paths
# ---------------------------------------------------------------------------
LOCAL_PATHS="$NASE_ROOT/.local-paths"
if [ -f "$LOCAL_PATHS" ]; then
  TARGET=$(grep -E '^backup-target=' "$LOCAL_PATHS" 2>/dev/null | head -1 | cut -d= -f2-)
else
  # No config — nothing to do; exit silently
  exit 0
fi

# ---------------------------------------------------------------------------
# Validate target path (P1-BAK-01 — realpath-based, not length heuristic)
# ---------------------------------------------------------------------------
if [ -z "$TARGET" ]; then
  log_status "ERROR" "backup target path is empty in $LOCAL_PATHS"
  exit 1
fi

if ! REAL_TARGET=$(canonicalize_path "$TARGET"); then
  log_status "WARNING" "could not canonicalize target path; validating raw path: $TARGET"
fi
# Denylist for the most obvious dangerous roots
case "$REAL_TARGET" in
  / | "$HOME" | /Users | /home | /tmp | /private/tmp | /var | /etc | /usr )
    log_status "ERROR" "unsafe target path: $TARGET (resolves to: $REAL_TARGET)"
    exit 1
    ;;
esac
# Depth guard: require at least 3 path components (e.g. /c/Users/me/backup, not /c/Users)
DEPTH=$(printf '%s' "$REAL_TARGET" | tr '/' '\n' | grep -c .)
if [ "$DEPTH" -lt 3 ]; then
  log_status "ERROR" "target path too shallow (depth $DEPTH) — refusing: $TARGET (resolves to: $REAL_TARGET)"
  exit 1
fi
# Ancestor guard: target must not be an ancestor of HOME or NASE_ROOT
case "$HOME/" in "$REAL_TARGET/"*) log_status "ERROR" "target is ancestor of HOME: $REAL_TARGET"; exit 1 ;; esac
case "$NASE_ROOT/" in "$REAL_TARGET/"*) log_status "ERROR" "target is ancestor of NASE_ROOT: $REAL_TARGET"; exit 1 ;; esac

SRC="$NASE_ROOT/workspace"
if ! REAL_SRC=$(canonicalize_path "$SRC"); then
  REAL_SRC="$SRC"
fi
case "$REAL_TARGET" in
  "$REAL_SRC"|"$REAL_SRC"/*)
    log_status "ERROR" "backup target must be outside workspace/: $TARGET (resolves to: $REAL_TARGET)"
    exit 1
    ;;
esac

TARGET="$REAL_TARGET"

# ---------------------------------------------------------------------------
# Empty-source guard (P1-BAK-01): refuse if source appears empty.
# Require at least one of: workspace/context.md  OR  workspace/kb/
# This prevents a missing/empty workspace/ from wiping a good backup.
# ---------------------------------------------------------------------------
if [ ! -d "$SRC" ] || ( [ ! -f "$SRC/context.md" ] && [ ! -d "$SRC/kb" ] ); then
  log_status "ERROR" "source workspace/ is missing or empty (no context.md and no kb/) — aborting to protect backup"
  exit 1
fi

SENSITIVE_SCAN="$NASE_ROOT/tests/check-local-sensitive-artifacts.sh"
if [ ! -f "$SENSITIVE_SCAN" ]; then
  log_status "ERROR" "workspace security preflight is missing: tests/check-local-sensitive-artifacts.sh"
  exit 1
fi

# ---------------------------------------------------------------------------
# Ensure target directory exists
# ---------------------------------------------------------------------------
mkdir -p "$TARGET" || { log_status "ERROR" "cannot create target directory: $TARGET"; exit 1; }

# ---------------------------------------------------------------------------
# Concurrency lock — prevent two simultaneous Stop hooks from corrupting the backup
# mkdir is atomic on all filesystems (including Windows NTFS via Git Bash)
# PID file inside lock dir lets us detect stale locks from crashed/killed runs
# ---------------------------------------------------------------------------
LOCK_DIR="$TARGET/.backup-lock"
LOCK_PID="$LOCK_DIR/pid"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  # Check if the owning process is still alive
  stale=1
  if [ -f "$LOCK_PID" ]; then
    owner_pid=$(cat "$LOCK_PID" 2>/dev/null)
    if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
      stale=0
    fi
  fi
  if [ "$stale" -eq 1 ]; then
    log_status "WARNING" "removing stale backup lock (pid=$(cat "$LOCK_PID" 2>/dev/null || echo unknown))"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || { log_status "ERROR" "cannot acquire backup lock after stale cleanup"; exit 1; }
  else
    log_status "WARNING" "another backup is already in progress — skipping this run"
    exit 0
  fi
fi
echo $$ > "$LOCK_PID"
SNAPSHOT_DIR=""
cleanup_backup() {
  rm -rf "$LOCK_DIR"
  if [ -n "$SNAPSHOT_DIR" ] && [ -d "$SNAPSHOT_DIR" ]; then
    rm -rf "$SNAPSHOT_DIR"
  fi
}
trap cleanup_backup EXIT

# ---------------------------------------------------------------------------
# Auto commit summary — append to today's daily log
# ---------------------------------------------------------------------------
COMMIT_DATE=$(date +%Y-%m-%d)
COMMIT_LOG="$NASE_ROOT/workspace/logs/$COMMIT_DATE.md"
REPOS=$(grep -v '^[[:space:]]*#' "$LOCAL_PATHS" | grep -v '^[[:space:]]*$' | grep -v '^backup-target=' | cut -d= -f2- || true)
COMMITS=""
COMMIT_HASHES=""
if [ -n "$REPOS" ]; then
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
    # `%H %s` gives full hash + subject — single git call serves both
    # display (truncated to short hash on output) and dedup fingerprint.
    REPO_LOG=$(git -C "$repo" log --since="midnight" --format='%H %s' --branches 2>/dev/null || true)
    if [ -n "$REPO_LOG" ]; then
      if ! printf '%s\n' "$REPO_LOG" | bash "$SENSITIVE_SCAN" --stdin >/dev/null 2>&1; then
        log_status "WARNING" "skipped a commit summary containing a credential-like value"
        continue
      fi
      REPO_NAME=$(basename "$repo")
      REPO_DISPLAY=$(printf '%s\n' "$REPO_LOG" | awk '{ printf "%s %s\n", substr($1,1,7), substr($0, index($0,$2)) }')
      REPO_HASHES=$(printf '%s\n' "$REPO_LOG" | awk '{print $1}')
      COMMITS+="**[$REPO_NAME]**"$'\n'"$REPO_DISPLAY"$'\n'
      COMMIT_HASHES+="$REPO_HASHES"$'\n'
    fi
  done <<< "$REPOS"
  if [ -n "$COMMITS" ]; then
    # Dedup: compute fingerprint from sorted commit SHAs; skip if unchanged
    FINGERPRINT=$(printf '%s' "$COMMIT_HASHES" | grep -v '^$' | sort | tr '\n' ',')
    FP_FILE="$NASE_ROOT/workspace/logs/.last-commit-fingerprint"
    LAST_FP=""
    if [ -f "$FP_FILE" ]; then
      LAST_FP=$(cat "$FP_FILE")
    fi
    if [ "$COMMIT_DATE:$FINGERPRINT" = "$LAST_FP" ]; then
      echo "[stop-backup] commit summary unchanged — skipping"
    else
      # Daily logs are append-only; keep prior commit snapshots intact.
      mkdir -p "$(dirname "$COMMIT_LOG")"
      printf "\n## Commits\n%s\n" "$COMMITS" >> "$COMMIT_LOG"
      echo "$COMMIT_DATE:$FINGERPRINT" > "$FP_FILE"
      echo "[stop-backup] appended commit summary in $COMMIT_LOG"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Remind if today's log has no session notes
# ---------------------------------------------------------------------------
if [ -f "$COMMIT_LOG" ]; then
  SESSION_CONTENT=$(awk '/^## Sessions/{found=1; next} /^## /{found=0} found && /[^[:space:]]/{print; exit}' "$COMMIT_LOG")
  if [ -z "$SESSION_CONTENT" ]; then
    echo "[stop-backup] WARNING: no session notes in today's log — update workspace/logs/$COMMIT_DATE.md before closing"
  fi
else
  echo "[stop-backup] WARNING: no daily log for today — consider running /nase:wrap-up"
fi

# This is the final live-tree gate, after every hook-owned workspace mutation.
if ! SCAN_OUTPUT=$(NASE_SENSITIVE_SCAN_ROOT="$NASE_ROOT" bash "$SENSITIVE_SCAN" --workspace 2>&1); then
  printf '%s\n' "$SCAN_OUTPUT" >&2
  log_status "ERROR" "workspace security preflight failed; backup not created"
  exit 1
fi

# ---------------------------------------------------------------------------
# Create and validate a local zip snapshot before external publication.
# ---------------------------------------------------------------------------
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ZIP_NAME="nase-backup-${TIMESTAMP}.zip"
ZIP_PATH="$TARGET/$ZIP_NAME"
SNAPSHOT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nase-backup.XXXXXX") || {
  log_status "ERROR" "cannot create local backup snapshot directory"
  exit 1
}
LOCAL_ZIP_PATH="$SNAPSHOT_DIR/$ZIP_NAME"
SNAPSHOT_WORKSPACE="$SNAPSHOT_DIR/workspace"
SOURCE_MANIFEST="$SNAPSHOT_DIR/source-manifest.json"
POST_ARCHIVE_MANIFEST="$SNAPSHOT_DIR/post-archive-manifest.json"
mkdir "$SNAPSHOT_WORKSPACE"
if ! cp -a "$SRC/." "$SNAPSHOT_WORKSPACE/"; then
  log_status "ERROR" "workspace could not be copied into the private snapshot"
  exit 1
fi
if ! SCAN_OUTPUT=$(NASE_SENSITIVE_SCAN_ROOT="$SNAPSHOT_DIR" bash "$SENSITIVE_SCAN" --workspace 2>&1); then
  printf '%s\n' "$SCAN_OUTPUT" >&2
  log_status "ERROR" "private workspace snapshot failed security validation"
  exit 1
fi
if ! bash "$SENSITIVE_SCAN" --manifest "$SNAPSHOT_WORKSPACE" "$SOURCE_MANIFEST"; then
  log_status "ERROR" "private workspace snapshot manifest could not be created"
  exit 1
fi
manifest_sha() {
  python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys

print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
}

SOURCE_MANIFEST_SHA=$(manifest_sha "$SOURCE_MANIFEST") || {
  log_status "ERROR" "private workspace snapshot manifest could not be bound"
  exit 1
}

# ---------------------------------------------------------------------------
# Content dedup — skip publishing an archive identical to the last published one.
#
# The manifest already binds every archived member's path, mode, type, and
# sha256, so its own hash is an exact fingerprint of what the zip would contain.
# The zip bytes are not: they embed per-run timestamps, so two archives of an
# unchanged workspace differ while their content does not. Compare manifests.
#
# The fingerprint lives at the repository root rather than inside `workspace/`
# on purpose: a state file under the archived tree would change the very
# manifest it is meant to fingerprint, so dedup could never match.
#
# `logs/.backup-status` is excluded for the same reason. This hook appends to it
# on every run, so leaving it in would make the fingerprint differ every time
# and dedup would never fire. It is excluded from the *fingerprint* only — the
# manifest that binds the published archive still covers it.
#
# Requires a surviving archive — after a long idle period retention can expire
# every copy, and "unchanged since the last one" must not mean "no backup".
# ---------------------------------------------------------------------------
content_fingerprint() {
  python3 - "$1" <<'PY'
import hashlib
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
manifest.pop("logs/.backup-status", None)
payload = json.dumps(manifest, ensure_ascii=False, sort_keys=True).encode("utf-8")
print(hashlib.sha256(payload).hexdigest())
PY
}

BACKUP_STATE_FILE="$NASE_ROOT/.nase-backup-state"
CONTENT_FINGERPRINT=$(content_fingerprint "$SOURCE_MANIFEST") || {
  log_status "ERROR" "private workspace snapshot content fingerprint could not be computed"
  exit 1
}
LAST_FINGERPRINT=""
if [ -f "$BACKUP_STATE_FILE" ]; then
  LAST_FINGERPRINT=$(sed -n 's/^last-content-fingerprint=//p' "$BACKUP_STATE_FILE" | head -1)
fi
# `ls` exits non-zero when the glob matches nothing, and `set -o pipefail` would
# turn a legitimately empty target into a hook failure.
EXISTING_ARCHIVES=$( { ls -1 "$TARGET"/nase-backup-*.zip 2>/dev/null || true; } | wc -l | tr -d ' ')
if [ -n "$LAST_FINGERPRINT" ] \
  && [ "$LAST_FINGERPRINT" = "$CONTENT_FINGERPRINT" ] \
  && [ "$EXISTING_ARCHIVES" -gt 0 ]; then
  log_status "OK" "workspace unchanged since last archive — skipped ($EXISTING_ARCHIVES retained)"
  exit 0
fi

rc=0
if command -v 7z &>/dev/null; then
  (cd "$SNAPSHOT_WORKSPACE" && 7z a -tzip -mx=1 -snl -bso0 -bsp0 "$LOCAL_ZIP_PATH" . -x!tmp) || rc=$?
elif command -v zip &>/dev/null; then
  (cd "$SNAPSHOT_WORKSPACE" && zip -qry "$LOCAL_ZIP_PATH" . -x "tmp/*") || rc=$?
else
  log_status "ERROR" "neither 7z nor zip found — install one for backups"
  exit 1
fi
if [ "$rc" -ne 0 ]; then
  log_status "ERROR" "archive tool failed (exit $rc) — backup not created"
  exit 1
fi
CURRENT_MANIFEST_SHA=$(manifest_sha "$SOURCE_MANIFEST") || CURRENT_MANIFEST_SHA=""
if [ "$CURRENT_MANIFEST_SHA" != "$SOURCE_MANIFEST_SHA" ]; then
  log_status "ERROR" "private workspace snapshot authority changed during archive creation"
  exit 1
fi
if ! bash "$SENSITIVE_SCAN" --manifest "$SNAPSHOT_WORKSPACE" "$POST_ARCHIVE_MANIFEST" \
  || ! cmp -s "$SOURCE_MANIFEST" "$POST_ARCHIVE_MANIFEST"; then
  log_status "ERROR" "private workspace snapshot changed during archive creation"
  exit 1
fi
if ! SCAN_OUTPUT=$(bash "$SENSITIVE_SCAN" --archive "$LOCAL_ZIP_PATH" "$SOURCE_MANIFEST" 2>&1); then
  printf '%s\n' "$SCAN_OUTPUT" >&2
  log_status "ERROR" "local backup snapshot failed security validation; backup not published"
  exit 1
fi
if ! python3 - "$LOCAL_ZIP_PATH" "$ZIP_PATH" <<'PY'
import os
import shutil
import sys

source_path, destination_path = sys.argv[1:]
source_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
source_fd = os.open(source_path, source_flags)
destination_fd = None
try:
    destination_fd = os.open(
        destination_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        0o600,
    )
    with os.fdopen(source_fd, "rb", closefd=False) as source, os.fdopen(
        destination_fd, "wb", closefd=False
    ) as destination:
        shutil.copyfileobj(source, destination, 1024 * 1024)
        destination.flush()
        os.fsync(destination.fileno())
except Exception:
    if destination_fd is not None:
        try:
            os.unlink(destination_path)
        except OSError:
            pass
    raise SystemExit(1)
finally:
    os.close(source_fd)
    if destination_fd is not None:
        os.close(destination_fd)
PY
then
  log_status "ERROR" "validated backup snapshot could not be published"
  exit 1
fi

ZIP_SIZE=$(du -sh "$ZIP_PATH" | cut -f1)
log_status "OK" "created $ZIP_NAME ($ZIP_SIZE)"

# Record the fingerprint only after the archive is published, so a failed run
# never suppresses the next attempt.
printf 'last-content-fingerprint=%s\n' "$CONTENT_FINGERPRINT" > "$BACKUP_STATE_FILE.tmp" \
  && mv -f "$BACKUP_STATE_FILE.tmp" "$BACKUP_STATE_FILE" \
  || log_status "WARNING" "could not record backup fingerprint — next run will re-archive"

# ---------------------------------------------------------------------------
# Retention cleanup — read policy from workspace/config.md
# Format: backup_retention: count:100, days:7, or both (`days:30,count:200`).
# Default: count:100
#
# Both clauses apply when both are given: age prunes first, then the count cap
# bounds what a single busy day can leave behind. A time-only window places no
# bound on how many archives one day contributes, which is how this target
# reached four figures.
# ---------------------------------------------------------------------------
RETENTION="count:100"
if [ -f "$NASE_ROOT/workspace/config.md" ]; then
  CFG_LINE=$(sed -n 's/^backup_retention:[[:space:]]*//p' "$NASE_ROOT/workspace/config.md" 2>/dev/null | tr -d ' ' || true)
  if [ -n "$CFG_LINE" ]; then
    RETENTION="$CFG_LINE"
  fi
fi

RETENTION_COUNT=""
RETENTION_DAYS=""
RETENTION_INVALID=""
OLD_IFS="$IFS"
IFS=','
for clause in $RETENTION; do
  [ -n "$clause" ] || continue
  clause_type="${clause%%:*}"
  clause_value="${clause##*:}"
  if ! [[ "$clause_value" =~ ^[0-9]+$ ]]; then
    RETENTION_INVALID="$clause"
    continue
  fi
  case "$clause_type" in
    count) RETENTION_COUNT="$clause_value" ;;
    days) RETENTION_DAYS="$clause_value" ;;
    *) RETENTION_INVALID="$clause" ;;
  esac
done
IFS="$OLD_IFS"

if [ -n "$RETENTION_INVALID" ]; then
  log_status "WARNING" "invalid retention clause '$RETENTION_INVALID' — ignored"
fi
if [ -z "$RETENTION_COUNT" ] && [ -z "$RETENTION_DAYS" ]; then
  log_status "WARNING" "no usable retention clause in '$RETENTION' — using default count:100"
  RETENTION_COUNT="100"
fi

# Collect backup zips sorted ascending by name (= chronological order)
BACKUPS=()
while IFS= read -r line; do BACKUPS+=("$line"); done < <(ls -1 "$TARGET"/nase-backup-*.zip 2>/dev/null | sort)
DELETED=0

if [ -n "$RETENTION_DAYS" ]; then
  CUTOFF=$(date -d "-${RETENTION_DAYS} days" +%Y%m%d 2>/dev/null \
    || date -v-"${RETENTION_DAYS}"d +%Y%m%d 2>/dev/null \
    || true)
  if [ -z "$CUTOFF" ]; then
    log_status "WARNING" "neither GNU nor BSD date supports computing cutoff — age retention skipped"
  else
    RETAINED=()
    for backup in ${BACKUPS[@]+"${BACKUPS[@]}"}; do
      BDATE=$(basename "$backup" | sed -n 's/nase-backup-\([0-9]\{8\}\)-.*/\1/p')
      if [ -n "$BDATE" ] && [ "$BDATE" -lt "$CUTOFF" ]; then
        rm -f "$backup"
        ((++DELETED))
      else
        RETAINED+=("$backup")
      fi
    done
    # bash 3.2 treats "${EMPTY[@]}" as unbound under `set -u`; the +expansion
    # form is the portable way to copy a possibly-empty array.
    BACKUPS=(${RETAINED[@]+"${RETAINED[@]}"})
  fi
fi

if [ -n "$RETENTION_COUNT" ] && [ "${#BACKUPS[@]}" -gt "$RETENTION_COUNT" ]; then
  TO_DELETE=$(( ${#BACKUPS[@]} - RETENTION_COUNT ))
  for ((i=0; i<TO_DELETE; i++)); do
    rm -f "${BACKUPS[$i]}"
    ((++DELETED))
  done
fi

if [ "$DELETED" -gt 0 ]; then
  log_status "OK" "retention cleanup: removed $DELETED old backup(s) (policy: $RETENTION)"
fi
