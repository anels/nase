#!/usr/bin/env bash
# List terminal effort docs in one directory for a given month, with PR + Jira refs
# found in each doc. Completion date is approximated by file mtime, which is when
# the effort was last edited / closed - good enough to bucket by month, and the
# report's own "effort-closed != PR-merged" reconciliation corrects the rest.
#
# Usage: month-efforts.sh <YYYY-MM> [efforts-dir]
#   month-efforts.sh 2026-06
#   month-efforts.sh 2026-06 workspace/efforts/done
#   month-efforts.sh 2026-06 workspace/efforts/archive/2026
#
# Terminal `tracking_only: true` efforts close into archive/<YYYY>/ rather than done/
# (.claude/docs/effort-lifecycle.md -> Terminal Destination), so a month sweep that
# reads only done/ misses them. The emitted frontmatter carries tracking_only so the
# caller can exclude another owner's delivery from its counts.
#
# Output: one block per matching effort - slug, mtime, frontmatter (status/repo/jira),
# and every PR URL/number + Jira key referenced in the body. Feed this to the
# extraction subagent so it reads only the in-scope docs.
set -euo pipefail

MONTH="${1:?usage: month-efforts.sh <YYYY-MM> [efforts-dir]}"
EFFORTS_DIR="${2:-workspace/efforts/done}"

if [[ ! -d "$EFFORTS_DIR" ]]; then
  echo "no such dir: $EFFORTS_DIR" >&2; exit 1
fi

# stat mtime dialect differs (BSD/macOS vs GNU); detect once.
if stat -f '%Sm' -t '%Y-%m' "$0" >/dev/null 2>&1; then
  mtime_month() { stat -f '%Sm' -t '%Y-%m' "$1"; }
else
  mtime_month() { date -d "@$(stat -c '%Y' "$1")" '+%Y-%m'; }
fi

found=0
for f in "$EFFORTS_DIR"/*.md; do
  [[ -e "$f" ]] || continue
  [[ "$(mtime_month "$f")" == "$MONTH" ]] || continue
  found=$((found+1))
  slug="$(basename "$f" .md)"
  echo "=== $slug ($(mtime_month "$f")) ==="
  # frontmatter status/repo/jira lines
  awk 'NR==1&&$0=="---"{fm=1;next} fm&&$0=="---"{exit} fm' "$f" \
    | grep -iE '^(status|resolution|repo|jira|parent_jira|superseded_by|tracking_only|owner):' || true
  # PR references (owner/repo#N and pull/N URLs) + Jira keys
  { grep -oiE '(github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+|#[0-9]{2,6}|[A-Z]{2,5}-[0-9]{3,6})' "$f" || true; } \
    | sort -u | tr '\n' ' '
  echo; echo
done

echo "---- $found efforts with mtime in $MONTH under $EFFORTS_DIR ----"
