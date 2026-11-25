#!/usr/bin/env bash
# Sourced before `set -e`: on bash 3.2 a syntax error in a sourced file would otherwise
# end the shell with status 2 instead of reaching the `||` fallback below.
HOOK_DIR=${BASH_SOURCE[0]%/*}
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.
# shellcheck source=../lib/hook-common.sh
{ [ -r "$HOOK_DIR/../lib/hook-common.sh" ] && . "$HOOK_DIR/../lib/hook-common.sh"; } 2>/dev/null \
  || { echo "[stop-backup] ERROR: hook-common.sh unavailable - backup skipped" >&2; exit 0; }

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
  # Expand `~` against the shell's HOME: native Windows Python expands it against
  # USERPROFILE, which is a different directory whenever HOME is overridden.
  # shellcheck disable=SC2088 # the quoted tilde is the literal text to match, not an expansion
  case "$path" in
    "~") path="$HOME" ;;
    "~/"*) path="$HOME/${path#"~/"}" ;;
  esac
  py=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
  if [ -n "$py" ]; then
    "$py" - "$path" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).expanduser().resolve(strict=False).as_posix())
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
NASE_ROOT=$(nase_root) || NASE_ROOT=""
if [ -z "$NASE_ROOT" ]; then
  echo "[stop-backup] ERROR: not in a git repo — cannot determine workspace" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Read backup target from .local-paths
# ---------------------------------------------------------------------------
LOCAL_PATHS="$NASE_ROOT/.local-paths"
if [ -f "$LOCAL_PATHS" ]; then
  TARGET=$(grep -E '^backup-target=' "$LOCAL_PATHS" 2>/dev/null | head -1 | cut -d= -f2- || true)
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
REAL_HOME=$(canonicalize_path "$HOME") || REAL_HOME="$HOME"
REAL_ROOT=$(canonicalize_path "$NASE_ROOT") || REAL_ROOT="$NASE_ROOT"
SRC="$NASE_ROOT/workspace"
if ! REAL_SRC=$(canonicalize_path "$SRC"); then
  REAL_SRC="$SRC"
fi

# Drive-letter paths compare case-insensitively; POSIX paths compare as written.
path_key() {
  case "$1" in
    [A-Za-z]:*) printf '%s' "$1" | tr '[:upper:]' '[:lower:]' ;;
    *) printf '%s' "$1" ;;
  esac
}
# True when $1 equals $2 or is a directory above it.
path_contains() {
  local outer inner
  outer=$(path_key "$1")
  inner=$(path_key "$2")
  outer=${outer%/}
  case "$inner/" in "$outer/"*) return 0 ;; esac
  return 1
}
TARGET_KEY=$(path_key "$REAL_TARGET")

# Denylist for the most obvious dangerous roots
case "$TARGET_KEY" in
  / | "$HOME" | "$REAL_HOME" | "$(path_key "$REAL_HOME")" | /Users | /home | /tmp | /private/tmp | /var | /etc | /usr \
  | [a-z]: | [a-z]:/ | [a-z]:/users | [a-z]:/windows | [a-z]:/program\ files | [a-z]:/program\ files\ \(x86\) | [a-z]:/programdata )
    log_status "ERROR" "unsafe target path: $TARGET (resolves to: $REAL_TARGET)"
    exit 1
    ;;
esac
# Depth guard: require at least 3 path components (e.g. /c/Users/me/backup, not /c/Users).
# A drive letter is a root, not a component, so D:/nase-backup is one level under its root
# and is allowed; the denylist above covers the system directories at that level.
DEPTH_PATH="$REAL_TARGET"
MIN_DEPTH=3
case "$TARGET_KEY" in
  [a-z]:*) DEPTH_PATH="${TARGET_KEY#[a-z]:}"; MIN_DEPTH=1 ;;
esac
DEPTH=$(printf '%s' "$DEPTH_PATH" | tr '/' '\n' | grep -c . || true)
if [ "$DEPTH" -lt "$MIN_DEPTH" ]; then
  log_status "ERROR" "target path too shallow (depth $DEPTH) — refusing: $TARGET (resolves to: $REAL_TARGET)"
  exit 1
fi
# Ancestor guard: target must not be an ancestor of HOME or NASE_ROOT
for guarded_home in "$HOME" "$REAL_HOME"; do
  if path_contains "$REAL_TARGET" "$guarded_home"; then
    log_status "ERROR" "target is ancestor of HOME: $REAL_TARGET"
    exit 1
  fi
done
for guarded_root in "$NASE_ROOT" "$REAL_ROOT"; do
  if path_contains "$REAL_TARGET" "$guarded_root"; then
    log_status "ERROR" "target is ancestor of NASE_ROOT: $REAL_TARGET"
    exit 1
  fi
done

if path_contains "$REAL_SRC" "$REAL_TARGET"; then
  log_status "ERROR" "backup target must be outside workspace/: $TARGET (resolves to: $REAL_TARGET)"
  exit 1
fi

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
# Ownership is an exclusive file create, not mkdir: uutils mkdir before 0.11.0 (Ubuntu 26.04
# ships it) can report success to two runs racing on one path.
# PID file inside lock dir lets us detect stale locks from crashed/killed runs
# ---------------------------------------------------------------------------
LOCK_DIR="$TARGET/.backup-lock"
LOCK_PID="$LOCK_DIR/pid"
RECLAIM_FILE="$TARGET/.backup-lock.reclaim"
# Writes this run's pid to $1 only if $1 does not exist: bash opens it with O_EXCL under noclobber.
claim_file() {
  (set -C; echo $$ > "$1") 2>/dev/null
}
owner_pid=""
# Returns 0 when the lock is stale. Sets owner_pid to the recorded pid, if any.
lock_is_stale() {
  owner_pid=""
  if [ -f "$LOCK_PID" ]; then
    owner_pid=$(cat "$LOCK_PID" 2>/dev/null || true)
  fi
  if [ -n "$owner_pid" ]; then
    if kill -0 "$owner_pid" 2>/dev/null; then
      return 1
    fi
    # A clean exit removes the lock before the process dies, so only a pid that is
    # still recorded now belongs to an owner that died holding the lock.
    [ "$(cat "$LOCK_PID" 2>/dev/null || true)" = "$owner_pid" ]
    return
  fi
  # The owner creates the lock dir, then the pid file, then writes the pid, so a fresh
  # dir without a pid belongs to a run that is still starting. A missing dir has
  # nothing to reclaim.
  # Try GNU stat first, because GNU `stat -f` prints filesystem info before it fails on `%m`.
  local lock_mtime
  lock_mtime=$(stat -c %Y "$LOCK_DIR" 2>/dev/null || stat -f %m "$LOCK_DIR" 2>/dev/null) || return 1
  [ $(( $(date +%s) - lock_mtime )) -ge 60 ]
}
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if lock_is_stale; then
    # Only one run may delete a stale lock. Without this mutex, two runs that both saw
    # the lock as stale can each delete the fresh lock the other just created.
    if ! claim_file "$RECLAIM_FILE"; then
      # A reclaimer that crashed leaves the mutex behind. Clear an old one for the next run.
      # A mutex that is already gone has no age, and the next one may belong to a live run.
      if reclaim_mtime=$(stat -c %Y "$RECLAIM_FILE" 2>/dev/null || stat -f %m "$RECLAIM_FILE" 2>/dev/null) \
        && [ $(( $(date +%s) - reclaim_mtime )) -ge 60 ]; then
        rm -rf "$RECLAIM_FILE"
      fi
      log_status "WARNING" "another backup is already in progress — skipping this run"
      exit 0
    fi
    # Re-check under the mutex: another run may have replaced the lock since the first check.
    if ! lock_is_stale; then
      rm -f "$RECLAIM_FILE"
      log_status "WARNING" "another backup is already in progress — skipping this run"
      exit 0
    fi
    log_status "WARNING" "removing stale backup lock (pid=${owner_pid:-unknown})"
    rm -rf "$LOCK_DIR"
    # A fresh run can take the lock between the rm and this mkdir. It then owns the lock.
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
      rm -f "$RECLAIM_FILE"
      log_status "WARNING" "another backup is already in progress — skipping this run"
      exit 0
    fi
    rm -f "$RECLAIM_FILE"
  else
    log_status "WARNING" "another backup is already in progress — skipping this run"
    exit 0
  fi
fi
# The run that creates the pid file owns the lock, whatever mkdir reported.
if ! claim_file "$LOCK_PID"; then
  log_status "WARNING" "another backup is already in progress — skipping this run"
  exit 0
fi
SNAPSHOT_DIR=""
cleanup_backup() {
  # Only remove a lock this run still owns; a reclaimer may have replaced it.
  if [ "$(cat "$LOCK_PID" 2>/dev/null || true)" = "$$" ]; then
    rm -rf "$LOCK_DIR"
  fi
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
REPOS=$(nase_local_repo_paths "$LOCAL_PATHS")
COMMITS=""
COMMIT_HASHES=""
if [ -n "$REPOS" ]; then
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    if [ ! -d "$repo" ]; then
      log_status "WARNING" "configured repo path not found, skipping commit summary: $repo"
      continue
    fi
    # `%H %s` gives full hash + subject — single git call serves both
    # display (truncated to short hash on output) and dedup fingerprint.
    REPO_LOG=$(git -C "$repo" log --since="midnight" --format='%H %s' --branches 2>/dev/null || true)
    if [ -n "$REPO_LOG" ]; then
      if ! printf '%s\n' "$REPO_LOG" | bash "$SENSITIVE_SCAN" --stdin >/dev/null 2>&1; then
        log_status "WARNING" "skipped a commit summary containing a credential-like value"
        continue
      fi
      REPO_NAME=$(basename "$repo")
      REPO_DISPLAY=$(printf '%s\n' "$REPO_LOG" | awk '{ h = substr($1,1,7); sub(/^[^ ]+ ?/, ""); printf "%s %s\n", h, $0 }')
      REPO_HASHES=$(printf '%s\n' "$REPO_LOG" | awk '{print $1}')
      COMMITS+="**[$REPO_NAME]**"$'\n'"$REPO_DISPLAY"$'\n'
      COMMIT_HASHES+="$REPO_HASHES"$'\n'
    fi
  done <<< "$REPOS"
  if [ -n "$COMMITS" ]; then
    # Dedup: compute fingerprint from sorted commit SHAs; the append script skips if unchanged
    FINGERPRINT=$(printf '%s' "$COMMIT_HASHES" | grep -v '^$' | sort | tr '\n' ',')
    # Daily logs are append-only; the script locks so two stopping sessions cannot interleave.
    APPEND_PY=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
    APPEND_RESULT=""
    if [ -n "$APPEND_PY" ]; then
      APPEND_RESULT=$(printf '%s\n%s' "$FINGERPRINT" "$COMMITS" | "$APPEND_PY" \
        "$NASE_ROOT/.claude/scripts/commit-log-append.py" --root "$NASE_ROOT" --date "$COMMIT_DATE") || APPEND_RESULT=""
    fi
    case "$APPEND_RESULT" in
      appended) echo "[stop-backup] appended commit summary in $COMMIT_LOG" ;;
      unchanged) echo "[stop-backup] commit summary unchanged — skipping" ;;
      *) log_status "WARNING" "commit summary append failed: $COMMIT_LOG" ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# Minimum-interval throttle
# Format: backup_min_interval_minutes: N in workspace/config.md. Default: 30.
# 0 disables the throttle.
#
# `Stop` fires once per assistant turn, not once per session, so an active
# session reaches here every few minutes. Content dedup does not bound that:
# a working session genuinely changes logs/, efforts/, and kb/ on most turns,
# so the fingerprint legitimately differs and every turn publishes a full
# archive of the whole workspace.
#
# Checked before the snapshot so a throttled run skips the entire cost: the
# live-tree scan, the workspace copy, the manifest, and the archive. The cheap
# commit summary above still runs.
#
# Anchored on the newest surviving archive's filename timestamp rather than on
# `.nase-backup-state`: if retention has expired or storage has lost every
# copy, there is no backup for this run to be "too soon" after, and the
# throttle must never be the reason a target has no archive at all.
# ---------------------------------------------------------------------------
archive_age_seconds() {
  python3 - "$1" <<'PY'
import datetime
import re
import sys

match = re.fullmatch(r"nase-backup-(\d{8})-(\d{6})\.zip", sys.argv[1])
if not match:
    raise SystemExit(1)
try:
    stamp = datetime.datetime.strptime(match.group(1) + match.group(2), "%Y%m%d%H%M%S")
except ValueError:
    raise SystemExit(1)
print(int((datetime.datetime.now() - stamp).total_seconds()))
PY
}

MIN_INTERVAL_MINUTES="30"
if [ -f "$NASE_ROOT/workspace/config.md" ]; then
  CFG_INTERVAL=$(sed -n 's/^backup_min_interval_minutes:[[:space:]]*//p' "$NASE_ROOT/workspace/config.md" 2>/dev/null | tr -d ' ' || true)
  if [ -n "$CFG_INTERVAL" ]; then
    if [[ "$CFG_INTERVAL" =~ ^[0-9]+$ ]]; then
      MIN_INTERVAL_MINUTES="$CFG_INTERVAL"
    else
      log_status "WARNING" "invalid backup_min_interval_minutes '$CFG_INTERVAL' - using default $MIN_INTERVAL_MINUTES"
    fi
  fi
fi

if [ "$MIN_INTERVAL_MINUTES" -gt 0 ]; then
  # Glob rather than parse `ls`. These names are ASCII digits and hyphens, so the
  # shell's own ordering is chronological and the last match is the newest. The
  # `-e` guard is what handles no-match, where the pattern comes back literal.
  NEWEST_ARCHIVE=""
  for archive_candidate in "$TARGET"/nase-backup-*.zip; do
    [ -e "$archive_candidate" ] || continue
    NEWEST_ARCHIVE="$archive_candidate"
  done
  if [ -n "$NEWEST_ARCHIVE" ] && [ -f "$NEWEST_ARCHIVE" ] && [ ! -L "$NEWEST_ARCHIVE" ]; then
    # A negative age means the newest name carries a future timestamp, so the
    # elapsed interval is unknown. Back up rather than throttle on bad input.
    if NEWEST_AGE=$(archive_age_seconds "$(basename "$NEWEST_ARCHIVE")") \
      && [ "$NEWEST_AGE" -ge 0 ] \
      && [ "$NEWEST_AGE" -lt $(( MIN_INTERVAL_MINUTES * 60 )) ]; then
      log_status "OK" "last archive is ${NEWEST_AGE}s old - throttled (backup_min_interval_minutes: $MIN_INTERVAL_MINUTES)"
      exit 0
    fi
  fi
fi

# This is the final live-tree gate, after every hook-owned workspace mutation.
# Credential-like hits are advisory: workspace/ is git-ignored, so they cannot reach
# GitHub. Unsafe links, unreadable files, and incomplete coverage still fail closed.
ADVISORY_WARNING=0
note_advisory_scan() {
  case "$1" in
    *"WARN: credential-like"*)
      if [ "$ADVISORY_WARNING" -eq 0 ]; then
        ADVISORY_WARNING=1
        log_status "WARNING" "credential-like values in workspace were backed up; list them with: bash tests/check-local-sensitive-artifacts.sh --workspace --advisory"
      fi
      ;;
  esac
}
if ! SCAN_OUTPUT=$(NASE_SENSITIVE_SCAN_ROOT="$NASE_ROOT" bash "$SENSITIVE_SCAN" --workspace --advisory 2>&1); then
  printf '%s\n' "$SCAN_OUTPUT" >&2
  log_status "ERROR" "workspace security preflight failed; backup not created"
  exit 1
