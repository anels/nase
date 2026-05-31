#!/usr/bin/env bash
# requires bash 3.2+ (macOS default)
# kb-search.sh — Search KB files with filters, weighted relevance, and fuzzy fallback
#
# Usage: bash .claude/scripts/kb-search.sh [query] [in:general|projects|ops|cross-project] \
#              [tag:<tag>] [since:YYYY-MM-DD] [confidence:low|medium|high] \
#              [mentions:<path-or-fragment>] [--with-score] [--full] [--max-entry-lines N]
#
# Output: matched KB entries sorted by relevance + freshness, printed to stdout
# Exit 0: results found; Exit 2: no results; Exit 1: usage error
#
# When `mentions:<path>` is given without a query, the path itself is used as
# the query — answers "which KB entries reference this file/folder?" before edit.
#
# Examples:
#   bash .claude/scripts/kb-search.sh "caching"
#   bash .claude/scripts/kb-search.sh "auth gotcha" in:projects tag:gotcha
#   bash .claude/scripts/kb-search.sh "EF Core" since:2026-01-01 confidence:high
#   bash .claude/scripts/kb-search.sh mentions:src/auth/handler.ts
#   bash .claude/scripts/kb-search.sh "timeout" mentions:src/checkout/

set -uo pipefail

# ── parse args ────────────────────────────────────────────────────────────────
QUERY_TERMS=()
DOMAIN_FILTER=""
TAG_FILTER=""
SINCE_DATE=""
CONF_FILTER=""
MENTIONS_PATH=""
SHOW_SCORE=0
FULL_OUTPUT=0
MAX_ENTRY_LINES=24

while [ "$#" -gt 0 ]; do
  arg="$1"
  case "$arg" in
    --with-score) SHOW_SCORE=1 ;;
    --full)       FULL_OUTPUT=1 ;;
    --max-entry-lines)
      shift
      if ! [[ "${1:-}" =~ ^[0-9]+$ ]] || [ "${1:-0}" -lt 1 ]; then
        echo "ERROR: --max-entry-lines requires a positive integer" >&2
        exit 1
      fi
      MAX_ENTRY_LINES="$1" ;;
    --max-entry-lines=*)
      value="${arg#--max-entry-lines=}"
      if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ]; then
        echo "ERROR: --max-entry-lines requires a positive integer" >&2
        exit 1
      fi
      MAX_ENTRY_LINES="$value" ;;
    in:*)        DOMAIN_FILTER="${arg#in:}" ;;
    tag:*)       TAG_FILTER="${arg#tag:}" ;;
    since:*)     SINCE_DATE="${arg#since:}" ;;
    confidence:*)CONF_FILTER="${arg#confidence:}" ;;
    mentions:*)  MENTIONS_PATH="${arg#mentions:}" ;;
    *)           QUERY_TERMS+=("$arg") ;;
  esac
  shift
done

QUERY="${QUERY_TERMS[*]:-}"
# If no query but mentions: provided, treat the path as the query — answers
# "which KB entries reference this file/folder?" out of the box.
if [ -z "$QUERY" ] && [ -n "$MENTIONS_PATH" ]; then
  QUERY="$MENTIONS_PATH"
fi
if [ -z "$QUERY" ]; then
  echo "Usage: kb-search.sh <query> [in:general|projects|ops|cross-project] [tag:<tag>] [since:YYYY-MM-DD] [confidence:low|medium|high] [mentions:<path>] [--with-score] [--full] [--max-entry-lines N]" >&2
  exit 1
fi

# Derive once: is the mentions: filter a distinct extra constraint, or did it
# already act as the query (in which case per-entry re-filtering is redundant —
# every surviving entry already contains the path via the file-level grep).
MENTIONS_EXTRA=""
[ -n "$MENTIONS_PATH" ] && [ "$QUERY" != "$MENTIONS_PATH" ] && MENTIONS_EXTRA="$MENTIONS_PATH"

# ── determine search scope ─────────────────────────────────────────────────────
KB_ROOT="workspace/kb"
case "$DOMAIN_FILTER" in
  general)      SEARCH_DIRS=("$KB_ROOT/general") ;;
  projects)     SEARCH_DIRS=("$KB_ROOT/projects") ;;
  ops)          SEARCH_DIRS=("$KB_ROOT/ops") ;;
  cross-project)SEARCH_DIRS=("$KB_ROOT/cross-project") ;;
  "")           SEARCH_DIRS=("$KB_ROOT") ;;
  *)
    echo "ERROR: unknown domain filter 'in:${DOMAIN_FILTER}'. Use: general, projects, ops, cross-project" >&2
    exit 1 ;;
esac

