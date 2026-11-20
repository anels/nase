#!/usr/bin/env bash
# Regression tests for .claude/scripts/lessons-lookup.py.
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/lessons-lookup.py"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

# shellcheck source=/dev/null
. "$ROOT/tests/lib/assert.sh"
failures=0

mkdir -p "$FIXTURE/workspace/tasks"
cat >"$FIXTURE/workspace/tasks/lessons.md" <<'EOF'
# Lessons

## workflow -- 2026-11-01 -- Read back a reply before resolving its thread
**When:** address-comments posts a reply through the GitHub API.
**Do:** Compare the posted body with the draft before resolving.

## code -- 2026-11-10 -- Parse the manifest path with sed before cleanup
**When:** A hook reads packages/sdk/src/commands/submit.ts after a rename.
**Do:** Re-read the file at the new path.

## workflow -- 2026-11-15 -- Stage the fix in an earlier call
**When:** A PreToolUse scan reads the index before the command runs.
**Do:** Run git add as its own call.

## calibration -- 2026-11-16 -- address-comments ETA ran long
**When:** address-comments estimate diverged.
**Do:** Pad the estimate.

## style -- 2026-11-17 -- address-comments replies stay short
**When:** address-comments drafts a reply.
**Do:** Keep it to two sentences.

## workflow -- 2026-11-19 -- An address-comments rule already in a doc -> applied to .claude/docs/x.md on 2026-11-20 (archived)

## workflow -- 2026-11-18 -- Split the read-back into its own call
**When:** address-comments hits a guard.
**Do:** Split the read-back into its own call.
EOF

out=$(python3 "$SCRIPT" --root "$FIXTURE" --skill address-comments)
assert_cmd "a skill match prints the header line" grep -q '^\[lessons\] 2 entries match' <<<"$out"
assert_cmd "an entry that names the skill is returned" grep -q 'Read back a reply before resolving' <<<"$out"
assert_cmd "a tie is broken by the newer date" test "$(grep '^## ' <<<"$out" | head -1 | grep -c 'Split the read-back')" = 1
assert_cmd "calibration entries are skipped" bash -c '! grep -q "ETA ran long" <<<"$1"' _ "$out"
assert_cmd "style entries are skipped" bash -c '! grep -q "replies stay short" <<<"$1"' _ "$out"
assert_cmd "an entry already applied to a doc is skipped" bash -c '! grep -q "already in a doc" <<<"$1"' _ "$out"
assert_cmd "an entry that names no term is left out" bash -c '! grep -q "Stage the fix" <<<"$1"' _ "$out"

out=$(python3 "$SCRIPT" --root "$FIXTURE" --path packages/sdk/src/commands/submit.ts)
assert_cmd "a path match returns the entry that names the path" grep -q 'Parse the manifest path' <<<"$out"

out=$(python3 "$SCRIPT" --root "$FIXTURE" --path src/commands/submit.ts)
assert_cmd "a path with no full match falls back to its file name" grep -q 'Parse the manifest path' <<<"$out"

out=$(python3 "$SCRIPT" --root "$FIXTURE" --skill ddress-comm)
assert_cmd "a term inside a longer word does not match" test -z "$out"

out=$(python3 "$SCRIPT" --root "$FIXTURE" --term index)
assert_cmd "a body hit returns the entry" grep -q 'Stage the fix' <<<"$out"

out=$(python3 "$SCRIPT" --root "$FIXTURE" --skill address-comments --limit 1)
assert_cmd "--limit caps the entry count" test "$(grep -c '^## ' <<<"$out")" = 1

out=$(python3 "$SCRIPT" --root "$FIXTURE")
assert_cmd "no terms prints nothing" test -z "$out"

python3 "$SCRIPT" --root "$FIXTURE" --skill zz >/dev/null
assert_cmd "no match exits 0" test "$?" = 0

out=$(python3 "$SCRIPT" --root "$FIXTURE/missing" --skill address-comments)
rc=$?
assert_cmd "a missing lessons file prints nothing" test -z "$out"
assert_cmd "a missing lessons file exits 0" test "$rc" = 0

out=$(python3 "$SCRIPT" --root "$FIXTURE" --term 'a(b[')
assert_cmd "regex characters in a term are matched literally" test -z "$out"

out=$(python3 "$SCRIPT" --root "$FIXTURE" --skill address-comments --limit 0)
assert_cmd "--limit 0 prints nothing" test -z "$out"
out=$(python3 "$SCRIPT" --root "$FIXTURE" --skill address-comments --limit -1)
assert_cmd "a negative --limit prints nothing" test -z "$out"

err=$(python3 "$SCRIPT" --root "$FIXTURE/missing" --skill address-comments 2>&1 >/dev/null)
assert_cmd "a missing lessons file explains itself on stderr" grep -q 'no file at' <<<"$err"

SHAPES=$(mktemp -d)
trap 'rm -rf "$FIXTURE" "$SHAPES"' EXIT
mkdir -p "$SHAPES/workspace/tasks"
cat >"$SHAPES/workspace/tasks/lessons.md" <<'EOF'
## ops -- 2026-11-01 -- Wrapped field for zebra
**When:** zebra grazes
across two lines.
**Do:** Fence it in.