fi
# Any of the three scans can be the first to see a hit: a write can land between
# the live scan and the snapshot copy. Report the warning once, from whichever
# stage caught it, so the snapshot gate cannot downgrade a hit silently.
note_advisory_scan "$SCAN_OUTPUT"

# ---------------------------------------------------------------------------
# Create and validate a local zip snapshot before external publication.
# ---------------------------------------------------------------------------
# A hard kill (the hook timeout) skips the EXIT trap and leaves a full workspace copy in
# the temp directory. Remove only directories with this hook's mktemp name and layout
# that are more than a day old; a live run is minutes old.
while IFS= read -r -d '' stale_snapshot; do
  [ -d "$stale_snapshot/workspace" ] || continue
  rm -rf "$stale_snapshot" || log_status "WARNING" "could not remove stale backup snapshot $stale_snapshot"
done < <(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'nase-backup.??????' -mmin +1440 -print0 2>/dev/null || true)
SNAPSHOT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nase-backup.XXXXXX") || {
  log_status "ERROR" "cannot create local backup snapshot directory"
  exit 1
}
SNAPSHOT_WORKSPACE="$SNAPSHOT_DIR/workspace"
SOURCE_MANIFEST="$SNAPSHOT_DIR/source-manifest.json"
POST_ARCHIVE_MANIFEST="$SNAPSHOT_DIR/post-archive-manifest.json"
mkdir "$SNAPSHOT_WORKSPACE"
# Top-level `tmp/` never enters the archive, the manifest, or the scans, so it is not
# copied either. Only a real directory is skipped, matching what the scans skip.
copy_failed=0
entries_seen=0
# `$SRC/.` makes find descend when `workspace` is itself a symlink, as `cp -a "$SRC/."` did.
while IFS= read -r -d '' entry; do
  if [ "${entry##*/}" = "tmp" ] && [ -d "$entry" ] && [ ! -L "$entry" ]; then
    continue
  fi
  entries_seen=$((entries_seen + 1))
  cp -a "$entry" "$SNAPSHOT_WORKSPACE/" || copy_failed=1
