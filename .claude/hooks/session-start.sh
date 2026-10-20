#!/usr/bin/env bash
set -euo pipefail

NASE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || true
if [ -z "$NASE_ROOT" ]; then
  jq -cn '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: "[session-start] ERROR: not in a git repo — cannot determine workspace"
    }
  }'
  exit 0
fi

DATE=$(date +%Y-%m-%d)
LOG="$NASE_ROOT/workspace/logs/$DATE.md"
mkdir -p "$NASE_ROOT/workspace/logs"
if [ ! -f "$LOG" ]; then
  printf "# Work Log — %s\n\n## Sessions\n\n" "$DATE" > "$LOG"
fi

# Detect Python interpreter — used for archival, skill sync, and date fallback
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || command -v py 2>/dev/null || true)

# Buffer all diagnostic stdout so we can emit a single SessionStart JSON envelope
# at the end. The envelope carries additionalContext (the diagnostic lines) plus
# reloadSkills:true when the skill-sync block actually mutated stub files —
# Claude Code 2.1.152+ then picks up the new/removed /nase:workspace:* commands
# without a session restart.
BUFFER=$(mktemp)
trap 'rm -f "$BUFFER"' EXIT

SKILL_SYNC_CHANGED=0

{
  # Check last backup status: surface errors AND last successful run timestamp.
  STATUS_FILE="$NASE_ROOT/workspace/logs/.backup-status"
  if [ -f "$STATUS_FILE" ]; then
    LAST=$(tail -n1 "$STATUS_FILE")
    if echo "$LAST" | grep -qE "ERROR|WARNING"; then
      echo "[session-start] WARNING: last backup had an issue — $LAST"
      echo "[session-start] Check .local-paths config or run /restore to verify data"
    fi
    # Only these stop-backup.sh lines mean an archive covers the workspace; the
    # throttle and retention-cleanup lines are [OK] too but prove nothing.
    # `synced` is the legacy wording still present in older status files.
    LAST_OK=$(awk '/\[OK\] (created |synced |workspace unchanged since last archive)/{last=$1} END{print last}' "$STATUS_FILE")
    if [ -n "$LAST_OK" ]; then
      echo "[session-start] last good backup: $LAST_OK"
    else
      echo "[session-start] NOTE: no successful backup recorded yet in workspace/logs/.backup-status"
    fi
  fi

  # Item 4 — backup target reachability check
  LOCAL_PATHS="$NASE_ROOT/.local-paths"
  if [ -f "$LOCAL_PATHS" ]; then
    TARGET=$(grep -E '^backup-target=' "$LOCAL_PATHS" 2>/dev/null | head -1 | cut -d= -f2-)
    if [ -n "$TARGET" ] && ! ls "$TARGET" >/dev/null 2>&1; then
      echo "[session-start] WARNING: backup target not reachable: $TARGET"
      echo "[session-start] Check that drive/network share is mounted, or update .local-paths"
    fi
  fi

  # Item 5 — auto-archive tech digest entries older than 30 days
  TRENDS="$NASE_ROOT/workspace/kb/general/tech-trends.md"
  TRENDS_JOURNAL="$NASE_ROOT/.nase-locks/workspace-archive-tech-trends.json"
  if { [ -f "$TRENDS" ] && [ ! -L "$TRENDS" ]; } \
    || [ -e "$TRENDS_JOURNAL" ] || [ -L "$TRENDS_JOURNAL" ]; then
    if [ -z "$PYTHON" ]; then
      echo "[session-start] WARNING: python3/python not found — tech digest archival skipped (tech-trends.md may grow unbounded)"
    else
    if ! "$PYTHON" "$NASE_ROOT/.claude/scripts/workspace-archive.py" tech-trends --root "$NASE_ROOT"; then
      echo "[session-start] WARNING: tech digest archival failed; source was preserved"
    fi
    fi
  fi

  # Item 6 - sync workspace/skills/ → .claude/commands/nase/workspace/.
  # Do not create hidden native mirrors: they duplicate command discovery and
  # allow the same operational workflow to be model-invoked twice.
  # Exit code 10 means a stub changed, so Claude Code reloads the commands.
  SKILLS_DIR="$NASE_ROOT/workspace/skills"
  if [ -d "$SKILLS_DIR" ]; then
    if [ -z "$PYTHON" ]; then
      echo "[session-start] WARNING: python3/python not found — workspace skill sync skipped"
    else
      SYNC_RC=0
      SYNC_OUTPUT=$("$PYTHON" "$NASE_ROOT/.claude/scripts/sync-workspace-skills.py" \
        --root "$NASE_ROOT" 2>&1) || SYNC_RC=$?
      if [ -n "$SYNC_OUTPUT" ]; then
        printf '%s\n' "$SYNC_OUTPUT"
      fi
      if [ "$SYNC_RC" -eq 10 ]; then
        SKILL_SYNC_CHANGED=1
      elif [ "$SYNC_RC" -ne 0 ]; then
        echo "[session-start] WARNING: workspace skill sync failed (exit $SYNC_RC)"
      fi
    fi
  fi

  # Item 8 — suggest /nase:reflect when today has commits
  if [ -f "$LOCAL_PATHS" ]; then
    REPOS=$(awk -F= '
      /^[[:space:]]*#/ || /^[[:space:]]*$/ || $1 == "backup-target" { next }
      { sub(/^[^=]*=/, ""); print }
    ' "$LOCAL_PATHS")
    HAS_COMMITS=0
    while IFS= read -r repo; do
      [ -z "$repo" ] && continue
      [ -d "$repo" ] || continue
      REPO_LOG=$(git -C "$repo" log --since="midnight" --oneline --branches 2>/dev/null || true)
      if [ -n "$REPO_LOG" ]; then
        HAS_COMMITS=1
        break
      fi
    done <<< "$REPOS"
    if [ "$HAS_COMMITS" -eq 1 ]; then
      echo "[session-start] You have commits today — consider running /nase:reflect to capture learnings"
    fi
  fi
} > "$BUFFER"

# Emit consolidated SessionStart JSON envelope. reloadSkills:true is set when
# the skill-sync block mutated stub files (see top-of-file comment).
RELOAD="false"
if [ "$SKILL_SYNC_CHANGED" -eq 1 ]; then
  RELOAD="true"
fi

CONTEXT=$(cat "$BUFFER")
if [ -z "$CONTEXT" ] && [ "$RELOAD" = "false" ]; then
  # Nothing to surface and no reload needed — stay silent.
  exit 0
fi

jq -cn --arg ctx "$CONTEXT" --argjson reload "$RELOAD" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx,
    reloadSkills: $reload
  }
}'
