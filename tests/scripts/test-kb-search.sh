#!/usr/bin/env bash
# Regression tests for .claude/scripts/kb-search.sh.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/kb-search.sh"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/workspace/kb/general"
cat > "$FIXTURE/workspace/kb/general/search.md" <<'EOF'
# Search fixture

### 2026-05-01 Literal bracket search
**Tags:** [P1], shell
**Confidence:** high
literal [ value in body.

### 2026-05-02 C++ literal search
**Tags:** language
**Confidence:** high
C++ and .NET should be searched as literal text.

### 2026-05-03 Dash literal search
**Tags:** shell
**Confidence:** high
--literal should be searched as an exact literal, not interpreted as a grep option.

### 2026-05-04 Long token budget search
**Tags:** token-budget
**Confidence:** high
longtoken line 01
longtoken line 02
longtoken line 03
longtoken line 04
longtoken line 05
longtoken line 06
longtoken line 07
longtoken line 08
longtoken line 09
longtoken line 10
longtoken line 11
longtoken line 12
longtoken line 13
longtoken line 14
longtoken line 15
longtoken line 16
longtoken line 17
longtoken line 18
longtoken line 19
longtoken line 20
longtoken line 21
longtoken line 22
longtoken line 23
longtoken line 24
longtoken line 25
longtoken line 26
longtoken line 27
longtoken line 28
longtoken line 29
longtoken line 30

## Folder-Scope Enforcement

Current-state folder contract.

#### Nested implementation detail

folderScopeToken is required by the current contract.
EOF

cd "$FIXTURE" || exit 1
export NASE_ROOT="$FIXTURE"
export CLAUDE_CODE_SESSION_ID="kb-search-test"

pass=0
fail=0

assert_exit() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    pass=$((pass + 1))
    printf 'PASS  %s (exit=%s)\n' "$desc" "$actual"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s (expected exit=%s, got %s)\n' "$desc" "$expected" "$actual" >&2
  fi
}

assert_contains() {
  local desc="$1" actual="$2" needle="$3"
  if grep -qF -- "$needle" <<< "$actual"; then
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n  expected to contain: %s\n  actual: %s\n' "$desc" "$needle" "$actual" >&2
  fi
}

assert_not_contains() {
  local desc="$1" actual="$2" needle="$3"
  if grep -qF -- "$needle" <<< "$actual"; then
    fail=$((fail + 1))
    printf 'FAIL  %s\n  expected NOT to contain: %s\n  actual: %s\n' "$desc" "$needle" "$actual" >&2
  else
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$desc"
  fi
}

out=$(bash "$SCRIPT" "[" 2>&1)
rc=$?
assert_exit "T1: literal bracket query succeeds" 0 "$rc"
assert_contains "T1: literal bracket entry found" "$out" "Literal bracket search"
assert_not_contains "T1: no grep regex error" "$out" "grep:"

out=$(bash "$SCRIPT" "literal" "tag:[P1]" 2>&1)
rc=$?
assert_exit "T2: literal tag filter succeeds" 0 "$rc"
assert_contains "T2: tag-filtered entry found" "$out" "Literal bracket search"
assert_not_contains "T2: no grep regex error" "$out" "grep:"

out=$(bash "$SCRIPT" "C++" 2>&1)
rc=$?
assert_exit "T3: literal plus query succeeds" 0 "$rc"
assert_contains "T3: C++ entry found" "$out" "C++ literal search"
assert_not_contains "T3: no grep regex error" "$out" "grep:"

out=$(bash "$SCRIPT" --with-score "literal" 2>&1)
rc=$?
assert_exit "T4: score output succeeds" 0 "$rc"
assert_contains "T4: score is exposed" "$out" "**Score:** 3"
assert_contains "T4: scored entry found" "$out" "Literal bracket search"

out=$(bash "$SCRIPT" "--literal" 2>&1)
rc=$?
assert_exit "T5: dash-prefixed literal query succeeds" 0 "$rc"
assert_contains "T5: dash-prefixed entry found" "$out" "Dash literal search"
assert_not_contains "T5: exact dash query does not fall back" "$out" "partial match"

