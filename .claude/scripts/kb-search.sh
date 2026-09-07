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
# `mentions:` may be repeated. Several paths are swept once and rendered as one section
# per path, which is why a caller with ten changed paths pays one file walk instead of
# ten. One path renders exactly as it did before.
#
# One difference in the multi-path form: the fuzzy fallback fires only when the whole
# sweep found nothing, so a path that would have fuzzy-matched alone gets no fallback
# when a sibling path had hits. Per-path fallback would cost an extra sweep for every
# path with no mentions, which is the common case; and splitting a file path into its
# segments and reporting whatever they hit is noise rather than a mention.
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
MENTIONS_PATHS=()
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
    mentions:*)  MENTIONS_PATHS+=("${arg#mentions:}") ;;
    *)           QUERY_TERMS+=("$arg") ;;
  esac
  shift
done

QUERY="${QUERY_TERMS[*]:-}"
# If no query but mentions: provided, the paths act as the query, answering "which KB
# entries reference this file or folder?" out of the box. Several paths become several
# search terms, and the results are rendered per path from the one sweep.
MENTIONS_AS_QUERY=0
if [ -z "$QUERY" ] && [ "${#MENTIONS_PATHS[@]}" -gt 0 ]; then
  MENTIONS_AS_QUERY=1
  QUERY="${MENTIONS_PATHS[*]}"
fi
if [ -z "$QUERY" ]; then
  echo "Usage: kb-search.sh <query> [in:general|projects|ops|cross-project] [tag:<tag>] [since:YYYY-MM-DD] [confidence:low|medium|high] [mentions:<path>] [--with-score] [--full] [--max-entry-lines N]" >&2
  exit 1
fi

# Derive once: is the mentions: filter a distinct extra constraint, or did it
# already act as the query (in which case per-entry re-filtering is redundant —
# every surviving entry already contains the path via the file-level grep).
# When a path is also the query, every surviving entry already contains it, so the
# per-entry re-check is redundant. It is a real extra constraint only alongside a
# separate query, which is the single-path case; several paths plus a query would mean
# "contains all of them", which no caller asks for.
MENTIONS_EXTRA=""
if [ "$MENTIONS_AS_QUERY" -eq 0 ] && [ "${#MENTIONS_PATHS[@]}" -eq 1 ]; then
  MENTIONS_EXTRA="${MENTIONS_PATHS[0]}"
fi
if [ "$MENTIONS_AS_QUERY" -eq 0 ] && [ "${#MENTIONS_PATHS[@]}" -gt 1 ]; then
  echo "ERROR: several mentions: paths need to act as the query; drop the separate query" >&2
  exit 1
fi

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
# The `\x1f` encode belongs here rather than in the shell: bash 3.2, the macOS default,
# is quadratic in a global pattern substitution, so an encode per entry does not scale.
# See the render loop's `tr` for the measurement.
#
# A section is the nearest enclosing `###`, `##`, or file `#` heading with nested
# headings kept inside, which supports dated entries and current-state sections alike.
#
# Inputs arrive through the environment, not -v: awk expands escape sequences in a -v
# assignment, and the terms below are regex-escaped with backslashes.
# Emits: score, entry date (`0000-00-00` when the section has no dated heading), the
# 1-based indices of the terms this entry contains, and the section text with newlines
# encoded as \x1f, the encoding the results file uses.
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

    # A line that starts with the label and also contains the wanted value, both
    # case-insensitively. Replaces a grep for the label piped into a fixed-string grep
    # for the value. No apostrophes in here: the whole program sits inside shell single
    # quotes, and a stray one ends them.
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
        matched_terms = ""
        for (i = 1; i <= term_count; i++) {
          term_header = occurrences(header_line, lower_terms[i])
          term_body = occurrences(body, lower_terms[i])
          header_hits += term_header
          body_hits += term_body
          # Which terms this entry actually holds, so a caller sweeping several paths at
          # once can render a section per path without a second pass over the files.
          if (term_header + term_body > 0) {
            matched_terms = matched_terms (matched_terms == "" ? "" : ",") i
          }
        }
        score = header_hits * 2 + body_hits
        # Never empty: the alternation matched a line inside this entry, so some term
        # occurs in it. An empty middle field would collapse under the tab IFS used to
        # read this record back.
        if (matched_terms == "") matched_terms = "0"

        encoded = entry
        gsub(/\n/, US, encoded)
        print score "\t" entry_date "\t" matched_terms "\t" encoded
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

    local score entry_date matched_terms entry_enc fresh_date
    while IFS=$'\t' read -r score entry_date matched_terms entry_enc; do
      [ -n "$entry_enc" ] || continue

      # Freshness: prefer newer of entry date vs file mtime
      fresh_date="$entry_date"
      if [[ -n "$file_mtime" ]] && [[ "$file_mtime" > "$fresh_date" ]]; then
        fresh_date="$file_mtime"
      fi

      # Result record: score, freshness, matched term indices, file, entry. The entry's
      # newlines are already \x1f encoded, so the record stays one line.
      printf '%s\t%s\t%s\t%s\t%s\n' \
        "$score" "${fresh_date:-0000-00-00}" "$matched_terms" "$kb_file" "$entry_enc" \
        >> "$RESULTS_FILE"
    done < <(extract_scored_blocks "$kb_file" "$pattern" "$term_list")
  done < "$KB_FILES_TMP"
}

