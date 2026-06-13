#!/usr/bin/env bash
# kb-domain-resolve.sh — Resolve a repo name or domain key to its KB file path
#
# Usage: bash .claude/scripts/kb-domain-resolve.sh <repo-name-or-domain-key>
# Output (stdout): relative path to KB file, e.g. workspace/kb/projects/insights-monitoring.md
# Exit 0: found; Exit 1: not found (error on stderr)
#
# Examples:
#   bash .claude/scripts/kb-domain-resolve.sh "Insights-Monitoring"
#   bash .claude/scripts/kb-domain-resolve.sh "insights-monitoring"
#   bash .claude/scripts/kb-domain-resolve.sh "SRE"

set -euo pipefail

INPUT="${1:?Usage: kb-domain-resolve.sh <repo-name-or-domain-key>}"
DOMAIN_MAP="workspace/kb/.domain-map.md"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

log_kb_resolve() {
  local file_path="$1"
  command -v python3 >/dev/null 2>&1 || return 0
  python3 "$SCRIPT_DIR/kb-usage-log.py" record \
    --file "$file_path" \
    --access resolve \
    --source kb-domain-resolve >/dev/null 2>&1 || true
}

if [ ! -f "$DOMAIN_MAP" ]; then
  echo "ERROR: $DOMAIN_MAP not found — is this running from the nase workspace root?" >&2
  exit 1
fi

# Normalize: lowercase, collapse spaces/underscores to hyphens
DOMAIN_KEY=$(echo "$INPUT" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr ' ' '-')

# Match lines like: - insights-monitoring → workspace/kb/projects/insights-monitoring.md
# Also handles: - sre → workspace/kb/ops/sre.md
KB_PATH=$(grep -E "^[[:space:]]*-[[:space:]]+${DOMAIN_KEY}[[:space:]]+→" "$DOMAIN_MAP" \
  | sed -E 's/.*→[[:space:]]*//' \
  | awk '{print $1}' \
  || true)

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