out=$(bash "$SCRIPT" "longtoken" "--max-entry-lines" 8 2>&1)
rc=$?
assert_exit "T6: long entries are capped by default" 0 "$rc"
assert_contains "T6: cap marker is shown" "$out" "rerun with --full"
assert_not_contains "T6: capped output omits tail" "$out" "longtoken line 30"

out=$(bash "$SCRIPT" "longtoken" "--full" 2>&1)
rc=$?
assert_exit "T7: --full preserves complete entry output" 0 "$rc"
assert_contains "T7: full output includes tail" "$out" "longtoken line 30"

ledger="$FIXTURE/workspace/stats/kb-usage.jsonl"
ledger_body=$(cat "$ledger" 2>/dev/null || true)
assert_contains "T8: search-result telemetry is appended" "$ledger_body" '"access":"search-result"'
assert_contains "T8: telemetry records result file only" "$ledger_body" '"file":"workspace/kb/general/search.md"'
assert_not_contains "T8: telemetry does not log raw query text" "$ledger_body" '"query"'
assert_not_contains "T8: telemetry does not include searched term" "$ledger_body" 'longtoken'

out=$(bash "$SCRIPT" "Folder-Scope Enforcement" 2>&1)
rc=$?
assert_exit "T9: level-two current-state heading succeeds" 0 "$rc"
assert_contains "T9: level-two current-state heading is returned" "$out" "## Folder-Scope Enforcement"
assert_not_contains "T9: exact level-two heading does not fall back" "$out" "partial match"

out=$(bash "$SCRIPT" "folderScopeToken" 2>&1)
rc=$?
assert_exit "T10: nested level-four content succeeds" 0 "$rc"
assert_contains "T10: nested content returns its parent current-state section" "$out" "## Folder-Scope Enforcement"
assert_contains "T10: nested content remains in the returned section" "$out" "folderScopeToken is required"

# T11: one KB file that answers the query in several sections must return each of
# them, and repeated hits inside one section must still collapse to one result.
cat > "$FIXTURE/workspace/kb/general/multi.md" <<'EOF'
# Multi-section fixture

### 2026-06-01 First multihit section
**Tags:** dedup
**Confidence:** high
multihit appears here.
multihit appears again in the same section.

### 2026-06-02 Second multihit section
**Tags:** dedup
**Confidence:** high
multihit appears in a different section.
EOF

out=$(bash "$SCRIPT" "multihit" --with-score 2>&1)
rc=$?
assert_exit "T11: multi-section query succeeds" 0 "$rc"
assert_contains "T11: first matching section is returned" "$out" "First multihit section"
assert_contains "T11: second matching section is returned" "$out" "Second multihit section"
assert_contains "T11: both sections counted once each" "$out" "2 result(s)"

# ── T12: several mentions: paths are swept once and rendered per path ────────
out=$(bash "$SCRIPT" mentions:folderScopeToken mentions:longtoken mentions:zzzz-absent 2>&1)
rc=$?
assert_exit "T12: multi-path sweep succeeds when any path has hits" 0 "$rc"
assert_contains "T12: first path gets its own section" "$out" '## KB Search'
assert_contains "T12: absent path is reported, not omitted" "$out" 'mentions:zzzz-absent'
assert_contains "T12: absent path says no results" "$out" 'no results'
if [ "$(printf '%s\n' "$out" | grep -c '^## KB Search')" = "3" ]; then
  pass=$((pass + 1))
  printf 'PASS  %s\n' "T12: one section per path"
else
  fail=$((fail + 1))
  printf 'FAIL  %s\n' "T12: one section per path" >&2
fi
# The fuzzy fallback is global by design: it fires only when the whole sweep found
# nothing, so a path with no hits alongside a path that has them gets no fallback.
# Per-path fallback would cost an extra sweep for every path with no mentions.
assert_not_contains "T12: no fuzzy fallback when a sibling path had hits" "$out" 'partial match'

# A separate query plus several paths would mean "contains all of them", which no caller
# asks for, so it is refused rather than guessed at.
out=$(bash "$SCRIPT" longtoken mentions:a mentions:b 2>&1)
rc=$?
assert_exit "T12: a query plus several paths is refused" 1 "$rc"
assert_contains "T12: the refusal says what to do" "$out" 'drop the separate query'
rm -f "$FIXTURE/workspace/kb/general/multi.md"