done < <(find "$SRC/." -mindepth 1 -maxdepth 1 -print0)
if [ "$copy_failed" -ne 0 ]; then
  log_status "ERROR" "workspace could not be copied into the private snapshot"
  exit 1
fi
if [ "$entries_seen" -eq 0 ]; then
  log_status "ERROR" "workspace snapshot is empty; refusing to publish an empty archive"
  exit 1
fi
if ! SCAN_OUTPUT=$(NASE_SENSITIVE_SCAN_ROOT="$SNAPSHOT_DIR" bash "$SENSITIVE_SCAN" --workspace --advisory 2>&1); then
  printf '%s\n' "$SCAN_OUTPUT" >&2
  log_status "ERROR" "private workspace snapshot failed security validation"
  exit 1
fi
note_advisory_scan "$SCAN_OUTPUT"
if ! bash "$SENSITIVE_SCAN" --manifest "$SNAPSHOT_WORKSPACE" "$SOURCE_MANIFEST"; then
  log_status "ERROR" "private workspace snapshot manifest could not be created"
  exit 1
fi
manifest_sha() {
  python3 - "$1" <<'PY'
import hashlib
import os
import stat
import sys

digest = hashlib.sha256()
source_fd = os.open(
    sys.argv[1], os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
)
try:
    if not stat.S_ISREG(os.fstat(source_fd).st_mode):
        raise OSError("hash input is not a regular file")
    with os.fdopen(source_fd, "rb", closefd=False) as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
finally:
    os.close(source_fd)
print(digest.hexdigest())
PY
}

