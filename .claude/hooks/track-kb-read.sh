#!/usr/bin/env bash
# PostToolUse:Read|Grep|Glob|Bash hook — record KB file access to workspace/stats/kb-usage.jsonl.
#
# Read is the precise signal. Grep, Glob and Bash reach the KB too, and in practice far
# more often than Read does, so they are recorded under their own sources (`grep-hook`,
# `bash-hook`) and the report can tell them apart. Bash is read from the command text,
# so it is an upper bound: a path named in a command that then failed still counts.

set -uo pipefail

HOOK_DIR=${BASH_SOURCE[0]%/*}
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.
# shellcheck source=../lib/hook-common.sh
{ [ -r "$HOOK_DIR/../lib/hook-common.sh" ] && . "$HOOK_DIR/../lib/hook-common.sh"; } 2>/dev/null \
  || { echo "[track-kb-read] hook-common.sh unavailable - skipping" >&2; exit 0; }

nase_require jq python3 || exit 0

NASE_ROOT=$(nase_root) || exit 0
LOGGER="$HOOK_DIR/../scripts/kb-usage-log.py"

INPUT=$(cat)
# Every Bash command in a session passes through here, so leave before any jq or python
# when the payload never mentions the KB. A Windows path reaches the JSON as `workspace\\kb`.
case "$INPUT" in
  *workspace/kb* | *'workspace\\kb'*) ;;
  *) exit 0 ;;
esac

# One jq call. Fields are joined with a NUL byte so a path that contains spaces,
# backslashes or newlines survives intact; a shell variable cannot hold a NUL, so they
# are read straight off the pipe. The fourth field is the KB paths, one per line.
#
# A Grep or Glob result only counts when the call itself aimed at the KB, because a
# search over the docs also prints lines that merely mention a KB path. Only the file
# list and the `path:line:` prefix of a content line are read, never the matched text.
# A Bash command is cut into stages at `;`, `&&`, `||`, `|`, `&` and newlines, and a
# stage that writes or removes is skipped, because it is not a read. Judging the whole
# command instead would drop `cat kb/a.md | tee /tmp/x`, a plain read. Writers this
# misses (an inline `python3 -c open(..., "w")`) are counted as reads, so Bash is an
# upper bound.
JQ_PROGRAM=$(cat <<'JQ'
def slashed: gsub("\\\\+"; "/");
def kb_paths: [slashed | scan("workspace/kb/[^\\s\"\\x27\\x60()<>|;&,{}\\[\\]:\\\\]+\\.(?:md|sql)")];
def stages: [splits("\\s*(&&|\\|\\||[;|&\\n])\\s*")];
def writes: test("(^|\\s)(rm|mv|cp|tee|touch|install|rsync|truncate|dd|git\\s+(add|commit|checkout|stash|restore))\\s|sed\\s+-i|perl\\s+-\\S*i|>>?\\s*\\S*workspace/kb");
def listed_paths:
  if type == "string" then .
  else
    ((.filenames // []) | join("\n")) + "\n"
    + ([(.content // "") | splits("\\n") | select(test("^[^:]+\\.(md|sql):")) | sub(":.*$"; "")] | join("\n"))
  end;
(.tool_name // "Read") as $tool
| ((.tool_input.path // "") + " " + (.tool_input.glob // "") + " " + (.tool_input.pattern // "") | slashed) as $aim
| (.tool_input.command // "" | slashed) as $cmd
| (if $tool == "Read" then
     [.tool_input.file_path // .tool_input.path // "" | slashed]
   elif ($tool == "Grep" or $tool == "Glob") and ($aim | contains("workspace/kb")) then
     ((.tool_response // "" | listed_paths | kb_paths) + [.tool_input.path // "" | slashed])
   elif $tool == "Bash" then
     [$cmd | stages[] | select(writes | not) | kb_paths[]]
   else [] end
   | map(select(. != "")) | unique | .[0:10]) as $paths
| [$tool,
   (.session_id // .sessionId // ""),
   (if $tool == "Read" and .tool_response != null
    then ((.tool_response | if type == "object" then (.file.content // tostring) else tostring end) | length | tostring)
    else "" end),
   ($paths | join("\n"))]
| join("\u0000")
JQ
)

TOOL=""
SESSION_ID=""
CHARS=""
PATHS=""
{
  IFS= read -r -d '' TOOL || true
  IFS= read -r -d '' SESSION_ID || true
  IFS= read -r -d '' CHARS || true
  IFS= read -r -d '' PATHS || true
} < <(printf '%s' "$INPUT" | jq -j "$JQ_PROGRAM" 2>/dev/null || true)
[ -z "$PATHS" ] && exit 0
[ -n "$SESSION_ID" ] || SESSION_ID=$(nase_session_id)

case "$TOOL" in
  Grep | Glob) ACCESS=search-result SOURCE=grep-hook ;;
  Bash) ACCESS=read SOURCE=bash-hook ;;
  *) ACCESS=read SOURCE=read-hook ;;
esac

FILES=()
while IFS= read -r path; do
  # A native Windows jq prints CRLF, which leaves a CR on every line but the last.
  path=${path%$'\r'}
  [ -n "$path" ] && FILES+=("$path")
done <<< "$PATHS"

ARGS=(record --root "$NASE_ROOT" --access "$ACCESS" --source "$SOURCE")
[ -n "$SESSION_ID" ] && ARGS+=(--session "$SESSION_ID")
[ -n "$CHARS" ] && ARGS+=(--chars "$CHARS")
ARGS+=(--file "${FILES[@]}")
python3 "$LOGGER" "${ARGS[@]}" \
  >/dev/null 2>&1 || true

exit 0