## ops -- 2026-11-02 -- Free text entry for yak

Yak shaving has no labelled fields, so the first line is shown.

## ops -- 2026-11-03 -- Rejected rule for llama -> rejected on 2026-11-04

**When:** llama spits.
**Do:** Ignore this.

## ops -- 2026-11-04 -- Entry that ends at a heading for emu
**When:** emu runs.
### Archive block
**Do:** quokka only appears after the heading.

- 2026-11-05 ops -- bullet entry for ibex that quokka mentions

## ops -- 2026-11-07 -- Fenced sample for gnu
**When:** gnu wanders.
```bash
# a comment inside the fence is not a heading
echo hi
```
**Do:** Tag the gnu.

## ops -- 2026-11-08 -- Rule field for okapi
**When:** okapi sulks.
**Rule:** Feed the okapi.
- list item under the field is not joined

## ops -- 2026-11-09 -- Context before rule for tapir
**Context:** tapir naps.
**Rule:** Wake the tapir.

## ops -- 2026-11-10 -- Colon outside the bold for civet
**When**: civet hides.
**Do**: Find the civet.

## ops -- 2026-11-11 -- Map a -> rejected values handling for dingo
**When:** dingo digs.
**Do:** Keep this one.

## ops -- 2026-11-12 -- Unclosed fence for newt
**When:** newt swims.
```bash
echo unclosed

## ops -- 2026-11-13 -- Later entry for walrus
**When:** walrus basks.

## ops -- 2026-11-06 -- Generic file name lesson
**When:** index.ts needs a change.
**Do:** Check it.
EOF

out=$(python3 "$SCRIPT" --root "$SHAPES" --term zebra)
assert_cmd "a wrapped field is joined into one line" grep -q 'zebra grazes across two lines' <<<"$out"
out=$(python3 "$SCRIPT" --root "$SHAPES" --term yak)
assert_cmd "an entry with no When or Do shows its first body line" grep -q 'Yak shaving has no labelled fields' <<<"$out"
out=$(python3 "$SCRIPT" --root "$SHAPES" --term llama)
assert_cmd "a rejected entry is skipped" test -z "$out"
out=$(python3 "$SCRIPT" --root "$SHAPES" --term quokka)
assert_cmd "text after a heading or a bullet entry is not part of the entry" test -z "$out"
out=$(python3 "$SCRIPT" --root "$SHAPES" --term gnu)
assert_cmd "a hash line inside a code fence does not end the entry" grep -q 'Tag the gnu' <<<"$out"
assert_cmd "a code fence is not joined into the When line" bash -c '! grep -q "bash" <<<"$1"' _ "$out"
out=$(python3 "$SCRIPT" --root "$SHAPES" --term okapi)
assert_cmd "a Rule field stands in for a missing Do" grep -q 'Feed the okapi' <<<"$out"
assert_cmd "a list item is not joined into the field" bash -c '! grep -q "list item" <<<"$1"' _ "$out"
err=$(python3 "$SCRIPT" --root "$SHAPES" --term ab 2>&1 >/dev/null)
assert_cmd "a term that is too short is reported on stderr" grep -q 'no usable term' <<<"$err"
out=$(python3 "$SCRIPT" --root "$SHAPES" --term tapir)
assert_cmd "the rule shows instead of a leading Context field" grep -q 'Wake the tapir' <<<"$out"
out=$(python3 "$SCRIPT" --root "$SHAPES" --term civet)
assert_cmd "a label with the colon outside the bold is a field" grep -q 'Find the civet' <<<"$out"
out=$(python3 "$SCRIPT" --root "$SHAPES" --term dingo)
assert_cmd "a title that merely contains an arrow and rejected is kept" grep -q 'Keep this one' <<<"$out"
out=$(python3 "$SCRIPT" --root "$SHAPES" --term walrus)
assert_cmd "an unclosed fence does not hide the next entry" grep -q 'walrus basks' <<<"$out"
out=$(python3 "$SCRIPT" --root "$SHAPES" --path package.json)
assert_cmd "a generic file name at the repo root does not match" test -z "$out"
mkdir -p "$SHAPES/bom/workspace/tasks"
printf '\xef\xbb\xbf## ops -- 2026-11-14 -- First entry for lynx\n**When:** lynx stalks.\n' >"$SHAPES/bom/workspace/tasks/lessons.md"
out=$(python3 "$SCRIPT" --root "$SHAPES/bom" --term lynx)
assert_cmd "a byte order mark does not hide the first entry" grep -q 'lynx stalks' <<<"$out"
out=$(python3 "$SCRIPT" --root "$SHAPES" --path 'src\foo\index.ts')
assert_cmd "a backslash path is normalised and its generic name still skipped" test -z "$out"
out=$(python3 "$SCRIPT" --root "$SHAPES" --path src/foo/index.ts)
assert_cmd "a generic file name alone does not match" test -z "$out"

[ "$failures" -eq 0 ] && printf '\nlessons-lookup tests passed.\n'
exit "$failures"