# With several paths and no exact hit, the fuzzy fallback would split the joined paths into
# words and print an entry that mentions three of them under no `mentions:` header.
cat > "$FIXTURE/workspace/kb/general/fuzzy-multi.md" <<'EOF'
# Fuzzy multi-path fixture

### 2026-05-20 Alpha parser notes
**Tags:** parser
**Confidence:** high
The alpha module hands its tokens to the parser stage.
EOF
out=$(bash "$SCRIPT" mentions:alpha-module mentions:parser-nothing mentions:gammaz 2>&1)
rc=$?
assert_exit "T12: several paths with no exact hit report nothing found" 2 "$rc"
assert_not_contains "T12: no fuzzy fallback across several paths" "$out" 'partial match'
assert_not_contains "T12: no entry is printed under a mentions: header" "$out" 'Alpha parser notes'
# A single path keeps its fuzzy fallback, so the same words still find the entry.
out=$(bash "$SCRIPT" mentions:alpha-module-parser-nothing 2>&1)
rc=$?
assert_exit "T12: a single path still falls back to fuzzy" 0 "$rc"
assert_contains "T12: a single path reports partial matches" "$out" 'partial match'
rm -f "$FIXTURE/workspace/kb/general/fuzzy-multi.md"

# T13: `high` is the unwritten default, so confidence:high matches an entry with no field
# and confidence:medium does not.
cat > "$FIXTURE/workspace/kb/general/confidence.md" <<'EOF'
# Confidence fixture

### 2026-06-03 Default confidence entry
**Tags:** confidence
defaultconf has no Confidence field.

### 2026-06-04 Medium confidence entry
**Tags:** confidence
**Confidence:** medium
defaultconf is only medium here.

### 2026-06-05 Outside-colon medium entry
**Tags:** confidence
**Confidence**: medium (spelled with the colon outside the bold)
defaultconf is medium in the other spelling.

### 2026-06-06 Flow medium entry
**Tags:** confidence
**Confidence:** medium for the onboarding-flow narrative
defaultconf is medium, and its note contains the word flow.
EOF

out=$(bash "$SCRIPT" "defaultconf" confidence:high 2>&1)
assert_contains "T13: confidence:high matches an entry with no Confidence field" "$out" "Default confidence entry"
assert_not_contains "T13: confidence:high skips a medium entry" "$out" "Medium confidence entry"
assert_not_contains "T13: confidence:high skips a **Confidence**: medium entry" "$out" "Outside-colon medium entry"
out=$(bash "$SCRIPT" "defaultconf" confidence:medium 2>&1)
assert_not_contains "T13: confidence:medium skips the default entry" "$out" "Default confidence entry"
assert_contains "T13: confidence:medium finds the **Confidence**: spelling" "$out" "Outside-colon medium entry"
out=$(bash "$SCRIPT" "defaultconf" confidence:low 2>&1)
assert_not_contains "T13: confidence:low does not match low inside flow" "$out" "Flow medium entry"

# ── T14: a short plain word matches as a whole word, longer words stay substrings ──
mkdir -p "$FIXTURE/workspace/kb/projects"
cat > "$FIXTURE/workspace/kb/projects/short-term.md" <<'EOF'
# Short term fixture

### 2026-06-07 Outbound NAT gateway
Outbound traffic leaves through the NAT gateway.

### 2026-06-08 Alternative native rollout
The alternative rollout is native and international.

### 2026-06-09 Folders layout
The shortfolders layout keeps two folders.
EOF

out=$(bash "$SCRIPT" "NAT" 2>&1)
assert_contains "T14: short word finds the whole-word entry" "$out" "Outbound NAT gateway"
assert_not_contains "T14: short word skips alternative/native/international" "$out" "Alternative native rollout"
out=$(bash "$SCRIPT" "NAT" in:projects --with-score 2>&1)
assert_contains "T14: NAT still counts as one result" "$out" "1 result(s)"
out=$(bash "$SCRIPT" "folder" 2>&1)
assert_contains "T14: a long word still matches inside folders" "$out" "Folders layout"
out=$(bash "$SCRIPT" "C++" 2>&1)
assert_contains "T14: punctuated terms stay substring matches" "$out" "C++ literal search"