# Collect all KB .md files (exclude .domain-map.md) into a temp list
KB_FILES_TMP=$(mktemp)
find "${SEARCH_DIRS[@]}" -name "*.md" -not -name ".domain-map.md" 2>/dev/null | sort > "$KB_FILES_TMP"

if [ ! -s "$KB_FILES_TMP" ]; then
  echo "No KB files found under: ${SEARCH_DIRS[*]}" >&2
  rm -f "$KB_FILES_TMP"
  exit 2
fi

# ── search function ───────────────────────────────────────────────────────────
# Extract entry block containing match_line: from enclosing `### ` header to
# the line before the next `## ` heading (or EOF). Single awk pass — replaces
# the previous per-line `sed -n "${n}p"` loop that was O(n²) per match.
extract_entry_block() {
  local file="$1"
  local match_line="$2"
  awk -v ln="$match_line" '
    function emit() {
      for (i = start; i <= NR - 1; i++) print buf[i]
      done = 1
    }
    /^### / {
      if (start && ln >= start && ln <= NR - 1) emit()
      if (done) exit
      delete buf
      start = NR
      buf[NR] = $0
      next
    }
    /^##+ / && start {
      if (ln >= start && ln <= NR - 1) emit()
      if (done) exit
      start = 0
      next
    }
    start { buf[NR] = $0 }
    END {
      if (!done && start && ln >= start) {
        for (i = start; i <= NR; i++) print buf[i]
      }
    }
  ' "$file"
}

# ── run search ────────────────────────────────────────────────────────────────
TMPDIR_SEARCH=$(mktemp -d)
trap 'rm -rf "$TMPDIR_SEARCH"; rm -f "$KB_FILES_TMP"' EXIT

RESULTS_FILE="$TMPDIR_SEARCH/results.txt"
FUZZY=false

# Detect stat dialect once. On Linux, `stat -f` means filesystem-info mode and
# silently succeeds with a multi-line dump — corrupting downstream tab records.
if stat -c '%y' "$KB_FILES_TMP" >/dev/null 2>&1; then
  STAT_KIND="gnu"
else
  STAT_KIND="bsd"
fi

file_mtime_for() {
  local f="$1"
  if [ "$STAT_KIND" = "gnu" ]; then
    stat -c '%y' "$f" 2>/dev/null | cut -d' ' -f1
  else
    stat -f '%Sm' -t '%Y-%m-%d' "$f" 2>/dev/null
  fi
}

