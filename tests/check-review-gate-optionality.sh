#!/usr/bin/env bash
# Verify the FSD candidate-review gate's optionality contract stays coherent.
#
# Phase 6.4 yields on one terminal state and only one: a reviewer that cannot
# return a usable result sets `review_outcome = not-run` and the run continues.
# `blocked-evidence` and `NEEDS_HUMAN` still stop. Two couplings make that safe,
# and both are easy to break from a distance:
#
#   1. The gate routes the reviewer through `roles.yaml -> verifier` and relies
#      on that role's tool whitelist for its read-only guarantee. Adding Edit or
#      Write to `verifier` would silently turn a whitelisted read-only reviewer
#      into one that is read-only by instruction alone.
#   2. Skipping the gate is only acceptable while it stays loud. If a disclosure
#      point loses its `review_outcome` instruction, or `closure_state: done`
#      stops excluding a skipped review, the skip becomes invisible and
#      "reviewed" quietly degrades into "assumed fine" across a series of PRs.
#
# Assertions anchor on identifiers and the section they must appear in, not on
# the doc's prose, so rewording a paragraph does not fail this gate.
#
# Run from repo root:  bash tests/check-review-gate-optionality.sh
# Exit 0 = contract intact, exit 1 = at least one coupling broke.

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

# shellcheck source=tests/lib/assert.sh
. tests/lib/assert.sh

failures=0

GATES=.claude/docs/fsd-delivery-gates.md
FSD=.claude/commands/nase/fsd.md
ROLES=.claude/roles.yaml

for f in "$GATES" "$FSD" "$ROLES"; do
  if [ ! -f "$f" ]; then
    fail "missing required file: $f"
    printf '\n%d failure(s)\n' "$failures" >&2
    exit 1
  fi
done

# Body of one Markdown section: from its heading to the next heading at the
# same level or shallower. Fenced code blocks are skipped, because these docs
# carry shell snippets whose `#` comments would otherwise read as headings and
# truncate the section before the line under test.
section() {
  awk -v want="$2" '
    /^```/ { fenced = !fenced }
    !fenced && /^#+ / {
      depth = index($0, " ") - 1
      if (inside && depth <= want_depth) inside = 0
      if ($0 == want) { inside = 1; want_depth = depth; next }
    }
    inside { print }
  ' "$1"
}

assert_section_contains() {
  local name="$1" file="$2" heading="$3" pattern="$4"
  if section "$file" "$heading" | grep -Fq -- "$pattern"; then
    pass "$name"
  else
    fail "$name"
  fi
}

# --- 1. The yielding state exists and is named consistently -----------------

assert_contains "gates doc defines the not-run outcome" \
  "$GATES" 'review_outcome = not-run'

assert_contains "gates doc has the When the review did not run section" \
  "$GATES" '### When the review did not run'

assert_contains "fsd entrypoint carries review_outcome in the 6.4 state contract" \
  "$FSD" 'review_outcome'

# --- 2. Only the infrastructure state yields ---------------------------------

assert_section_contains "blocked-evidence still stops" \
  "$GATES" '## Phase 6.4: Candidate Review' 'blocked-evidence` still stops'

assert_section_contains "NEEDS_HUMAN still stops" \
  "$GATES" '## Phase 6.4: Candidate Review' 'NEEDS_HUMAN` still stops'

# The old wording made every terminal state interrupt. If it comes back, the
# entrypoint and the gates doc disagree about who stops the run.
if grep -Fq 'terminal infrastructure/evidence states interrupt' "$FSD"; then
  fail "fsd entrypoint still claims terminal infrastructure states interrupt the user"
else
  pass "fsd entrypoint no longer treats infrastructure states as interrupts"
fi

# --- 3. Phase 7 has something to bind when no review approved a tree ---------

assert_contains "Phase 7 names the fallback tree binding" \
  "$FSD" 'tested_candidate_tree_oid'

assert_section_contains "gates doc names the Phase 7 fallback binding" \
  "$GATES" '### When the review did not run' 'tested_candidate_tree_oid'

# --- 4. A skipped review cannot be reported as done --------------------------

assert_section_contains "closure_state derivation excludes a skipped review" \
  "$GATES" '## Phase 10: Report' 'review_outcome = not-run'

# --- 5. The skip is disclosed on both surfaces a reader arrives from ---------
# The PR body is the only one its reviewer can see; the Phase 10 report is the
# only one the operator sees. Losing either makes the skip invisible to someone.

assert_section_contains "Phase 8 discloses a skipped review in the PR body" \
  "$GATES" '## Phase 8: Pull Request (if PR = Yes)' 'review_outcome = not-run'

# --- 6. The reviewer role is named, and is still read-only -------------------

assert_section_contains "gates doc routes the reviewer through the verifier role" \
  "$GATES" '### Run the reviewer' '`verifier` role in `.claude/roles.yaml`'

# The gate's read-only guarantee is the verifier role's whitelist. Parse that
# role's own tools list rather than grepping the whole file, so an Edit/Write
# entry under some other role cannot mask a real regression here.
if python3 - "$ROLES" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r"^  verifier:\n((?:    .*\n|\n)*)", text, re.M)
if not match:
    print("verifier role not found in roles.yaml", file=sys.stderr)
    sys.exit(1)
body = match.group(1)
tools = re.search(r"^    tools:\s*\[([^\]]*)\]", body, re.M)
if not tools:
    print("verifier role declares no tools list", file=sys.stderr)
    sys.exit(1)
declared = {t.strip() for t in tools.group(1).split(",") if t.strip()}
forbidden = declared & {"Edit", "Write", "NotebookEdit", "MultiEdit"}
if forbidden:
    print(
        "verifier role grants write tools %s, so the review gate's read-only "
        "guarantee is instruction-only" % sorted(forbidden),
        file=sys.stderr,
    )
    sys.exit(1)
PY
then
  pass "verifier role is read-only by tool whitelist"
else
  fail "verifier role no longer guarantees read-only review"
fi

# --- 7. The empty-turn cause is documented -----------------------------------
# Two runs were lost to an agent that accepts a review spawn and returns
# nothing. Keep the diagnosis in the doc so the retry budget is not spent on it
# again.

assert_contains "gates doc warns that an empty turn is often agent selection" \
  "$GATES" 'empty turn'

if [ "$failures" -gt 0 ]; then
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi

printf '\nreview-gate optionality contract intact\n'
