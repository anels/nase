#!/usr/bin/env bash
# kb-gap-scan.sh — Scan daily logs + lessons for knowledge-gap signals.
#
# Detects 5 marker types via regex:
#   uncertainty  — 不确定/unclear/TIL/figured out
#   lookup       — 查文档/looked up/checked docs
#   sme_teach    — 教我/告诉我/told me/explained that/corrected by
#   first_time   — 第一次/first time/never seen
#   post_error   — 根因/root cause/turns out
#
# Usage: bash .claude/scripts/kb-gap-scan.sh [opts]
#   --since YYYY-MM-DD       Range start (default: today - 14d)
#   --until YYYY-MM-DD       Range end (default: today)
#   --repo NAME              Only scan logs containing this repo name (case-insensitive)
#   --logs-dir DIR           Override logs directory (default: workspace/logs)
#   --lessons PATH           Override lessons file (default: workspace/tasks/lessons.md)
#   --no-lessons             Skip lessons file
#
# Output (TSV, stdout): marker_type<TAB>file<TAB>line<TAB>snippet
# Exit 0: hits emitted; 2: no hits / no logs in range; 1: usage error.

set -euo pipefail

SINCE=""
UNTIL=""
REPO_FILTER=""
LOGS_DIR="workspace/logs"
LESSONS_FILE="workspace/tasks/lessons.md"
USE_LESSONS=1

need_value() {
  local opt="$1"
  local value="${2-}"
  if [ -z "$value" ] || [[ "$value" == --* ]]; then
    echo "ERROR: ${opt} requires a value" >&2
    exit 1
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --since)      need_value "$1" "${2-}"; SINCE="$2"; shift 2 ;;
    --until)      need_value "$1" "${2-}"; UNTIL="$2"; shift 2 ;;
    --repo)       need_value "$1" "${2-}"; REPO_FILTER="$2"; shift 2 ;;
    --logs-dir)   need_value "$1" "${2-}"; LOGS_DIR="$2"; shift 2 ;;
    --lessons)    need_value "$1" "${2-}"; LESSONS_FILE="$2"; shift 2 ;;
    --no-lessons) USE_LESSONS=0; shift ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "ERROR: unknown arg '$1'" >&2
      exit 1 ;;
  esac
done

TODAY=$(date '+%Y-%m-%d')
[ -z "$UNTIL" ] && UNTIL="$TODAY"
if [ -z "$SINCE" ]; then
  SINCE=$(date -v-14d '+%Y-%m-%d' 2>/dev/null \
       || date -d '14 days ago' '+%Y-%m-%d' 2>/dev/null \
       || echo "1970-01-01")
fi

# ── marker patterns (extended regex, case-insensitive via grep -i) ────────────
UNCERTAINTY_PAT='不确定|不清楚|存疑|没搞懂|not sure|uncertain|unclear|\bTIL\b|figured out'
LOOKUP_PAT='查文档|翻文档|查阅文档|looked up|checked.{0,10}docs|read.{0,10}docs'
SME_TEACH_PAT='教我|告诉我|纠正|told me|explained that|corrected by|SME[[:space:]]+(told|said|explained)'
FIRST_TIME_PAT='第一次|初次|first time|never seen|new to me'
POST_ERROR_PAT='根因|root cause|turns out'