SOURCE_MANIFEST_SHA=$(manifest_sha "$SOURCE_MANIFEST") || {
  log_status "ERROR" "private workspace snapshot manifest could not be bound"
  exit 1
}

# ---------------------------------------------------------------------------
# Retention policy - parsed before dedup so an expired archive cannot suppress
# the replacement that the policy requires.
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
  if ! [[ "$clause_value" =~ ^[0-9]+$ ]] || [ "$clause_value" -eq 0 ]; then
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
  log_status "WARNING" "invalid retention clause '$RETENTION_INVALID' - ignored"
fi
if [ -z "$RETENTION_COUNT" ] && [ -z "$RETENTION_DAYS" ]; then
  log_status "WARNING" "no usable retention clause in '$RETENTION' - using default count:100"
  RETENTION_COUNT="100"
fi

RETENTION_CUTOFF=""
if [ -n "$RETENTION_DAYS" ]; then
  RETENTION_CUTOFF=$(date -d "-${RETENTION_DAYS} days" +%Y%m%d 2>/dev/null \
    || date -v-"${RETENTION_DAYS}"d +%Y%m%d 2>/dev/null \
    || true)
fi

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
LAST_ARCHIVE=""
LAST_ARCHIVE_SHA=""
if [ -f "$BACKUP_STATE_FILE" ]; then
  LAST_FINGERPRINT=$(sed -n 's/^last-content-fingerprint=//p' "$BACKUP_STATE_FILE" | head -1)
  LAST_ARCHIVE=$(sed -n 's/^last-archive=//p' "$BACKUP_STATE_FILE" | head -1)
  LAST_ARCHIVE_SHA=$(sed -n 's/^last-archive-sha256=//p' "$BACKUP_STATE_FILE" | head -1)
