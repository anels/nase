#!/usr/bin/env bash
# kb-domain-resolve.sh — Resolve a repo name or domain key to its KB file path
#
# Usage: bash .claude/scripts/kb-domain-resolve.sh <repo-name-or-domain-key>
# Output (stdout): relative path to KB file, e.g. workspace/kb/projects/platform-monitoring.md
# Exit 0: found; Exit 1: not found (error on stderr)
#
# Examples:
#   bash .claude/scripts/kb-domain-resolve.sh "Platform-Monitoring"
#   bash .claude/scripts/kb-domain-resolve.sh "platform-monitoring"
#   bash .claude/scripts/kb-domain-resolve.sh "SRE"

set -euo pipefail

INPUT="${1:?Usage: kb-domain-resolve.sh <repo-name-or-domain-key>}"
DOMAIN_MAP="workspace/kb/.domain-map.md"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

log_kb_resolve() {
  local file_path="$1"
  command -v python3 >/dev/null 2>&1 || return 0
  local args=(record --file "$file_path" --access resolve --source kb-domain-resolve)
  # No --session: kb-usage-log.py reads the session id from the environment
  # itself (CLAUDE_CODE_SESSION_ID first), so the chain lives in one place.
  python3 "$SCRIPT_DIR/kb-usage-log.py" "${args[@]}" >/dev/null 2>&1 || true
}

if [ ! -f "$DOMAIN_MAP" ]; then
  echo "ERROR: $DOMAIN_MAP not found — is this running from the nase workspace root?" >&2
  exit 1
fi

# Normalize: lowercase, collapse spaces/underscores to hyphens
DOMAIN_KEY=$(echo "$INPUT" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr ' ' '-')

# Match rows like: - platform-monitoring → workspace/kb/projects/platform-monitoring.md
# Same row shape as ROW_RE in nase_domain_map.py. The key is compared as a literal
# string (a regex built from the input would let "." or "|" match other rows), rows
# inside <!-- ... --> blocks are ignored, and the first matching row wins. The key
# travels in the environment because `awk -v` would expand backslash escapes in it.
KB_PATH=$(KEY="$DOMAIN_KEY" awk '
  BEGIN { key = ENVIRON["KEY"]; in_comment = 0 }
  {
    line = $0
    sub(/\r$/, "", line)
    out = ""
    while (line != "") {
      if (in_comment) {
        i = index(line, "-->")
        if (i == 0) { line = ""; break }
        line = substr(line, i + 3)
        in_comment = 0
      } else {
        i = index(line, "<!--")
        if (i == 0) { out = out line; line = ""; break }
        out = out substr(line, 1, i - 1)
        line = substr(line, i + 4)
        in_comment = 1
      }
    }
    if (out !~ /^[ \t]*-[ \t]+/) next
    sub(/^[ \t]*-[ \t]+/, "", out)
    i = index(out, "→")
    if (i == 0) next
    k = substr(out, 1, i - 1)
    sub(/[ \t]+$/, "", k)
    rest = substr(out, i + length("→"))
    if (rest !~ /^[ \t]+[^ \t[]/) next
    sub(/^[ \t]+/, "", rest)
    sub(/[ \t[].*$/, "", rest)
    if (k == key) { print rest; exit }
  }
' "$DOMAIN_MAP" || true)

if [ -z "$KB_PATH" ]; then
  echo "ERROR: No KB entry for domain '${DOMAIN_KEY}' in .domain-map.md" >&2
  echo "Hint: run /nase:onboard to register this repo, or check the domain map at ${DOMAIN_MAP}" >&2
  exit 1
fi

# Prepend workspace/ prefix if missing
if [[ "$KB_PATH" != workspace/* ]]; then
  KB_PATH="workspace/${KB_PATH}"
fi

if [ ! -f "$KB_PATH" ]; then
  echo "ERROR: Domain '${DOMAIN_KEY}' maps to '${KB_PATH}' but file does not exist" >&2
  echo "Hint: run /nase:onboard to regenerate the KB file" >&2
  exit 1
fi

log_kb_resolve "$KB_PATH"
echo "$KB_PATH"
