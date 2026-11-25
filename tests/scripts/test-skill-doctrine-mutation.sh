#!/usr/bin/env bash
# Mutation test for tests/check-skill-doctrine.sh.
#
# A doctrine rule that cannot fail is documentation with a green tick. For a sample of the
# highest-churn rules this copies the tree into a scratch directory, seeds exactly one
# violation, and requires the gate to exit non-zero with a FAIL inside that rule's own
# section. The pristine copy must pass, so a mutation can never "fail" because the base was
# already red.
#
# It also pins the workspace-skill rule from tests/lib/workspace-skip.sh: with
# workspace/skills/ absent the workspace-only assertions skip and say how many; with it
# present, a missing named skill file fails instead of skipping.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

failures=0
source "$ROOT/tests/lib/assert.sh"

# Everything the gate and the two workspace-skill tests read.
BASE="$SCRATCH/base"
mkdir -p "$BASE"
cp -R "$ROOT/.claude" "$ROOT/docs" "$ROOT/tests" "$ROOT/CLAUDE.md" "$ROOT/README.md" "$BASE/"
[[ -d "$BASE/tests/fixtures" ]] && rm -rf "$BASE/tests/fixtures"

strip_ansi() { LC_ALL=C sed $'s/\033\\[[0-9;]*m//g'; }

# The gate prints `--- D<n>: ... ---` before each rule. Print the body of one section.
section_of() {
  local rule="$1" file="$2"
  awk -v head="--- ${rule}: " 'index($0, head) == 1 { p = 1; next } /^--- / { p = 0 } p' "$file"
}

fresh() {
  WORK="$SCRATCH/work-$1"
  rm -rf "$WORK"
  cp -R "$BASE" "$WORK"
}

run_gate() {
  local tag="$1"
  GATE_RC=0
  (cd "$WORK" && bash tests/check-skill-doctrine.sh) >"$SCRATCH/$tag.raw" 2>&1 || GATE_RC=$?
  strip_ansi <"$SCRATCH/$tag.raw" >"$SCRATCH/$tag.out"
}

append_line() { printf '\n%s\n' "$2" >>"$WORK/$1"; }

# replace_first FILE OLD NEW - fails loudly when OLD is absent, so a stale mutation is a
# harness failure, not a silent no-op that lets the gate "pass".
replace_first() {
  python3 -c '
import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if old not in text:
    sys.exit("mutation target not found: " + old)
open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
' "$WORK/$1" "$2" "$3"
}

# expect_rule_fails NAME RULE - run the gate on $WORK and check RULE's section FAILs.
expect_rule_fails() {
  local name="$1" rule="$2" tag section
  tag=$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '_')
  run_gate "$tag"
  section=$(section_of "$rule" "$SCRATCH/$tag.out")
  if [[ "$GATE_RC" -ne 0 ]] && grep -q 'FAIL' <<<"$section"; then
    pass "$rule: $name fails the gate"
  else
    fail "$rule: $name was not caught (rc=$GATE_RC, section: $(tr '\n' ' ' <<<"$section" | cut -c1-160))"
  fi
}

# --- pristine copy ---
fresh pristine
run_gate pristine
if [[ "$GATE_RC" -eq 0 ]] && ! grep -q 'FAIL' "$SCRATCH/pristine.out"; then
  pass "pristine copy passes every doctrine rule"
else
  fail "pristine copy passes every doctrine rule (rc=$GATE_RC): $(grep 'FAIL' "$SCRATCH/pristine.out" | head -3)"
fi

# --- one seeded violation per rule ---
fresh d1
append_line .claude/commands/nase/learn.md 'curl -s -u ":$ADO_PAT" https://dev.azure.com/org/_apis/projects'
expect_rule_fails "curl with an ADO PAT in a command" D1

fresh d5
append_line .claude/docs/plain-writing-guard.md 'Escalate through Codex MCP when the review is slow.'
expect_rule_fails "provider residue in a shared doc" D5

fresh d11
replace_first .claude/docs/kb-gap-detect.md \
  'Auto-write modes only skip human confirmation; they never skip final drift checks.' \
  'Auto-write modes skip confirmation.'
expect_rule_fails "auto-write rule drops its drift-check sentence" D11