fi
ARCHIVE_SURVIVES_RETENTION=0
if [[ "$LAST_ARCHIVE" =~ ^nase-backup-[0-9]{8}-[0-9]{6}\.zip$ ]] \
  && [[ "$LAST_ARCHIVE_SHA" =~ ^[0-9a-f]{64}$ ]] \
  && [ -f "$TARGET/$LAST_ARCHIVE" ] \
  && [ ! -L "$TARGET/$LAST_ARCHIVE" ] \
  && [ "$(manifest_sha "$TARGET/$LAST_ARCHIVE" 2>/dev/null || true)" = "$LAST_ARCHIVE_SHA" ]; then
  ARCHIVE_SURVIVES_RETENTION=1
  if [ -n "$RETENTION_DAYS" ]; then
    LAST_ARCHIVE_DATE=$(printf '%s\n' "$LAST_ARCHIVE" | sed -n 's/nase-backup-\([0-9]\{8\}\)-.*/\1/p')
    if [ -z "$RETENTION_CUTOFF" ] \
      || [ -z "$LAST_ARCHIVE_DATE" ] \
      || [ "$LAST_ARCHIVE_DATE" -lt "$RETENTION_CUTOFF" ]; then
      ARCHIVE_SURVIVES_RETENTION=0
    fi
  fi
