#!/usr/bin/env bash
# Verify the FSD candidate-review gate's never-skipped contract stays coherent.
#
# Phase 6.4 is never skipped. A reviewer that cannot return a usable result sets
# `review_outcome = not-run` and the run STOPS with an error before Phase 7.
# `blocked-evidence` and `NEEDS_HUMAN` stop too. Two couplings make that safe,
# and both are easy to break from a distance:
#
#   1. The gate routes the reviewer through the persisted `nase-verifier` agent
#      and relies on its `tools:` frontmatter for the read-only guarantee. Adding
#      a write or shell tool would silently turn an enforced read-only reviewer
#      into one that is read-only by instruction alone.
#   2. Stopping has to stay loud and final. If Phase 7 regains a fallback tree
#      binding, or `closure_state: done` stops excluding a not-run review, the
#      skip comes back as "reviewed" quietly degrading into "assumed fine".
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

GATES=.claude/docs/fsd-candidate-review.md
CLOSEOUT=.claude/docs/fsd-closeout.md
PR_DELIVERY=.claude/docs/fsd-pr-delivery.md
FSD=.claude/commands/nase/fsd.md
ROLES=.claude/roles.yaml

for f in "$GATES" "$CLOSEOUT" "$PR_DELIVERY" "$FSD" "$ROLES"; do
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
  local name="$1" file="$2" heading="$3" pattern="$4" body
  # Capture, then match in the shell. Piping into `grep -q` under `pipefail` is a
  # race: grep exits on the first match, the producer's next write gets SIGPIPE,
  # and the pipeline reports 141, so a pattern near the top of a long section
  # reads as absent. That flaked in CI while passing locally.
  body=$(section "$file" "$heading")
  if [[ "$body" == *"$pattern"* ]]; then
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

# --- 3. The gate is never skipped, so Phase 7 has no fallback binding --------

assert_section_contains "gates doc states the review gate is never skipped" \
  "$GATES" '## Phase 6.4: Candidate Review' 'The review gate is never skipped'

# A fallback binding is what lets a not-run review reach Phase 7. If it returns,
# the run can ship a tree no independent reviewer saw.
if grep -Fq 'bind `tested_candidate_tree_oid`' "$FSD"; then
  fail "fsd entrypoint binds a fallback tree when the review did not run"
else
  pass "fsd entrypoint has no fallback tree binding for a not-run review"
fi

# --- 4. A not-run review cannot be reported as done --------------------------

assert_section_contains "closure_state derivation excludes a skipped review" \
  "$CLOSEOUT" '## Phase 10: Report' 'review_outcome = not-run'

# --- 5. A not-run review never reaches the PR --------------------------------
# Phase 8 must still name the state and stop, so a resumed run cannot draft a PR
# for a candidate nobody independent has reviewed.

assert_section_contains "Phase 8 stops on a not-run review instead of drafting a PR" \
  "$PR_DELIVERY" '## Phase 8: Pull Request (if PR = Yes)' 'review_outcome = not-run'

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

# The role's tools list is advisory: only a persisted agent's `tools:` frontmatter is an
# enforced whitelist. Each persisted review agent must exist, run in plan mode, and list
# only read tools, so the gate can truthfully report an enforced read-only review.
# mode `subset` allows any non-empty subset of the listed tools; `exact` requires the set.
check_agent_frontmatter() {
  local label="$1" path="$2" name="$3" mode="$4"
  shift 4
  if [ ! -f "$path" ]; then
    fail "persisted $label agent $path is missing"
    return
  fi
  if python3 - "$path" "$name" "$mode" "$@" <<'PY'
import re
import sys

path, name, mode, *allowed = sys.argv[1:]
text = open(path, encoding="utf-8").read()
front = re.match(r"---\n(.*?)\n---\n", text, re.S)
if not front:
    print("%s has no frontmatter" % name, file=sys.stderr)
    sys.exit(1)
fields = dict(re.findall(r"^(\w+):[ \t]*(.*)$", front.group(1), re.M))
if fields.get("name") != name:
    print("agent name is not %s" % name, file=sys.stderr)
    sys.exit(1)
if fields.get("permissionMode") != "plan":
    print("%s does not run in plan mode" % name, file=sys.stderr)
    sys.exit(1)
declared = {t.strip() for t in fields.get("tools", "").split(",") if t.strip()}
if not declared:
    print("%s declares no tools frontmatter" % name, file=sys.stderr)
    sys.exit(1)
if declared - set(allowed):
    print("%s grants non-read tools %s" % (name, sorted(declared - set(allowed))), file=sys.stderr)
    sys.exit(1)
if mode == "exact" and declared != set(allowed):
    print("%s tools must be exactly %s, got %s" % (name, sorted(allowed), sorted(declared)), file=sys.stderr)
    sys.exit(1)
PY
  then
    pass "persisted $label agent is read-only by its tools frontmatter"
  else
    fail "persisted $label agent no longer enforces read-only review"
  fi
}

check_agent_frontmatter verifier .claude/agents/nase-verifier.md nase-verifier subset Read Grep Glob

# --- 6a. The address-comments gates use the persisted agent, not the role ----
# Phase 7.5 and the Step 3d dossier pass gate outward-facing actions. Routing them
# through the prompt-prefix role would make read-only advisory, and a no-verdict
# result must stop the run instead of becoming a user question.
FIX_VERIFY=.claude/docs/pr-review-fix-verification.md
ANALYSIS=.claude/docs/address-comments-analysis.md

for doc in "$FIX_VERIFY" "$ANALYSIS"; do
  assert_contains "$doc spawns the persisted nase-verifier" "$doc" '`nase-verifier`'
  assert_contains "$doc names the agent definition file" "$doc" '.claude/agents/nase-verifier.md'
  if grep -Fq 'role `verifier` per' "$doc"; then
    fail "$doc routes the gate through the advisory verifier role"
  else
    pass "$doc does not route the gate through the advisory verifier role"
  fi
  assert_contains "$doc stops the run with an error on an unusable result" "$doc" 'stop the run with an error'
done
assert_section_contains "Phase 7.5 gate stops instead of asking on a malformed result" \
  "$FIX_VERIFY" '## 9. Review-Thread Resolution Gate' 'stop the run with an error'

# --- 6b. The design naive-reader is persisted, Read-only, and wired in -------
# The comprehension read is only a fresh-reader test if the agent has no way to
# run commands or edit, and only runs if each design mode points at the contract.
READER_DOC=.claude/docs/design-comprehension-reader.md
check_agent_frontmatter reader .claude/agents/nase-comprehension-reader.md \
  nase-comprehension-reader exact Read

assert_contains "reader contract names the persisted agent" \
  "$READER_DOC" '`nase-comprehension-reader`'
assert_contains "interactive design runs the naive-reader check after APPROVED" \
  .claude/commands/nase/design.md 'After APPROVED, run the naive-reader check in `.claude/docs/design-comprehension-reader.md`'
assert_contains "auto design has the naive-reader step" \
  .claude/docs/design-auto-mode.md '### 4e. Naive-reader check'
assert_contains "auto design exits the scoring loop into the naive-reader step" \
  .claude/docs/design-auto-mode.md 'If APPROVED: exit loop → 4e.'
assert_contains "review mode spawns the persisted verifier to score" \
  .claude/docs/design-review-mode.md 'Spawn the persisted `nase-verifier`'

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