fresh d11-gaps
replace_first .claude/commands/nase/kb-review.md \
  'It runs only when the user explicitly asks for it, never from model routing or another command.' \
  'It runs when asked.'
expect_rule_fails "gap mode drops its manual-only rule" D11

fresh d7
replace_first .claude/commands/nase/kb-teamshare.md 'Skip symlinks entirely' 'Follow symlinks'
expect_rule_fails "import mode stops skipping symlinks" D7

fresh d8
replace_first .claude/commands/nase/kb-teamshare.md 'Never copy imported frontmatter blocks wholesale' 'Copy imported frontmatter'
expect_rule_fails "import mode stops sanitizing wrapper frontmatter" D8

fresh d13
append_line .claude/commands/nase/fsd.md 'Write the plan to `workspace/tmp/fsd-{branch}.md`.'
expect_rule_fails "raw branch name in a workspace/tmp path" D13

fresh d15
for marker in 'repo-resolution.md' 'kb-domain-resolve.sh' 'nase-context-kb-researcher' \
  'workspace/kb/.domain-map.md' 'mentions:<path>'; do
  python3 -c '
import sys
path, old = sys.argv[1:3]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(text.replace(old, "REDACTED"))
' "$WORK/.claude/commands/nase/design.md" "$marker"
done
expect_rule_fails "design loses every KB lookup marker" D15

fresh d17
replace_first .claude/commands/nase/learn.md 'description: "' 'description: "中文触发 '
expect_rule_fails "CJK text in a command description" D17

fresh d24
append_line .claude/commands/nase/fsd.md 'Continue at Phase 99 when the build is green.'
expect_rule_fails "cross-reference to a phase with no heading" D24

fresh d25
append_line .claude/docs/plain-writing-guard.md 'Finish with /nase:wrap-up Step 99 before closing.'
expect_rule_fails "cross-reference to a step that does not exist" D25

# --- workspace-skill rule ---
# No workspace/ at all: fresh clone or CI. Skips are counted, never failures.
fresh ws-absent
run_gate ws-absent
if [[ "$GATE_RC" -eq 0 ]] && grep -Eq '^\[warn\] [0-9]+ workspace-only assertions skipped \(workspace/ is local-only\)$' "$SCRATCH/ws-absent.out"; then
  pass "workspace absent: doctrine skips are counted and the gate passes"
else
  fail "workspace absent: doctrine skips are counted and the gate passes (rc=$GATE_RC)"
fi

# workspace/skills exists but the named skill files do not: a rename or deletion, so FAIL.
fresh ws-present
mkdir -p "$WORK/workspace/skills"
expect_rule_fails "workspace/skills exists but deploy-alpha.md is missing" D13
if grep -q 'deploy-alpha.md: missing although workspace/skills/ exists' "$SCRATCH/workspace_skills_exists_but_deploy_alpha_md_is_missing.out"; then
  pass "the failure names the missing skill file"
else
  fail "the failure names the missing skill file"
fi

# The two bash regression tests apply the same rule.
for t in test-skill-safety-boundaries test-workspace-skill-p1-fixes; do
  fresh "$t-absent"
  rc=0
  (cd "$WORK" && bash "tests/scripts/$t.sh") >"$SCRATCH/$t-absent.out" 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]] && grep -Eq '^\[warn\] [0-9]+ workspace-only assertions skipped' "$SCRATCH/$t-absent.out"; then
    pass "$t: workspace absent skips are counted and the test passes"
  else
    fail "$t: workspace absent skips are counted and the test passes (rc=$rc)"
  fi

  fresh "$t-present"
  mkdir -p "$WORK/workspace/skills"
  rc=0
  (cd "$WORK" && bash "tests/scripts/$t.sh") >"$SCRATCH/$t-present.out" 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]] && grep -q 'workspace/skills exists but the file is missing' "$SCRATCH/$t-present.out"; then
    pass "$t: workspace/skills present but a named file missing fails"
  else
    fail "$t: workspace/skills present but a named file missing fails (rc=$rc)"
  fi
done

if [[ "$failures" -ne 0 ]]; then
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi
printf '\nAll skill doctrine mutation tests passed.\n'