# ── T15: a truncated result names where the hits sit ──────────────────────────
mkdir -p "$FIXTURE/workspace/kb/ops"
for i in 01 02 03 04 05 06 07 08; do
  printf '# Spread %s\n\n### 2026-07-%s Spread entry\nspreadtoken lives here.\n' "$i" "$i" \
    > "$FIXTURE/workspace/kb/projects/spread-$i.md"
done
for i in 01 02 03; do
  printf '# Ops spread %s\n\n### 2026-07-%s Ops spread entry\nspreadtoken lives here too.\n' "$i" "$i" \
    > "$FIXTURE/workspace/kb/ops/spread-$i.md"
done
out=$(bash "$SCRIPT" "spreadtoken" 2>&1)
assert_contains "T15: truncation notice is kept" "$out" "Showing the top 10 of 11"
assert_contains "T15: hit distribution names the areas" "$out" "Hits by area (narrow with in:<area>): projects 8, ops 3"
out=$(bash "$SCRIPT" "spreadtoken" in:ops 2>&1)
assert_not_contains "T15: no distribution when the area is already filtered" "$out" "Hits by area"
out=$(bash "$SCRIPT" "longtoken" 2>&1)
assert_not_contains "T15: no distribution when nothing was truncated" "$out" "Hits by area"

# ── T17: a short word still finds its plural and its snake_case form ────────
cat > "$FIXTURE/workspace/kb/projects/boundary.md" <<'EOF'
# Boundary fixture

### 2026-08-10 Plural form
The suite runs many tests in parallel.

### 2026-08-11 Snake case form
Set the env_var before the run.
EOF

out=$(bash "$SCRIPT" "test" 2>&1)
assert_contains "T17: test finds tests" "$out" "Plural form"
out=$(bash "$SCRIPT" "env" 2>&1)
assert_contains "T17: env finds env_var" "$out" "Snake case form"

# ── T18: the area hint only names areas that in: accepts ─────────────────────
mkdir -p "$FIXTURE/workspace/kb/terminology"
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
  printf '# Term %s\n\n### 2026-09-%s Term entry\nareatoken lives here.\n' "$i" "$i" \
    > "$FIXTURE/workspace/kb/terminology/area-$i.md"
done
out=$(bash "$SCRIPT" "areatoken" 2>&1)
assert_contains "T18: a directory in: rejects is reported as other" "$out" "Hits by area (narrow with in:<area>): other 12"
assert_not_contains "T18: terminology is not offered as a filter" "$out" "terminology 12"

# ── T16: the fuzzy fallback needs two of the words, and ignores tiny ones ────
cat > "$FIXTURE/workspace/kb/projects/fuzzy.md" <<'EOF'
# Fuzzy fixture

### 2026-08-01 Dropbox storage design
Dropbox stores blocks in a content-addressed layout.

### 2026-08-02 Dropbox billing
Dropbox invoices arrive monthly.

### 2026-08-03 Storage layout for blocks
The storage layout groups blocks by hash.
EOF

out=$(bash "$SCRIPT" "dropbox storage nomatchword" 2>&1)
assert_contains "T16: fuzzy fallback is still announced" "$out" "partial match"
assert_contains "T16: entry holding two query words is kept" "$out" "Dropbox storage design"
assert_not_contains "T16: entry holding one query word is dropped" "$out" "Dropbox billing"
out=$(bash "$SCRIPT" "ai dropbox storage zzmiss" 2>&1)
assert_contains "T16: two-letter word does not stop a real match" "$out" "Dropbox storage design"
out=$(bash "$SCRIPT" "dropbox zzmissone zzmisstwo" 2>&1)
rc=$?
assert_exit "T16: one matching word of three finds nothing" 2 "$rc"
out=$(bash "$SCRIPT" "dropbox storage design zzmiss" 2>&1)
assert_contains "T16: four words keep an entry that holds three" "$out" "Dropbox storage design"
out=$(bash "$SCRIPT" "dropbox storage hash zzmiss" 2>&1)
rc=$?
assert_exit "T16: four words drop entries that hold only two" 2 "$rc"