# ── collect log files in date range ──────────────────────────────────────────
FILES=()
if [ -d "$LOGS_DIR" ]; then
  shopt -s nullglob 2>/dev/null
  for f in "$LOGS_DIR"/*.md; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .md)
    date_part=$(printf '%s' "$base" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)
    [ -z "$date_part" ] && continue
    if [[ "$date_part" < "$SINCE" ]] || [[ "$date_part" > "$UNTIL" ]]; then
      continue
    fi
    FILES+=("$f")
  done
fi

if [ "$USE_LESSONS" -eq 1 ] && [ -n "$LESSONS_FILE" ] && [ -f "$LESSONS_FILE" ]; then
  FILES+=("$LESSONS_FILE")
fi

if [ ${#FILES[@]} -eq 0 ]; then
  echo "No logs matched ${SINCE}..${UNTIL} under ${LOGS_DIR}" >&2
  exit 2
fi

# ── apply --repo filter (file-level: must mention repo name) ─────────────────
if [ -n "$REPO_FILTER" ]; then
  KEPT=()
  for f in "${FILES[@]}"; do
    if [ "$USE_LESSONS" -eq 1 ] && [ "$f" = "$LESSONS_FILE" ]; then
      KEPT+=("$f")
      continue
    fi
    if grep -qiF -- "$REPO_FILTER" "$f"; then
      KEPT+=("$f")
    fi
  done
  FILES=("${KEPT[@]}")
  if [ ${#FILES[@]} -eq 0 ]; then
    echo "No logs in ${SINCE}..${UNTIL} mention '${REPO_FILTER}'" >&2
    exit 2
  fi
fi

# ── scan ─────────────────────────────────────────────────────────────────────
HITS=$(mktemp)
trap 'rm -f "$HITS"' EXIT

lesson_line_in_scope() {
  local file="$1"
  local target_line="$2"

  awk -v target_ln="$target_line" -v since="$SINCE" -v until="$UNTIL" -v repo="$REPO_FILTER" '
    function finish_section(end_ln, repo_lc) {
      if (target_ln < section_start || target_ln > end_ln) return
      done = 1
      if (("x" section_date) < ("x" since) || ("x" section_date) > ("x" until)) {
        code = 1
        exit code
      }
      if (repo != "") {
        repo_lc = tolower(repo)
        if (index(tolower(section_text), repo_lc) == 0) {
          code = 1
          exit code
        }
      }
      code = 0
      exit code
    }
    /^## [^ ]+ -- [0-9]{4}-[0-9]{2}-[0-9]{2} -- / {
      if (in_section) finish_section(NR - 1)
      in_section = 1
      section_start = NR
      section_text = $0 "\n"
      section_date = substr($0, index($0, "-- ") + 3, 10)
      next
    }
    in_section { section_text = section_text $0 "\n" }
    END {
      if (!done && in_section) finish_section(NR)
      if (done) exit code
      exit 1
    }
  ' "$file"
}

emit_hits() {
  local mtype="$1"
  local pat="$2"
  local f
  for f in "${FILES[@]}"; do
    while IFS= read -r raw; do
      [ -z "$raw" ] && continue
      local ln content snippet
      ln=$(printf '%s' "$raw" | cut -d: -f1)
      content=$(printf '%s' "$raw" | cut -d: -f2-)
      if [ "$USE_LESSONS" -eq 1 ] && [ "$f" = "$LESSONS_FILE" ]; then
        lesson_line_in_scope "$f" "$ln" || continue
      fi
      snippet=$(printf '%s' "$content" \
        | tr '\t' ' ' \
        | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
      if [ "${#snippet}" -gt 240 ]; then
        snippet="${snippet:0:240}…"
      fi
      printf '%s\t%s\t%s\t%s\n' "$mtype" "$f" "$ln" "$snippet" >> "$HITS"
    done < <(grep -nEi "$pat" "$f" 2>/dev/null)
  done
}

emit_hits uncertainty "$UNCERTAINTY_PAT"
emit_hits lookup      "$LOOKUP_PAT"
emit_hits sme_teach   "$SME_TEACH_PAT"
emit_hits first_time  "$FIRST_TIME_PAT"
emit_hits post_error  "$POST_ERROR_PAT"

if [ ! -s "$HITS" ]; then
  echo "No knowledge-gap signals in ${SINCE}..${UNTIL}" >&2
  exit 2
fi

# Stable sort: by file then line number
sort -t$'\t' -k2,2 -k3,3n "$HITS"
