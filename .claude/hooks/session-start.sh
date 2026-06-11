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

# Detect Python interpreter — used for archival and date fallback
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || command -v py 2>/dev/null || true)

# Buffer all diagnostic stdout so we can emit a single SessionStart JSON envelope
# at the end. The envelope carries additionalContext (the diagnostic lines) plus
# reloadSkills:true when the skill-sync block actually mutated stub files —
# Claude Code 2.1.152+ then picks up the new/removed /nase:workspace:* commands
# without a session restart.
BUFFER=$(mktemp)
trap 'rm -f "$BUFFER"' EXIT

synced=0
removed=0

extract_frontmatter_block() {
  local key="$1"
  local file="$2"
  awk -v key="$key" '
    function starts_new_key(line) {
      return line ~ /^[A-Za-z0-9_-]+:[[:space:]]*/
    }
    /^---$/ {
      if (NR == 1) { in_front = 1; next }
      if (in_front) { exit }
    }
    !in_front { next }
    capture && starts_new_key($0) { exit }
    capture {
      if ($0 ~ /^([[:space:]]|$)/) { print; next }
      exit
    }
    index($0, key ":") == 1 {
      print
      rest = $0
      sub(/^[^:]+:[[:space:]]*/, "", rest)
      if (rest == "") { capture = 1 } else { exit }
    }
  ' "$file"
}

extract_skill_description() {
  local file="$1"
  awk '
    function starts_new_key(line) {
      return line ~ /^[A-Za-z0-9_-]+:[[:space:]]*/
    }
    function is_block_scalar(value) {
      return value ~ /^[|>][+-]?$/
    }
    function strip_quotes(line) {
      if (line ~ /^".*"$/ || line ~ /^'\''.*'\''$/) {
        return substr(line, 2, length(line) - 2)
      }
      return line
    }
    /^---$/ {
      if (NR == 1) { in_front = 1; next }
      if (in_front) { in_front = 0; next }
    }
    in_front && capture_desc && starts_new_key($0) { exit }
    in_front && capture_desc {
      if ($0 ~ /^([[:space:]]|$)/) {
        sub(/^[[:space:]]*/, "")
        print
        next
      }
      exit
    }
    in_front && /^description:[[:space:]]*/ {
      desc = $0
      sub(/^description:[[:space:]]*/, "", desc)
      if (is_block_scalar(desc)) {
        capture_desc = 1
      } else {
        print strip_quotes(desc)
        exit
      }
      next
    }
    !in_front && NF {
      print
      exit
    }
  ' "$file"
}