fi
if [ -n "$LAST_FINGERPRINT" ] \
  && [ "$LAST_FINGERPRINT" = "$CONTENT_FINGERPRINT" ] \
  && [ "$ARCHIVE_SURVIVES_RETENTION" -eq 1 ]; then
  log_status "OK" "workspace unchanged since last archive - skipped ($LAST_ARCHIVE retained)"
  exit 0
fi

ARCHIVE_NAME_ATTEMPTS=0
while :; do
  TIMESTAMP=$(date +%Y%m%d-%H%M%S)
  ZIP_NAME="nase-backup-${TIMESTAMP}.zip"
  ZIP_PATH="$TARGET/$ZIP_NAME"
  if [ ! -e "$ZIP_PATH" ] && [ ! -L "$ZIP_PATH" ]; then
    break
  fi
  ((++ARCHIVE_NAME_ATTEMPTS))
  if [ "$ARCHIVE_NAME_ATTEMPTS" -ge 3 ]; then
    log_status "ERROR" "could not allocate a collision-free backup name"
    exit 1
  fi
  sleep 1
done
LOCAL_ZIP_PATH="$SNAPSHOT_DIR/$ZIP_NAME"

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
if ! SCAN_OUTPUT=$(bash "$SENSITIVE_SCAN" --archive "$LOCAL_ZIP_PATH" "$SOURCE_MANIFEST" --advisory 2>&1); then
  printf '%s\n' "$SCAN_OUTPUT" >&2
  log_status "ERROR" "local backup snapshot failed security validation; backup not published"
  exit 1
fi
note_advisory_scan "$SCAN_OUTPUT"
# A killed publish leaves a hidden `.partial` file. We hold the lock, so no live run
# owns one; anything older than an hour is debris. Swept here, not at startup, so a
# throttled run that publishes nothing skips the `find`.
find "$TARGET" -maxdepth 1 -type f -name '.nase-backup-*.partial' -mmin +60 -delete 2>/dev/null || true

# Publish by writing a hidden `.partial` sibling and renaming it into place. A kill or
# timeout mid-copy then leaves only a name that no `nase-backup-*` glob (throttle,
# retention, /nase:restore) matches, never a truncated archive that looks newest.
if ! python3 - "$LOCAL_ZIP_PATH" "$ZIP_PATH" <<'PY'
import os
import secrets
import shutil
import sys

source_path, destination_path = sys.argv[1:]
target_dir = os.path.dirname(destination_path)
partial_path = os.path.join(target_dir, ".nase-backup-%s.partial" % secrets.token_hex(6))
# O_BINARY: a text-mode descriptor on Windows rewrites newline bytes inside the archive.
binary = getattr(os, "O_BINARY", 0)
source_flags = os.O_RDONLY | binary | getattr(os, "O_NOFOLLOW", 0)
source_fd = os.open(source_path, source_flags)
partial_fd = None
try:
    partial_fd = os.open(
        partial_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | binary, 0o600
    )
    with os.fdopen(source_fd, "rb", closefd=False) as source, os.fdopen(
        partial_fd, "wb", closefd=False
    ) as partial:
        shutil.copyfileobj(source, partial, 1024 * 1024)
        partial.flush()
        os.fsync(partial.fileno())
    # Windows refuses to rename a file that still has an open handle.
    os.close(partial_fd)
    partial_fd = None
    if os.path.lexists(destination_path):
        raise FileExistsError(destination_path)
    os.rename(partial_path, destination_path)
