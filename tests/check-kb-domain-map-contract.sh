#!/usr/bin/env bash
# Verify the machine-readable contracts carried by workspace/kb/.domain-map.md.
#
# Two of them, each with its own consumers:
#   A. `retired:` - the upstream repo or domain no longer exists.
#   B. `### <group>` headings under `## Projects` - a routing label used to scope
#      a partial `/nase:onboard` refresh and to navigate the map by subject.
#
# Contract A - a retired entry means the upstream is gone while its KB file is
# kept as a historical record. Three behaviours depend on that one field, and
# each fails in a different direction if its doc loses the rule:
#
#   1. `/nase:onboard` batch refresh must exclude retired entries. Without it,
#      every batch re-resolves a repo that cannot be resolved and reports a skip,
#      which reads as a transient failure rather than a permanent exclusion.
#   2. `.claude/docs/kb-staleness.md` must exempt retired entries from the age
#      thresholds. Without it, a retired file ages past 30 days and then reports
#      `🔴 Stale / Likely diverged from current code` on every `/nase:doctor --deep`
#      run forever - a false positive with no possible fix, since there is no
#      current code to diverge from.
#   3. `.claude/docs/repo-resolution.md` Part 1 must check the marker before the
#      `.local-paths` miss path. Without it, resolving a retired repo prompts the
#      user for a local clone path that does not exist, so the prompt can only be
#      answered wrongly.
#
# The field is also required to stay positioned after the KB path, because two
# existing parsers read that line and neither knows about it:
# `kb-domain-resolve.sh` takes the first token after the arrow, and
# `kb-hygiene-scan.py -> domain_map_targets` reads only the path.
#
# Assertions anchor on identifiers and the section they must appear in, not on
# the surrounding prose, so rewording a paragraph does not fail this gate.
#
# Contract B - the group is a label, never a location. If a doc starts implying
# the group determines the KB file's path, the next edit moves files and breaks
# the ~300 references that name `workspace/kb/projects/<name>.md`, most of them
# in historical logs and journals that must not be rewritten.
#
# Run from repo root:  bash tests/check-kb-domain-map-contract.sh
# Exit 0 = contracts intact, exit 1 = at least one consumer lost a rule.

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

# shellcheck source=tests/lib/assert.sh
. tests/lib/assert.sh

failures=0

RESOLUTION=.claude/docs/repo-resolution.md
STALENESS=.claude/docs/kb-staleness.md
ONBOARD=.claude/commands/nase/onboard.md
RESOLVE_SCRIPT=.claude/scripts/kb-domain-resolve.sh
HYGIENE=.claude/scripts/kb-hygiene-scan.py

for f in "$RESOLUTION" "$STALENESS" "$ONBOARD" "$RESOLVE_SCRIPT" "$HYGIENE"; do
  if [ ! -f "$f" ]; then
    fail "missing required file: $f"
    printf '\n%d failure(s)\n' "$failures" >&2
    exit 1
  fi
done