cat > "$FIXTURE/workspace/kb/general/fenced.md" <<'EOF'
# Fenced fixture

### 2026-09-01 Fenced install steps
**Tags:** fencegotcha
**Confidence:** high
Run the installer.

```bash
# install step
make fencedtoken
```

~~~
## tilde fenced comment
~~~

Tail line fencedtail.
EOF

out=$(bash "$SCRIPT" "fencedtoken" "tag:fencegotcha" 2>&1)
rc=$?
assert_exit "T17: shell comment in a fence does not hide the tag" 0 "$rc"
assert_contains "T17: entry keeps its real heading" "$out" "Fenced install steps"
out=$(bash "$SCRIPT" "fencedtail" "tag:fencegotcha" 2>&1)
rc=$?
assert_exit "T17: text after a tilde fence stays in the real section" 0 "$rc"
assert_contains "T17: entry after tilde fence keeps its heading" "$out" "Fenced install steps"
out=$(bash "$SCRIPT" "fencedtoken" "since:2026-09-01" 2>&1)
rc=$?
assert_exit "T17: since filter still sees the real date" 0 "$rc"

# CRLF file: the closing fence is "```\r" and must still close, or every later heading is swallowed.
printf '# CRLF fixture\r\n\r\n### 2026-09-02 First crlf entry\r\n**Tags:** crlfone\r\n**Confidence:** high\r\n\r\n```bash\r\n# crlf comment\r\nmake crlftoken\r\n```\r\n\r\n### 2026-09-03 Second crlf entry\r\n**Tags:** crlftwo\r\n**Confidence:** high\r\nBody crlfsecond.\r\n' \
  > "$FIXTURE/workspace/kb/general/crlf-fenced.md"
out=$(bash "$SCRIPT" "crlfsecond" "tag:crlftwo" 2>&1)
rc=$?
assert_exit "T17: CRLF closing fence keeps the next entry separate" 0 "$rc"
assert_contains "T17: entry after a CRLF fence keeps its own heading" "$out" "Second crlf entry"

# ── T19: since: reads every dated heading shape, undated entries stay ────────
cat > "$FIXTURE/workspace/kb/general/dated-shapes.md" <<'EOF'
# Dated shapes fixture

### 2026-03-04 Old level-three entry
shapetoken old three.

### 2026-10-04 New level-three entry
shapetoken new three.

## 2026-03-01 Old level-two entry
shapetoken old two.

## 2026-10-01 New level-two entry
shapetoken new two.

## Old trailing paren (2026-03-02)
shapetoken old paren.

## New trailing paren (2026-10-02)
shapetoken new paren.

## Ad hoc - 2026-03-03
shapetoken old adhoc.

## Ad hoc - 2026-10-03
shapetoken new adhoc.

## Undated current-state section
shapetoken undated.

## Delta since 2026-01-01
shapetoken since heading is not an entry date.
EOF

out=$(bash "$SCRIPT" "shapetoken" "since:2026-09-01" 2>&1)
assert_contains "T19: a new level-two dated entry survives since" "$out" "New level-two entry"
assert_contains "T19: a new trailing-paren date survives since" "$out" "New trailing paren"
assert_contains "T19: a new dash-dated heading survives since" "$out" "new adhoc"
assert_contains "T19: a new level-three entry survives since" "$out" "New level-three entry"
assert_not_contains "T19: an old level-two entry is filtered" "$out" "Old level-two entry"
assert_not_contains "T19: an old trailing-paren entry is filtered" "$out" "Old trailing paren"
assert_not_contains "T19: an old dash-dated entry is filtered" "$out" "old adhoc"
assert_not_contains "T19: an old level-three entry is filtered" "$out" "Old level-three entry"
assert_contains "T19: an undated section is kept as before" "$out" "Undated current-state section"
assert_contains "T19: a since heading is not read as an entry date" "$out" "since heading is not an entry date"

total=$((pass + fail))
printf '\n%d/%d assertions passed\n' "$pass" "$total"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