except Exception:
    try:
        os.unlink(partial_path)
    except OSError:
        pass
    raise SystemExit(1)
finally:
    os.close(source_fd)
    if partial_fd is not None:
        os.close(partial_fd)
try:
    dir_fd = os.open(target_dir, os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)
except OSError:
    pass
PY
then
  log_status "ERROR" "validated backup snapshot could not be published"
  exit 1
fi

ZIP_SIZE=$(du -sh "$ZIP_PATH" | cut -f1)
log_status "OK" "created $ZIP_NAME ($ZIP_SIZE)"

# Record the fingerprint only after the archive is published, so a failed run
# never suppresses the next attempt.
PUBLISHED_ARCHIVE_SHA=$(manifest_sha "$ZIP_PATH") || PUBLISHED_ARCHIVE_SHA=""
if [ -n "$PUBLISHED_ARCHIVE_SHA" ]; then
  {
    printf 'last-content-fingerprint=%s\n' "$CONTENT_FINGERPRINT"
    printf 'last-archive=%s\n' "$ZIP_NAME"
    printf 'last-archive-sha256=%s\n' "$PUBLISHED_ARCHIVE_SHA"
  } > "$BACKUP_STATE_FILE.tmp" \
    && mv -f "$BACKUP_STATE_FILE.tmp" "$BACKUP_STATE_FILE" \
    || log_status "WARNING" "could not record backup fingerprint - next run will re-archive"
else
  log_status "WARNING" "could not verify published backup fingerprint - next run will re-archive"
fi

# ---------------------------------------------------------------------------
# Retention cleanup
# Format: backup_retention: count:100, days:7, or both (`days:30,count:200`).
# Default: count:100
#
# Both clauses apply when both are given: age prunes first, then the count cap
# bounds what a single busy day can leave behind. A time-only window places no
# bound on how many archives one day contributes, which is how this target
# reached four figures.
# ---------------------------------------------------------------------------
# Collect backup zips ascending by name (= chronological order). Globbing instead of
# parsing `ls` matters more here than at the throttle read: this list feeds `rm -f`.
BACKUPS=()
for archive_candidate in "$TARGET"/nase-backup-*.zip; do
  # `-e` alone would drop a dangling symlink, which the previous `ls -1` listed and
  # `rm -f` removed. Retention deleting less than before is a behavior change, so the
  # `-L` arm keeps the set identical; the no-match case still falls through.
  [ -e "$archive_candidate" ] || [ -L "$archive_candidate" ] || continue
  # Retention owns only the names this hook generates. A hand-named archive sorts after
  # every timestamp and would otherwise take a slot from, or outlive, the real newest one.
  case "${archive_candidate##*/}" in
    nase-backup-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].zip) ;;
    *) continue ;;
  esac
  BACKUPS+=("$archive_candidate")
done
DELETED=0

if [ -n "$RETENTION_DAYS" ]; then
  if [ -z "$RETENTION_CUTOFF" ]; then
    log_status "WARNING" "neither GNU nor BSD date supports computing cutoff — age retention skipped"
  else
    RETAINED=()
    for backup in ${BACKUPS[@]+"${BACKUPS[@]}"}; do
      BDATE=$(basename "$backup" | sed -n 's/nase-backup-\([0-9]\{8\}\)-.*/\1/p')
      if [ -n "$BDATE" ] && [ "$BDATE" -lt "$RETENTION_CUTOFF" ] && [ "${backup##*/}" != "${ZIP_NAME:-}" ]; then
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
    # A clock step backwards can sort the archive just published among the oldest.
    [ "${BACKUPS[$i]##*/}" != "${ZIP_NAME:-}" ] || continue
    rm -f "${BACKUPS[$i]}"
    ((++DELETED))
  done
fi

if [ "$DELETED" -gt 0 ]; then
  log_status "OK" "retention cleanup: removed $DELETED old backup(s) (policy: $RETENTION)"
fi