# Try exact search first. Several mentions: paths are several terms, so that one sweep
# can answer for all of them; anything else stays a single term, as before.
if [ "$MENTIONS_AS_QUERY" -eq 1 ] && [ "${#MENTIONS_PATHS[@]}" -gt 1 ]; then
  run_search "${MENTIONS_PATHS[@]}"
else
  run_search "$QUERY"
fi

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

# ── sort and print, per rendered section ──────────────────────────────────────
FILTER_LABEL=""
[ -n "$DOMAIN_FILTER" ] && FILTER_LABEL+=" in:$DOMAIN_FILTER"
[ -n "$TAG_FILTER" ]    && FILTER_LABEL+=" tag:$TAG_FILTER"
[ -n "$SINCE_DATE" ]    && FILTER_LABEL+=" since:$SINCE_DATE"
[ -n "$CONF_FILTER" ]   && FILTER_LABEL+=" confidence:$CONF_FILTER"
[ -n "$MENTIONS_EXTRA" ] && FILTER_LABEL+=" mentions:$MENTIONS_EXTRA"

# Entries whose matched-term field includes this 1-based index. Called once per path when
# several are swept together; with an empty index it passes everything through, which is
# the single-section path and byte-identical to the pre-change output.
select_for_term() {
  local index="$1" source="$2" target="$3"
  if [ -z "$index" ]; then
    cp "$source" "$target"
    return 0
  fi
  awk -F'\t' -v want="$index" '
    {
      count = split($3, terms, ",")
      for (i = 1; i <= count; i++) {
        if (terms[i] == want) {
          print
          next
        }
      }
    }
  ' "$source" > "$target"
}

# One rendered section: header, top ten by relevance, telemetry, entries.
render_section() {
  local label="$1" term_index="$2"
  local section_file="$TMPDIR_SEARCH/section.txt"
  select_for_term "$term_index" "$RESULTS_FILE" "$section_file"

  local result_count
  result_count=$(wc -l < "$section_file" | tr -d ' ')
  if [ "$result_count" -eq 0 ]; then
    echo "## KB Search — \"${label}\" · no results${FILTER_LABEL}"
    echo ""
    echo "---"
    echo ""
    return 1
  fi

  if [ "$FUZZY" = true ]; then
    echo "## KB Search — \"${label}\" · ${result_count} partial match(es)"
    echo "⚠️  No exact match. Showing partial matches."
  else
    echo "## KB Search — \"${label}\" · ${result_count} result(s)${FILTER_LABEL}"
  fi
  echo ""

  # Sort: by score desc, then freshness desc, then file asc; take top 10.
  sort -t$'\t' -k1,1rn -k2,2r -k4,4 "$section_file" | head -10 > "$TOP_RESULTS_FILE"

  # Name the truncation. A header count of 23 above ten printed entries otherwise
  # reads as "these are the results".
  local shown_count
  shown_count=$(wc -l < "$TOP_RESULTS_FILE" | tr -d ' ')
  if [ "$result_count" -gt "$shown_count" ]; then
    echo "Showing the top ${shown_count} of ${result_count} by relevance; narrow the query or add a filter to see the rest."
    echo ""
  fi

  cut -f4 "$TOP_RESULTS_FILE" | sort -u | while IFS= read -r kb_file; do
    [ -n "$kb_file" ] && log_kb_search_result "$kb_file"
  done

  local score fresh_date matched_terms kb_file entry decoded total_lines remaining
  while IFS=$'\t' read -r score fresh_date matched_terms kb_file entry; do
    if [ "$SHOW_SCORE" -eq 1 ]; then
      echo "**Score:** $score"
    fi
    echo "**File:** \`${kb_file}\`"
    # `tr`, not a global pattern substitution. bash 3.2 is the macOS default and its
    # global pattern substitution is quadratic: measured at 17 seconds for one 32 KB
    # entry with 400 separators, against 0.011 seconds through `tr`. The subprocess is
    # the fast path here, which is the opposite of what it looks like.
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
  return 0
}

if [ "$MENTIONS_AS_QUERY" -eq 1 ] && [ "${#MENTIONS_PATHS[@]}" -gt 1 ]; then
  # One section per path, from the single sweep above. Exit 0 when any path had a hit,
  # so a caller reading the exit code still learns whether the sweep found anything.
  ANY_RESULTS=1
  for path_index in "${!MENTIONS_PATHS[@]}"; do
    render_section "mentions:${MENTIONS_PATHS[$path_index]}" "$((path_index + 1))" && ANY_RESULTS=0
  done
  exit "$ANY_RESULTS"
fi

render_section "$QUERY" ""
