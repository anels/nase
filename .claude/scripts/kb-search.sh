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
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

log_kb_search_result() {
  local file_path="$1"
  command -v python3 >/dev/null 2>&1 || return 0
  local args=(record --file "$file_path" --access search-result --source kb-search)
  # Pass the session through when the environment carries one; without it the
  # logger falls back to a per-process id that no skill activation ever keyed.
  local session="${CLAUDE_SESSION_ID:-${CLAUDE_SESSIONID:-}}"
  [ -n "$session" ] && args+=(--session "$session")
  python3 "$SCRIPT_DIR/kb-usage-log.py" "${args[@]}" >/dev/null 2>&1 || true
}

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
# One awk pass per KB file does the whole per-entry job: find the matches, extract each
# match's enclosing section, apply the since/tag/confidence/mentions filters, and score
# the survivors. It emits one finished record per surviving section, so the shell loop
# below only has to pick the freshness date and append.
#
# All of that used to be shell: a `grep -n` plus one awk per match to extract, then per
# entry a date grep, the filters, the scoring greps, and an encode. On a KB of 88 files a
# common term took 103 seconds. The awk work was never the cost - profiling it per file
# totals 2.7 seconds - and neither was the subprocess count on its own. The cost was one
# line: `${entry//$'\n'/$'\x1f'}` ran once per entry, and bash 3.2, the macOS default,
# is quadratic in a global pattern substitution. Encoding here instead removes 282 of
# those for a common term; `tr` in the render loop removes the last ten.
#
# A section is the nearest enclosing `###`, `##`, or file `#` heading with nested
# headings kept inside, which supports dated entries and current-state sections alike.
# The search, filter, scoring, and output contracts are unchanged, verified by diffing
# this against the previous version's output across fourteen query and filter shapes.
#
# Inputs arrive through the environment, not -v: awk expands escape sequences in a -v
# assignment, and the terms below are regex-escaped with backslashes.
# Emits: score, entry date (`0000-00-00` when the section has no dated heading), and the
# section text with newlines encoded as \x1f, the encoding the results file uses.
extract_scored_blocks() {
  local file="$1"
  KB_SEARCH_PATTERN="$2" \
  KB_SEARCH_TERMS="$3" \
  KB_SINCE="$SINCE_DATE" \
  KB_TAG="$TAG_FILTER" \
  KB_CONFIDENCE="$CONF_FILTER" \
  KB_MENTIONS_EXTRA="$MENTIONS_EXTRA" \
  awk '
    function heading_level(line) {
      if (line ~ /^###### /) return 6
      if (line ~ /^##### /) return 5
      if (line ~ /^#### /) return 4
      if (line ~ /^### /) return 3
      if (line ~ /^## /) return 2
      if (line ~ /^# /) return 1
      return 0
    }

    # Scoring counts occurrences, not matching lines - several hits on one line each count,
    # which is the contract `grep -Fio <needle> | wc -l` set. The needle is the
    # regex-escaped term, so `gsub` still matches literally.
    function occurrences(haystack, needle_regex,   copy) {
      if (needle_regex == "") return 0
      copy = haystack
      return gsub(needle_regex, "", copy)
    }

    function join_lines(from, to,   i, out) {
      out = ""
      for (i = from; i <= to; i++) out = out (i == from ? "" : "\n") buf[i]
      return out
    }

    # `grep -i '^**Label:**' | grep -qiF -- wanted`: a line that starts with the label and
    # also contains the wanted value, both case-insensitively.
    function field_matches(text, label, wanted,   n, i, parts, low) {
      n = split(text, parts, "\n")
      for (i = 1; i <= n; i++) {
        low = tolower(parts[i])
        if (index(low, tolower(label)) == 1 && index(low, tolower(wanted)) > 0) return 1
      }
      return 0
    }

    BEGIN {
      US = sprintf("%c", 31)
      pattern = tolower(ENVIRON["KB_SEARCH_PATTERN"])
      # Escaping only adds backslashes before metacharacters, so lowercasing the
      # regex-escaped terms is still safe.
      term_count = split(ENVIRON["KB_SEARCH_TERMS"], terms, US)
      for (i = 1; i <= term_count; i++) lower_terms[i] = tolower(terms[i])
      since = ENVIRON["KB_SINCE"]
      tag = ENVIRON["KB_TAG"]
      confidence = ENVIRON["KB_CONFIDENCE"]
      mentions_extra = ENVIRON["KB_MENTIONS_EXTRA"]
      section_count = 0
      current = 0
    }

    {
      buf[NR] = $0
      level = heading_level($0)
      if (level >= 1 && level <= 3) {
        section_count++
        section_start[section_count] = NR
        section_level[section_count] = level
        current = section_count
      }
      owner[NR] = current
      if (tolower($0) ~ pattern) match_line[NR] = 1
    }

    END {
      last_end = 0
      for (line = 1; line <= NR; line++) {
        if (!(line in match_line)) continue
        if (last_end && line <= last_end) continue
        section = owner[line]
        if (section == 0) continue

        start = section_start[section]
        boundary_level = section_level[section] == 1 ? 2 : section_level[section]
        end = NR
        for (next_section = section + 1; next_section <= section_count; next_section++) {
          if (section_level[next_section] <= boundary_level) {
            end = section_start[next_section] - 1
            break
          }
        }
        if (line > end) continue

        # Claim the whole section before the filters run, so one section yields at most
        # one result however many of its lines matched.
        last_end = end

        # A sentinel rather than an empty string when the section carries no dated
        # heading. Tab is IFS whitespace, so the reader collapses adjacent tabs: an
        # empty middle field shifts the entry text into the date variable and leaves
        # the entry empty, which dropped every undated section. The shell already
        # substitutes this same value when it has no date to work with.
        entry_date = "0000-00-00"
        for (i = start; i <= end; i++) {
          if (buf[i] ~ /^### [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) {
            entry_date = substr(buf[i], 5, 10)
            break
          }
        }

        if (since != "" && entry_date != "0000-00-00" && entry_date < since) continue

        entry = join_lines(start, end)

        if (tag != "" && !field_matches(entry, "**Tags:**", tag)) continue
        if (confidence != "" && !field_matches(entry, "**Confidence:**", confidence)) continue
        if (mentions_extra != "" && index(entry, mentions_extra) == 0) continue

        header_line = tolower(buf[start])
        body = tolower(join_lines(start + 1, end))

        header_hits = 0
        body_hits = 0
        for (i = 1; i <= term_count; i++) {
          header_hits += occurrences(header_line, lower_terms[i])
          body_hits += occurrences(body, lower_terms[i])
        }
        score = header_hits * 2 + body_hits

        encoded = entry
        gsub(/\n/, US, encoded)
        print score "\t" entry_date "\t" encoded
      }
    }
  ' "$file"
}

# ── run search ────────────────────────────────────────────────────────────────
TMPDIR_SEARCH=$(mktemp -d)
trap 'rm -rf "$TMPDIR_SEARCH"; rm -f "$KB_FILES_TMP"' EXIT

RESULTS_FILE="$TMPDIR_SEARCH/results.txt"
TOP_RESULTS_FILE="$TMPDIR_SEARCH/top-results.txt"
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
  # Escape regex metacharacters in each term so a literal `|` in user input is not
  # interpreted as ERE alternation. `pattern` is the match alternation; `term_list`
  # is the same escaped terms, \x1f separated, for the per-term scoring inside awk.
  local pattern="" term_list=""
  local term escaped
  for term in "${terms[@]}"; do
    escaped=$(printf '%s' "$term" | sed 's/[][\\^$.*+?(){}|]/\\&/g')
    if [ -z "$pattern" ]; then
      pattern="$escaped"
      term_list="$escaped"
    else
      pattern="$pattern|$escaped"
      term_list="$term_list"$'\x1f'"$escaped"
    fi
  done

  : > "$RESULTS_FILE"

  while IFS= read -r kb_file; do
    [ -f "$kb_file" ] || continue

    # File mtime — once per file, not per entry. STAT_KIND chosen above.
    local file_mtime
    file_mtime=$(file_mtime_for "$kb_file")

    local score entry_date entry_enc fresh_date
    while IFS=$'\t' read -r score entry_date entry_enc; do
      [ -n "$entry_enc" ] || continue

      # Freshness: prefer newer of entry date vs file mtime
      fresh_date="$entry_date"
      if [[ -n "$file_mtime" ]] && [[ "$file_mtime" > "$fresh_date" ]]; then
        fresh_date="$file_mtime"
      fi

      # Result record: score|fresh_date|file|entry, entry newlines already \x1f encoded
      printf '%s\t%s\t%s\t%s\n' "$score" "${fresh_date:-0000-00-00}" "$kb_file" "$entry_enc" >> "$RESULTS_FILE"
    done < <(extract_scored_blocks "$kb_file" "$pattern" "$term_list")
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

# Sort: by score desc, then freshness desc, then file asc; take top 10.
sort -t$'\t' -k1,1rn -k2,2r -k3,3 "$RESULTS_FILE" | head -10 > "$TOP_RESULTS_FILE"

# Name the truncation. A header count of 23 above ten printed entries otherwise
# reads as "these are the results".
SHOWN_COUNT=$(wc -l < "$TOP_RESULTS_FILE" | tr -d ' ')
if [ "$RESULT_COUNT" -gt "$SHOWN_COUNT" ]; then
  echo "Showing the top ${SHOWN_COUNT} of ${RESULT_COUNT} by relevance; narrow the query or add a filter to see the rest."
  echo ""
fi

cut -f3 "$TOP_RESULTS_FILE" | sort -u | while IFS= read -r kb_file; do
  [ -n "$kb_file" ] && log_kb_search_result "$kb_file"
done

while IFS=$'\t' read -r score fresh_date kb_file entry; do
  if [ "$SHOW_SCORE" -eq 1 ]; then
    echo "**Score:** $score"
  fi
  echo "**File:** \`${kb_file}\`"
  # `tr`, not `${entry//.../...}`. bash 3.2 is the macOS default and its global pattern
  # substitution is quadratic: measured at 17 seconds for one 32 KB entry with 400
  # separators, against 0.011 seconds through `tr`. Ten of these were 33 of the 42
  # seconds a common query took.
  decoded=$(printf '%s' "$entry" | tr '\037' '\n')
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
done < "$TOP_RESULTS_FILE"