yaml_double_quote_escape() {
  # Keep generated command frontmatter valid even when imported skill
  # descriptions contain Windows paths, quotes, or control characters.
  LC_ALL=C tr -d '\000-\037\177' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

compact_skill_description() {
  # Skill descriptions are loaded as command metadata. Keep enough trigger text
  # for discovery while preventing accidental paragraphs from becoming ambient context.
  awk -v max=240 '
    {
      line = line (line == "" ? "" : " ") $0
    }
    END {
      gsub(/[[:space:]]+/, " ", line)
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (length(line) > max) {
        line = substr(line, 1, max - 3) "..."
      }
      print line
    }
  '
}

{
  # Check last backup status: surface errors AND last successful run timestamp.
  STATUS_FILE="$NASE_ROOT/workspace/logs/.backup-status"
  if [ -f "$STATUS_FILE" ]; then
    LAST=$(tail -n1 "$STATUS_FILE")
    if echo "$LAST" | grep -qE "ERROR|WARNING"; then
      echo "[session-start] WARNING: last backup had an issue — $LAST"
      echo "[session-start] Check .local-paths config or run /restore to verify data"
    fi
    LAST_OK=$(awk '/\[OK\]/{last=$1} END{print last}' "$STATUS_FILE")
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
  if [ -f "$TRENDS" ]; then
    if [ -z "$PYTHON" ]; then
      echo "[session-start] WARNING: python3/python not found — tech digest archival skipped (tech-trends.md may grow unbounded)"
    else
    "$PYTHON" - "$TRENDS" "$NASE_ROOT/workspace/kb/general" << 'PYEOF' || true
import sys, re, os
from datetime import datetime, timedelta

trends_path = sys.argv[1]
kb_dir = sys.argv[2]
cutoff = datetime.now() - timedelta(days=30)

with open(trends_path, encoding='utf-8') as f:
    content = f.read()

sections = re.split(r'(?=\n## Tech Digest — \d{4}-\d{2}-\d{2})', content)
if not sections[0].strip().startswith('## Tech Digest'):
    preamble = sections.pop(0)
else:
    preamble = ''

keep, archive_by_year = [], {}
for section in sections:
    m = re.search(r'## Tech Digest — (\d{4}-\d{2}-\d{2})', section)
    if not m:
        keep.append(section); continue
    entry_date = datetime.strptime(m.group(1), '%Y-%m-%d')
    if entry_date < cutoff:
        year = m.group(1)[:4]
        archive_by_year.setdefault(year, []).append(section)
    else:
        keep.append(section)

if not archive_by_year:
    sys.exit(0)

with open(trends_path, 'w', encoding='utf-8') as f:
    f.write(preamble + ''.join(keep))

for year, entries in archive_by_year.items():
    archive_path = os.path.join(kb_dir, f'tech-trends-archive-{year}.md')
    if not os.path.exists(archive_path):
        with open(archive_path, 'w', encoding='utf-8') as f:
            f.write(f'# Tech Trends Archive — {year}\n')
    with open(archive_path, 'a', encoding='utf-8') as f:
        f.write(''.join(entries))

total = sum(len(v) for v in archive_by_year.values())
print(f"[session-start] archived {total} tech digest entries older than 30 days")
PYEOF
    fi
  fi

  # Item 6 — sync workspace/skills/ → .claude/commands/nase/workspace/
  SKILLS_DIR="$NASE_ROOT/workspace/skills"
  CMDS_DIR="$NASE_ROOT/.claude/commands/nase/workspace"
  if [ -d "$SKILLS_DIR" ]; then
    mkdir -p "$CMDS_DIR"
    for skill_file in "$SKILLS_DIR"/*.md; do
      [ -f "$skill_file" ] || continue
      name=$(basename "$skill_file" .md)
      cmd_file="$CMDS_DIR/$name.md"
      # Extract frontmatter fields. `description` prefers frontmatter, else first non-empty body line.
      # `allowed-tools` / `disallowed-tools` are forwarded verbatim from source frontmatter when set —
      # they let a source skill restrict the wrapper's tool pool (see /nase:skill-audit mitigation).
      desc=$(extract_skill_description "$skill_file")
      allowed_tools=$(extract_frontmatter_block "allowed-tools" "$skill_file")
      disallowed_tools=$(extract_frontmatter_block "disallowed-tools" "$skill_file")
      desc=$(printf '%s' "$desc" | compact_skill_description | yaml_double_quote_escape)
      next_cmd_file=$(mktemp "$CMDS_DIR/.${name}.XXXXXX")
      {
        printf '%s\n' '---'
        printf 'name: nase:workspace:%s\n' "$name"
        printf 'description: "%s"\n' "$desc"
        [ -n "$allowed_tools" ] && printf '%s\n' "$allowed_tools"
        [ -n "$disallowed_tools" ] && printf '%s\n' "$disallowed_tools"
        printf '%s\n\n' '---'
        printf 'Read `workspace/skills/%s.md` and follow every step exactly as written.\n\n' "$name"
        printf '$ARGUMENTS\n'
      } > "$next_cmd_file"
      chmod 0644 "$next_cmd_file"
      if [ ! -f "$cmd_file" ] || ! cmp -s "$next_cmd_file" "$cmd_file"; then
        mv "$next_cmd_file" "$cmd_file"
        synced=$((synced + 1))
      else
        rm -f "$next_cmd_file"
        chmod 0644 "$cmd_file" 2>/dev/null || true
      fi
    done
    # Clean up orphaned stubs whose source files no longer exist
    for cmd_file in "$CMDS_DIR"/*.md; do
      [ -f "$cmd_file" ] || continue
      name=$(basename "$cmd_file" .md)
      if [ ! -f "$SKILLS_DIR/$name.md" ]; then
        rm "$cmd_file"
        removed=$((removed + 1))
      fi
    done
    [ "$synced" -gt 0 ] && echo "[session-start] synced $synced skill(s) from workspace/skills/ → /nase:workspace:*"
    [ "$removed" -gt 0 ] && echo "[session-start] removed $removed orphaned skill stub(s) from .claude/commands/nase/workspace/"
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
if [ "$synced" -gt 0 ] || [ "$removed" -gt 0 ]; then
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