run_search() {
  local terms=("$@")
  local pattern=""
  local term escaped
  for term in "${terms[@]}"; do
    # Escape regex metacharacters in each term so a literal `|` in user input
    # is not interpreted as ERE alternation.
    escaped=$(printf '%s' "$term" | sed 's/[][\\^$.*+?(){}|]/\\&/g')
    if [ -z "$pattern" ]; then
      pattern="$escaped"
    else
      pattern="$pattern|$escaped"
    fi
  done

  : > "$RESULTS_FILE"

  while IFS= read -r kb_file; do
    [ -f "$kb_file" ] || continue

    # File mtime — once per file, not per match. STAT_KIND chosen above.
    local file_mtime
    file_mtime=$(file_mtime_for "$kb_file")

    # Get matching line numbers (case-insensitive)
    while IFS= read -r match_line_num; do
      [ -z "$match_line_num" ] && continue

      local entry
      entry=$(extract_entry_block "$kb_file" "$match_line_num")
      [ -z "$entry" ] && continue

      # Extract header date
      local entry_date
      entry_date=$(echo "$entry" | grep -oE '^### [0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)

      # Apply since: filter
      if [ -n "$SINCE_DATE" ] && [ -n "$entry_date" ]; then
        if [[ "$entry_date" < "$SINCE_DATE" ]]; then continue; fi
      fi

      # Apply tag: filter
      if [ -n "$TAG_FILTER" ]; then
        if ! grep -i '^\*\*Tags:\*\*' <<< "$entry" | grep -qiF -- "$TAG_FILTER"; then continue; fi
      fi

      # Apply confidence: filter
      if [ -n "$CONF_FILTER" ]; then
        if ! grep -i '^\*\*Confidence:\*\*' <<< "$entry" | grep -qiF -- "$CONF_FILTER"; then continue; fi
      fi

      # Apply mentions: filter — case-sensitive literal path match.
      # MENTIONS_EXTRA is empty when the path *is* the query (file-level grep already matched).
      if [ -n "$MENTIONS_EXTRA" ]; then
        if ! grep -qF -- "$MENTIONS_EXTRA" <<< "$entry"; then continue; fi
      fi

      # Weighted relevance: header matches count 2x, body 1x
      local header_line
      header_line=$(echo "$entry" | head -1)
      local body_lines
      body_lines=$(echo "$entry" | tail -n +2)

      local header_hits=0
      local body_hits=0
      local h b
      for term in "${terms[@]}"; do
        h=$(grep -Fio -- "$term" <<< "$header_line" | wc -l | tr -d ' ')
        b=$(grep -Fio -- "$term" <<< "$body_lines"  | wc -l | tr -d ' ')
        header_hits=$((header_hits + h))
        body_hits=$((body_hits + b))
      done
      local score=$(( header_hits * 2 + body_hits ))

      # Freshness: prefer newer of entry date vs file mtime
      local fresh_date="$entry_date"
      if [[ -n "$file_mtime" ]] && [[ "$file_mtime" > "$fresh_date" ]]; then
        fresh_date="$file_mtime"
      fi

      # Write result record: score|fresh_date|file|entry
      # Newlines in entry → \x1f (unit separator) so each record stays one line
      local entry_enc="${entry//$'\n'/$'\x1f'}"
      printf '%s\t%s\t%s\t%s\n' "$score" "${fresh_date:-0000-00-00}" "$kb_file" "$entry_enc" >> "$RESULTS_FILE"
      break  # one result per entry block per file (avoid duplicates from multi-line matches)

    done < <(grep -nEi -- "$pattern" "$kb_file" 2>/dev/null | cut -d: -f1)
  done < "$KB_FILES_TMP"
}

# Try exact search first
run_search "$QUERY"

# Fuzzy fallback if no results
if [ ! -s "$RESULTS_FILE" ]; then
  # Split on space, hyphen, underscore
  IFS=' -_' read -ra PARTS <<< "$QUERY"
  if [ ${#PARTS[@]} -ge 2 ]; then
    FUZZY=true
    run_search "${PARTS[@]}"
  fi
fi

if [ ! -s "$RESULTS_FILE" ]; then
  echo "No KB entries found for \"${QUERY}\"${DOMAIN_FILTER:+ in:$DOMAIN_FILTER}${TAG_FILTER:+ tag:$TAG_FILTER}${SINCE_DATE:+ since:$SINCE_DATE}${CONF_FILTER:+ confidence:$CONF_FILTER}${MENTIONS_EXTRA:+ mentions:$MENTIONS_EXTRA}."
  echo ""
  echo "Suggestions:"
  echo "  - Try broader terms or individual keywords"
  echo "  - Run /nase:learn ${QUERY} to research and add this topic"
  exit 2
fi

# ── sort and print top 10 ──────────────────────────────────────────────────────
FILTER_LABEL=""
[ -n "$DOMAIN_FILTER" ] && FILTER_LABEL+=" in:$DOMAIN_FILTER"
[ -n "$TAG_FILTER" ]    && FILTER_LABEL+=" tag:$TAG_FILTER"
[ -n "$SINCE_DATE" ]    && FILTER_LABEL+=" since:$SINCE_DATE"
[ -n "$CONF_FILTER" ]   && FILTER_LABEL+=" confidence:$CONF_FILTER"
[ -n "$MENTIONS_EXTRA" ] && FILTER_LABEL+=" mentions:$MENTIONS_EXTRA"

RESULT_COUNT=$(wc -l < "$RESULTS_FILE" | tr -d ' ')

if [ "$FUZZY" = true ]; then
  echo "## KB Search — \"${QUERY}\" · ${RESULT_COUNT} partial match(es)"
  echo "⚠️  No exact match. Showing partial matches."
else
  echo "## KB Search — \"${QUERY}\" · ${RESULT_COUNT} result(s)${FILTER_LABEL}"
fi
echo ""

# Sort: by score desc, then freshness desc, then file asc; take top 10
sort -t$'\t' -k1,1rn -k2,2r -k3,3 "$RESULTS_FILE" | head -10 | while IFS=$'\t' read -r score fresh_date kb_file entry; do
  if [ "$SHOW_SCORE" -eq 1 ]; then
    echo "**Score:** $score"
  fi
  echo "**File:** \`${kb_file}\`"
  decoded="${entry//$'\x1f'/$'\n'}"
  if [ "$FULL_OUTPUT" -eq 1 ]; then
    printf '%s\n' "$decoded"
  else
    total_lines=$(printf '%s\n' "$decoded" | wc -l | tr -d ' ')
    printf '%s\n' "$decoded" | sed -n "1,${MAX_ENTRY_LINES}p"
    if [ "$total_lines" -gt "$MAX_ENTRY_LINES" ]; then
      remaining=$((total_lines - MAX_ENTRY_LINES))
      echo "... (${remaining} more lines; rerun with --full to show complete entries)"
    fi
  fi
  echo ""
  echo "---"
  echo ""
done