# Body of one Markdown section: from its heading to the next heading at the same
# level or shallower. Fenced code blocks are skipped, because these docs carry
# snippets whose `#` comments would otherwise read as headings and truncate the
# section before the line under test.
section() {
  local file="$1" heading="$2"
  awk -v want="$heading" '
    /^```/ { fence = !fence; if (inside) print; next }
    fence { if (inside) print; next }
    /^#+ / {
      line = $0
      sub(/^#+[[:space:]]*/, "", line)
      n = index($0, " ") - 1
      if (inside && n <= level) exit
      if (line == want) { inside = 1; level = n; next }
    }
    inside { print }
  ' "$file"
}

assert_section_contains() {
  local name="$1" file="$2" heading="$3" pattern="$4" body
  body=$(section "$file" "$heading")
  if [ -z "$body" ]; then
    fail "$name (section '$heading' not found in $file)"
    return
  fi
  if printf '%s\n' "$body" | grep -Fq -- "$pattern"; then
    pass "$name"
  else
    fail "$name"
  fi
}

# --- 1. repo-resolution.md owns the field definition ------------------------

assert_section_contains \
  "repo-resolution defines the retired field" \
  "$RESOLUTION" "Retired entries" "[retired:YYYY-MM-DD]"

assert_section_contains \
  "retired entries stay resolvable for readers" \
  "$RESOLUTION" "Retired entries" "kb-domain-resolve.sh"

assert_section_contains \
  "retired is documented as distinct from deleting the KB file" \
  "$RESOLUTION" "Retired entries" "Retiring is not deleting"

assert_section_contains \
  "Part 1 checks the marker before prompting for a local path" \
  "$RESOLUTION" "Part 1: Repo Resolution" "retired:"

# The marker check must come before the AskUserQuestion fallback, otherwise the
# prompt fires first and the check is dead code.
# `|| true` on both: `set -e` aborts the whole gate on a failed command substitution,
# so a missing marker would exit silently instead of reporting the assertion below.
retired_line=$(grep -n 'retired:' "$RESOLUTION" | head -1 | cut -d: -f1 || true)
askq_line=$(grep -n 'AskUserQuestion to ask the user for the local path' "$RESOLUTION" | head -1 | cut -d: -f1 || true)
if [ -n "$retired_line" ] && [ -n "$askq_line" ] && [ "$retired_line" -lt "$askq_line" ]; then
  pass "retired check precedes the AskUserQuestion fallback"
else
  fail "retired check must appear before the AskUserQuestion local-path fallback"
fi

# --- 2. kb-staleness.md exempts retired entries from aging ------------------

assert_section_contains \
  "staleness Step B knows about retired entries" \
  "$STALENESS" "Step B — Classify each file" "retired:"

assert_section_contains \
  "staleness Step B carries a Retired tier row" \
  "$STALENESS" "Step B — Classify each file" "| Retired |"

assert_section_contains \
  "staleness Step B points at the field's owning doc" \
  "$STALENESS" "Step B — Classify each file" "repo-resolution.md"

# --- 3. onboard.md excludes retired repos from batch refresh ----------------

assert_section_contains \
  "onboard Mode excludes retired repos from batch refresh" \
  "$ONBOARD" "Mode" "retired:"

assert_section_contains \
  "onboard --force does not un-retire an entry" \
  "$ONBOARD" "Mode" "un-retire"

assert_contains \
  "onboard reports a separate retired count" \
  "$ONBOARD" "refreshed/skipped/retired/failed"

# --- 4. the existing parsers still ignore trailing fields -------------------

# Both parsers must read only the path token. If either starts consuming the
# rest of the line, a `[retired:...]` field would corrupt the resolved path.
assert_cmd \
  "kb-domain-resolve.sh still takes only the first token after the arrow" \
  grep -Fq "awk '{print \$1}'" "$RESOLVE_SCRIPT"

# End-to-end: a domain map carrying the field must still resolve to the bare path.
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/kb-retired-XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/workspace/kb/projects" "$tmpdir/.claude/scripts"
cp "$RESOLVE_SCRIPT" "$tmpdir/.claude/scripts/"
cat > "$tmpdir/workspace/kb/.domain-map.md" <<'MAP'
# Domain Map

## Projects
- gone → workspace/kb/projects/gone.md [last-updated:2026-08-25] [retired:2026-08-25] (upstream archived)
MAP
: > "$tmpdir/workspace/kb/projects/gone.md"

resolved=$(cd "$tmpdir" && bash .claude/scripts/kb-domain-resolve.sh gone 2>/dev/null || true)
if [ "$resolved" = "workspace/kb/projects/gone.md" ]; then
  pass "a retired entry still resolves to its bare KB path"
else
  fail "retired entry resolved to '$resolved', expected 'workspace/kb/projects/gone.md'"
fi

# The hygiene scan's target parser must also survive the extra field.
#
# The probe body goes to a file first. A heredoc opened inside a command substitution
# parses on bash 3.2 and is a syntax error on the CI runner's bash, which aborts the
# whole gate with exit 2 - so the shape passed locally and took this file down in CI.
# `check-effort-pointer-integrity.sh` avoids the same trap the same way.
cat > "$tmpdir/probe.py" <<'PY'
import importlib.util, os, pathlib, sys
spec = importlib.util.spec_from_file_location(
    "hygiene", pathlib.Path(os.environ["HYGIENE_ABS"])
)
mod = importlib.util.module_from_spec(spec)
sys.modules["hygiene"] = mod
spec.loader.exec_module(mod)
print(sorted(mod.domain_map_targets(pathlib.Path("."))))
PY

hygiene_out=$(cd "$tmpdir" && HYGIENE_ABS="$ROOT/$HYGIENE" python3 probe.py 2>/dev/null || true)
if printf '%s' "$hygiene_out" | grep -Fq "workspace/kb/projects/gone.md"; then
  pass "kb-hygiene-scan domain_map_targets ignores the trailing retired field"
else
  fail "kb-hygiene-scan domain_map_targets mis-parsed a retired entry: $hygiene_out"
fi

# --- 5. project groups are a routing label, not a location -----------------

assert_section_contains \
  "repo-resolution defines the project-group heading shape" \
  "$RESOLUTION" "Project groups" "### <group>"

assert_section_contains \
  "groups are documented as a label, not a path" \
  "$RESOLUTION" "Project groups" "routing label, not a location"

assert_section_contains \
  "group membership is exclusive" \
  "$RESOLUTION" "Project groups" "exactly one group"

assert_section_contains \
  "grouping does not gate reads" \
  "$RESOLUTION" "Project groups" "regardless of"

assert_section_contains \
  "onboard accepts a group scope" \
  "$ONBOARD" "Mode" '`--group <name>`: scope the batch'

assert_section_contains \
  "onboard offers the groups interactively when none is given" \
  "$ONBOARD" "Mode" "AskUserQuestion"

assert_section_contains \
  "an unknown group is an error, not a silent full run" \
  "$ONBOARD" "Mode" "never a silent full run"

assert_contains \
  "onboard names the untouched groups in its summary" \
  "$ONBOARD" "groups left untouched"

# A scoped refresh must not quietly become a scoped review.
assert_section_contains \
  "group scope narrows repos, not gates" \
  "$ONBOARD" "Mode" "never narrows the gates"

# End-to-end: every Projects entry in the live map sits under exactly one group.
MAP=workspace/kb/.domain-map.md
if [ -f "$MAP" ]; then
  ungrouped=$(awk '
    /^## Projects/ { in_projects = 1; group = ""; next }
    /^## / { in_projects = 0 }
    !in_projects { next }
    /^### / { group = $0; next }
    /^- [A-Za-z0-9._-]+ / {
      if (group == "") print $2
    }
  ' "$MAP")
  if [ -z "$ungrouped" ]; then
    pass "every Projects entry in the live map sits under a group heading"
  else
    fail "ungrouped Projects entries in $MAP: $(printf '%s' "$ungrouped" | tr '\n' ' ')"
  fi
else
  printf 'SKIP  live domain map not present (%s)\n' "$MAP"
fi

if [ "$failures" -eq 0 ]; then
  printf '\nAll KB domain-map contract assertions passed.\n'
  exit 0
fi

printf '\n%d failure(s)\n' "$failures" >&2
exit 1
