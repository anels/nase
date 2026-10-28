#!/usr/bin/env bash
# Run local validation gates that mirror CI (`.github/workflows/validate.yml`).
#
# Run from repo root:
#   bash tests/check-all.sh            # full gate, includes local lychee when present
#   bash tests/check-all.sh --fast
#   bash tests/check-all.sh --changed
#   bash tests/check-all.sh --evals
#   bash tests/check-all.sh --links    # internal links only
#   bash tests/check-all.sh --online-links   # include external links (network)
#   bash tests/check-all.sh --list
#
# NASE_TEST_TIMEOUT overrides the per-test cap in seconds (default 600).
# Exit 0 = all gates pass, exit N = N failed gates.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

MODE="${1:---full}"
case "$MODE" in
  --full|--fast|--changed|--evals|--links|--online-links|--list) ;;
  -h|--help)
    cat <<'EOF'
Usage: bash tests/check-all.sh [--full|--fast|--changed|--evals|--links|--online-links|--list]

Modes:
  --full     Default full validation gate, including local lychee when installed.
  --fast     Fast syntax/catalog/doctrine/subagent/core-script gate.
  --changed  Fast gate plus path-targeted regression tests for changed files.
  --evals    PR review eval schema/scorer tests only.
  --links    Local lychee markdown link check; skips with warning when missing.
  --online-links  Lychee check including external URLs (needs network).
  --list     Print available modes and major gate groups.
EOF
    exit 0
    ;;
  *)
    printf 'ERROR: unknown mode: %s\n' "$MODE" >&2
    printf 'Run: bash tests/check-all.sh --help\n' >&2
    exit 2
    ;;
esac

failed=0
current_section=""
failures=()
# Test files already run in this invocation. `--changed` is `run_fast; run_changed_extras`,
# and FAST_SCRIPT_TESTS is a subset of SCRIPT_TESTS, so without this the 18 fast files ran
# twice - each one incrementing `failed` and adding its own summary row, so a single broken
# file exited 2.
ran_test_files=()

# Test files are the wall clock: 80+ of them, every one building its own fixtures under
# its own mktemp root, none touching repo state. They are subprocess-spawn bound rather
# than CPU bound, so the useful width is higher than the core count. Override with
# NASE_TEST_JOBS=1 to get a serial run back when debugging an interleaved failure.
if [[ -n "${NASE_TEST_JOBS:-}" ]]; then
  TEST_JOBS="$NASE_TEST_JOBS"
else
  TEST_JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
  [[ "$TEST_JOBS" =~ ^[0-9]+$ ]] || TEST_JOBS=4
  # Twice the core count, because these tests spend most of their time waiting on
  # subprocess startup rather than computing. Measured on a 14-core machine over the 66
  # script tests: width 1 = 470s, 4 = 263s, 8 = 211s, 14 = 208s, 24 = 177s. The knee is
  # around 8 and core-count leaves ~15% on the table.
  TEST_JOBS=$((TEST_JOBS * 2))
fi
# Validate and cap AFTER the branch, so an override is held to the same bounds the
# computed value is: `NASE_TEST_JOBS=1000` used to fan out to 1000 processes, and a
# non-numeric one used to reach the arithmetic below as a silent 0.
[[ "$TEST_JOBS" =~ ^[0-9]+$ ]] || TEST_JOBS=1
# Force base 10 before any arithmetic: a zero-padded value like `08` passes the regex but
# `(( ))` reads it as octal, errors with "value too great for base", and evaluates false -
# which silently disables the cap and the throttle both.
TEST_JOBS=$((10#$TEST_JOBS))
(( TEST_JOBS > 32 )) && TEST_JOBS=32
(( TEST_JOBS < 1 )) && TEST_JOBS=1

SHELLCHECK_BIN=$(command -v shellcheck 2>/dev/null || true)
SHELLCHECK_SKIP='SKIP: shellcheck is not installed locally; GitHub Actions still runs this gate.'
ACTIONLINT_BIN=$(command -v actionlint 2>/dev/null || true)
ACTIONLINT_SKIP='SKIP: actionlint is not installed locally; GitHub Actions still runs this gate.'
RUFF_BIN=$(command -v ruff 2>/dev/null || true)
RUFF_SKIP='SKIP: ruff is not installed locally (pip install ruff); GitHub Actions still runs this gate.'
VERMIN_BIN=$(command -v vermin 2>/dev/null || true)
VERMIN_SKIP='SKIP: vermin is not installed locally (pip install vermin); GitHub Actions still runs this gate.'

# Per-test wall-clock cap. A hung fixture used to block the whole batch forever
# (CI only stops at GitHub's 6-hour job limit). `python3` is the timeout carrier
# because macOS ships no `timeout(1)`; the alarm survives exec, so the test keeps
# its own PID and receives SIGALRM normally.
TEST_TIMEOUT_SECONDS=${NASE_TEST_TIMEOUT:-600}
case "$TEST_TIMEOUT_SECONDS" in
  ''|*[!0-9]*) TEST_TIMEOUT_SECONDS=600 ;;
esac
(( TEST_TIMEOUT_SECONDS < 1 )) && TEST_TIMEOUT_SECONDS=600
TIMEOUT_PY=$(command -v python3 2>/dev/null || true)

run_with_timeout() {
  local seconds="$1"
  shift
  if [[ -n "$TIMEOUT_PY" ]]; then
    "$TIMEOUT_PY" -c '
import os
import signal
import sys

signal.alarm(int(sys.argv[1]))
os.execvp(sys.argv[2], sys.argv[2:])
' "$seconds" "$@"
  else
    "$@"
  fi
}

# Every tracked shell file. `bash -n` and shellcheck read the same list so a new
# script cannot land in one gate and miss the other.
SHELL_FILES=()
for _shell_file in .claude/hooks/*.sh .claude/lib/*.sh .claude/scripts/*.sh tests/*.sh tests/hooks/*.sh \
  tests/lib/*.sh tests/scripts/*.sh workspace/skills/scripts/*.sh; do
  [[ -f "$_shell_file" ]] && SHELL_FILES+=("$_shell_file")
done
unset _shell_file

HOOK_TESTS=(tests/hooks/test-*.sh)
SCRIPT_TESTS=(tests/scripts/test-*.sh workspace/skills/scripts/test-*.sh)

FAST_SCRIPT_TESTS=(
  tests/scripts/test-help-summary.sh
  tests/scripts/test-local-parallel-subagents.sh
  tests/scripts/test-cli-tooling-integration.sh
  tests/scripts/test-github-actions-hardening.sh
  tests/scripts/test-pr-github-helper.sh
  tests/scripts/test-statusline-context.sh
  tests/scripts/test-fsd-preflight.sh
  tests/scripts/test-fsd-review-gate.sh
  tests/scripts/test-pr-review-eval.sh
  tests/scripts/test-skill-eval-run.sh
  tests/scripts/test-nase-json.sh
  tests/scripts/test-voice-profile-routing.sh
  tests/scripts/test-shared-workflow-extraction.sh
  tests/scripts/test-command-skill-size-budget.sh
  tests/scripts/test-skill-usage-report.sh
  tests/scripts/test-workspace-write-guard.sh
  tests/scripts/test-skill-overlap.sh
  tests/scripts/test-canonical-pointers.sh
  tests/scripts/test-boundary-terms.sh
  tests/scripts/test-shared-doc-refs.sh
)

section() {
  current_section="$1"
  printf '\n=== %s ===\n' "$current_section"
}

format_command() {
  local out="" part
  for part in "$@"; do
    printf -v part '%q' "$part"
    out+="${part} "
  done
  printf '%s' "${out% }"
}

# Sole writer of `failed` and `failures`, so the summary table cannot drift from the
# `[pass]`/`[fail]` lines. Callers that ran the command themselves (the parallel replay
# below) pass the rc and duration they recorded; `$@` after them is the rerun command.
record_gate_result() {
  local gate="$1" rc="$2" duration="$3"
  shift 3
  if [[ "$rc" -eq 0 ]]; then
    printf '[pass] %s (%ss)\n' "$gate" "$duration"
    return 0
  fi
  printf '[fail] %s (exit %s, %ss)\n' "$gate" "$rc" "$duration" >&2
  failures+=("${current_section}|${gate}|${rc}|${duration}s|$(format_command "$@")")
  failed=$((failed + 1))
  return 0
}

run_gate() {
  local gate="$1"
  shift
  local start end rc
  start=$(date +%s)
  printf '[gate] %s\n' "$gate"
  "$@"
  rc=$?
  end=$(date +%s)
  record_gate_result "$gate" "$rc" "$((end - start))" "$@"
}

already_ran_test_file() {
  local candidate="$1" seen
  for seen in "${ran_test_files[@]+"${ran_test_files[@]}"}"; do
    [[ "$seen" == "$candidate" ]] && return 0
  done
  return 1
}

run_test_files_serially() {
  local test_file start end rc
  for test_file in "$@"; do
    start=$(date +%s)
    printf '[gate] %s\n' "$(basename "$test_file")"
    run_with_timeout "$TEST_TIMEOUT_SECONDS" bash "$test_file"
    rc=$?
    end=$(date +%s)
    if [ "$rc" -eq 142 ]; then
      printf '[timeout] %s exceeded %ss (NASE_TEST_TIMEOUT)\n' \
        "$(basename "$test_file")" "$TEST_TIMEOUT_SECONDS" >&2
    fi
    # Record the plain rerun command, not `run_with_timeout ...`: that helper is a
    # function in this shell and would not resolve in the copied command.
    record_gate_result "$(basename "$test_file")" "$rc" "$((end - start))" \
      bash "$test_file"
  done
}

# Run independent test files concurrently, then replay their results in the order they
# were listed. Reporting order is the input order, never completion order, so a failure
# table stays diffable across runs. Each job's stdout+stderr is buffered to its own file
# and flushed whole, so two tests cannot interleave lines.
#
# `failures+=` cannot run in a job: a background subshell gets a copy of the array and
# the parent never sees the append. Jobs write an rc file instead and the parent does the
# accounting, which is also what keeps `failed` accurate.
run_test_files() {
  local test_file absent=() present=() run_dir gate
  local idx=0 pids=() rc duration skipped_optional=0
  for test_file in "$@"; do
    if [[ ! -f "$test_file" ]]; then
      case "$test_file" in
        workspace/skills/scripts/*)
          printf '[skip] optional workspace skill test missing: %s\n' "$test_file"
          skipped_optional=$((skipped_optional + 1))
          continue
          ;;
      esac
      absent+=("$test_file")
      continue
    fi
    already_ran_test_file "$test_file" && continue
    ran_test_files+=("$test_file")
    present+=("$test_file")
  done

  # A missing non-optional test is a gate failure in its own right; keep that serial and
  # first so the reason is the first thing on screen.
  for test_file in "${absent[@]+"${absent[@]}"}"; do
    run_gate "$(basename "$test_file")" test -f "$test_file"
  done

  # `workspace/` is git-ignored, so its skills and tests never reach a clean CI
  # checkout. Say that out loud instead of letting a silent skip read as coverage.
  if (( skipped_optional > 0 )); then
    printf '[warn] %s optional workspace test(s) skipped; workspace/ is local-only, so CI cannot cover them.\n' \
      "$skipped_optional" >&2
  fi

  (( ${#present[@]} == 0 )) && return 0

  if (( TEST_JOBS <= 1 )); then
    run_test_files_serially "${present[@]}"
    return 0
  fi

  # Falling back to serial rather than `return 1`: a bare return would skip the whole
  # batch without incrementing `failed` or printing a `[fail]`, so a tmpdir problem would
  # read as "these tests passed".
  if ! run_dir=$(mktemp -d "${TMPDIR:-/tmp}/nase-check-all-XXXXXXXX"); then
    printf '[warn] mktemp -d failed; running %s test file(s) serially\n' "${#present[@]}" >&2
    run_test_files_serially "${present[@]}"
    return 0
  fi
  # Results replay only after `wait`, so without this a hung test is total silence with no
  # clue which file. Name the batch up front.
  printf '[batch] %s test file(s) at width %s\n' "${#present[@]}" "$TEST_JOBS"
  for test_file in "${present[@]}"; do
    # Sliding window on explicit PIDs. `wait -n` would be the natural throttle, but it
    # landed in bash 4.3 and macOS still ships 3.2, where it exits 2 with "invalid
    # option" - the loop then busy-spins on `jobs -rp`, forking twice per iteration and
    # stealing the CPU the tests are supposed to be using. Blocking on the oldest PID
    # costs some head-of-line latency and never spins.
    if (( ${#pids[@]} >= TEST_JOBS )); then
      wait "${pids[0]}" 2>/dev/null || true
      pids=("${pids[@]:1}")
    fi
    {
      local start end job_rc
      start=$(date +%s)
      run_with_timeout "$TEST_TIMEOUT_SECONDS" bash "$test_file" \
        >"$run_dir/$idx.out" 2>&1
      # Capture before anything else runs: `$?` after the `date` below is date's status,
      # which would report every failing test as a pass.
      job_rc=$?
      end=$(date +%s)
      printf '%s %s\n' "$job_rc" "$((end - start))" >"$run_dir/$idx.rc"
    } &
    pids+=("$!")
    idx=$((idx + 1))
  done
  wait

  idx=0
  for test_file in "${present[@]}"; do
    gate=$(basename "$test_file")
    read -r rc duration 2>/dev/null < "$run_dir/$idx.rc" || { rc=1; duration=0; }
    printf '[gate] %s\n' "$gate"
    if [ "$rc" -eq 142 ]; then
      printf '[timeout] %s exceeded %ss (NASE_TEST_TIMEOUT)\n' "$gate" "$TEST_TIMEOUT_SECONDS" >&2
    fi
    cat "$run_dir/$idx.out" 2>/dev/null
    record_gate_result "$gate" "$rc" "$duration" bash "$test_file"
    idx=$((idx + 1))
  done
  # Explicit, not a RETURN trap: a trap set inside a function is not function-scoped, so
  # it also fires when unrelated functions return, where `run_dir` is out of scope and
  # `set -u` kills the run mid-gate. An interrupted run leaves the dir behind; that is
  # the cheaper problem.
  rm -rf "$run_dir"
}

list_modes() {
  cat <<'EOF'
Modes:
  --full
  --fast
  --changed
  --evals
  --links
  --online-links

Major gate groups:
  syntax: bash hooks/scripts, Python helpers, settings JSON
  lint: ruff over Python, vermin for the 3.10 floor, shellcheck over every shell file, actionlint - each when installed
  catalog: command_catalog.py --check-readme
  wiring: hook registrations and workspace validation
  docs: shared-doc reference integrity, canonical pointer wording, KB domain-map contract, skill doctrine, and advisory skill trigger overlap
  regressions: hook tests and script tests
  links: lychee markdown link check (part of --full when lychee is installed)
EOF
}

check_bash_syntax() {
  local f rc=0
  for f in "${SHELL_FILES[@]}"; do
    if ! bash -n "$f"; then
      printf 'rerun: bash -n %q\n' "$f" >&2
      rc=1
    fi
  done
  return "$rc"
}

run_bash_syntax() {
  section "bash syntax"
  # One gate over the whole list rather than one per file: 105 gate lines cost more to
  # read than they inform. `bash -n` names the offending file on failure, and the helper
  # echoes a copy-pasteable rerun for it, because the summary's Rerun column can only
  # show `check_bash_syntax` - a shell function the reader cannot invoke.
  run_gate "bash -n ${#SHELL_FILES[@]} shell file(s)" check_bash_syntax
}

run_python_syntax() {
  section "python syntax"
  local py_files=(.claude/scripts/*.py)
  local f
  for f in workspace/skills/scripts/*.py; do
    [[ -f "$f" ]] && py_files+=("$f")
  done
  run_gate "compile .claude/scripts/*.py workspace/skills/scripts/*.py" python3 -m py_compile "${py_files[@]}"
}

run_ruff() {
  section "python lint"
  if [[ -z "$RUFF_BIN" ]]; then
    printf '%s\n' "$RUFF_SKIP"
    return 0
  fi
  run_gate "ruff check" "$RUFF_BIN" check --no-cache .
  # `.ruff.toml` excludes `workspace/` wholesale because it is scratch space, but the
  # skill scripts under it are skill surface with their own tests. Pass them by name -
  # an explicit path is linted despite the exclude - so a Python skill script is held
  # to the same gate as the shell twins already in SHELL_FILES.
  local skill_py=() f
  for f in workspace/skills/scripts/*.py; do
    [[ -f "$f" ]] && skill_py+=("$f")
  done
  if [[ "${#skill_py[@]}" -gt 0 ]]; then
    run_gate "ruff check ${#skill_py[@]} workspace skill script(s)" \
      "$RUFF_BIN" check --no-cache "${skill_py[@]}"
  fi
}

run_python_floor() {
  section "python version floor"
  if [[ -z "$VERMIN_BIN" ]]; then
    printf '%s\n' "$VERMIN_SKIP"
    return 0
  fi
  # CLAUDE.md documents python3 3.10+. ruff's `target-version` cannot see a stdlib API
  # that is missing on 3.10 (`hashlib.file_digest`, `datetime.UTC`), so a 3.11-only call
  # would pass every other gate here and fail on the first 3.10 machine.
  run_gate "vermin --target=3.10- over shipped Python" \
    "$VERMIN_BIN" --target=3.10- --violations --no-tips .claude/scripts tests/lib
}

run_json() {
  section "JSON"
  run_gate "settings.json parses" bash -c 'python3 -m json.tool .claude/settings.json >/dev/null'
  run_gate ".mcp.json parses when present" bash -c '
    f=.mcp.json
    [ ! -f "$f" ] || python3 -m json.tool "$f" >/dev/null
  '
  # settings.local.json is git-ignored and hand-edited; a syntax error there can
  # silently disable or change hook behavior without touching a tracked file.
  run_gate "settings.local.json parses when present" bash -c '
    f=.claude/settings.local.json
    [ ! -f "$f" ] || python3 -m json.tool "$f" >/dev/null
  '
}

# Shared by the full gate and the `--changed` gate so the flags and the SKIP line cannot drift.
shellcheck_files() {
  local label="$1"
  shift
  if [[ -n "$SHELLCHECK_BIN" ]]; then
    run_gate "shellcheck $# $label shell file(s)" "$SHELLCHECK_BIN" -S warning "$@"
  else
    printf '%s\n' "$SHELLCHECK_SKIP"
  fi
}

run_shellcheck_scripts() {
  section "shellcheck (all shell)"
  shellcheck_files all "${SHELL_FILES[@]}"
}

# `--changed` runs run_fast, which skips the whole-tree shellcheck, so a changed shell file
# was never linted until CI. Lint just those, drawn from SHELL_FILES so the file set matches
# the full gate exactly.
run_shellcheck_changed() {
  local changed="$1" f changed_sh=()
  while IFS= read -r f; do
    changed_sh+=("$f")
  done < <(printf '%s\n' "${SHELL_FILES[@]}" | grep -xFf <(printf '%s\n' "$changed") || true)
  [[ "${#changed_sh[@]}" -gt 0 ]] || return 0
  section "shellcheck (changed shell)"
  shellcheck_files changed "${changed_sh[@]}"
}

run_actionlint() {
  section "GitHub Actions lint"
  if [[ -z "$ACTIONLINT_BIN" ]]; then
    printf '%s\n' "$ACTIONLINT_SKIP"
    return 0
  fi
  local workflow_files=() f
  for f in .github/workflows/*.yml .github/workflows/*.yaml; do
    [[ -f "$f" ]] && workflow_files+=("$f")
  done
  if [[ "${#workflow_files[@]}" -gt 0 ]]; then
    run_gate "actionlint workflows" "$ACTIONLINT_BIN" "${workflow_files[@]}"
  fi
}

check_hook_wiring() {
  local f name missing=0
  for f in .claude/hooks/*.sh; do
    name=$(basename "$f" .sh)
    if ! grep -q "${name}.sh" .claude/settings.json; then
      printf 'FAIL: %s.sh not wired in settings.json\n' "$name" >&2
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]]
}

run_hook_wiring() {
  section "hook wiring"
  run_gate "hook scripts wired in settings.json" check_hook_wiring
}

run_command_catalog() {
  section "command catalog"
  run_gate "README matches command frontmatter" python3 .claude/scripts/command_catalog.py --root . --check-readme
  run_gate "catalog JSON renders" bash -c 'python3 .claude/scripts/command_catalog.py --root . --format json >/dev/null'
}

check_skill_bash_blocks() {
  local f blocks err sc skill_fail=0
  for f in .claude/commands/nase/*.md; do
    blocks=$(awk '/```bash/{p=1;next} /```/{p=0} p' "$f")
    [[ -z "$blocks" ]] && continue
    if ! err=$(printf '%s\n' "$blocks" | bash -n 2>&1); then
      printf 'FAIL: invalid bash syntax in %s: %s\n' "$f" "$err" >&2
      skill_fail=1
    fi
    if [[ -n "$SHELLCHECK_BIN" ]]; then
      # Snippet-only suppressions, passed here rather than in a repo-root
      # .shellcheckrc so they cannot reach a real script.
      # SC2148 no shebang, SC2154/SC2034 `{repo}`-style placeholders, SC1091 illustrative
      # `source` paths, SC2016 single-quoted `$var` in jq filters, SC2260/SC2261
      # `<owner>/<repo>` reading as a redirection.
      if ! sc=$(printf '%s\n' "$blocks" | "$SHELLCHECK_BIN" --shell=bash -S error \
        -e SC2148,SC2154,SC1091,SC2034,SC2016,SC2260,SC2261 - 2>&1); then
        printf 'FAIL: shellcheck errors in %s:\n%s\n' "$f" "$sc" >&2
        skill_fail=1
      fi
    fi
  done
  if [[ -z "$SHELLCHECK_BIN" ]]; then
    printf '%s\n' "$SHELLCHECK_SKIP"
  fi
  [[ "$skill_fail" -eq 0 ]]
}

run_skill_bash_blocks() {
  section "skill bash syntax + shellcheck"
  run_gate "bash fenced blocks in commands" check_skill_bash_blocks
}

check_doc_bash_blocks() {
  local f blocks err doc_bash_fail=0
  for f in .claude/docs/*.md; do
    blocks=$(awk '/```bash/{p=1;next} /```/{p=0} p' "$f")
    [[ -z "$blocks" ]] && continue
    if ! err=$(printf '%s\n' "$blocks" | bash -n 2>&1); then
      printf 'FAIL: invalid bash syntax in %s: %s\n' "$f" "$err" >&2
      doc_bash_fail=1
    fi
  done
  [[ "$doc_bash_fail" -eq 0 ]]
}

run_shared_doc_bash_blocks() {
  section "shared-doc bash syntax"
  run_gate "bash fenced blocks in shared docs" check_doc_bash_blocks
}

run_hook_tests() {
  section "hook regression tests"
  run_test_files "${HOOK_TESTS[@]}"
}

run_workspace_validation() {
  section "workspace validation"
  run_gate "validate-workspace.sh" bash .claude/scripts/validate-workspace.sh
}

run_local_sensitive_scan() {
  section "local sensitive artifact scan"
  run_gate "check-local-sensitive-artifacts.sh" bash tests/check-local-sensitive-artifacts.sh
}

run_boundary_terms() {
  section "workspace boundary terms"
  run_gate "check-boundary-terms.sh" bash tests/check-boundary-terms.sh
}

run_script_tests() {
  section "script regression tests"
  run_test_files "${SCRIPT_TESTS[@]}"
}

run_fast_script_tests() {
  section "core script regression tests"
  run_test_files "${FAST_SCRIPT_TESTS[@]}"
}

run_shared_doc_refs() {
  section "shared-doc reference integrity"
  run_gate "check-shared-doc-refs.sh" bash tests/check-shared-doc-refs.sh
}

run_canonical_pointers() {
  section "canonical shared-doc pointers"
  run_gate "check-canonical-pointers.sh" bash tests/check-canonical-pointers.sh
}

run_review_gate_optionality() {
  section "FSD review-gate optionality contract"
  run_gate "check-review-gate-optionality.sh" bash tests/check-review-gate-optionality.sh
}

run_kb_domain_map_contract() {
  section "KB domain-map contract"
  run_gate "check-kb-domain-map-contract.sh" bash tests/check-kb-domain-map-contract.sh
}

run_effort_pointer_integrity() {
  section "effort pointer integrity"
  run_gate "check-effort-pointer-integrity.sh" bash tests/check-effort-pointer-integrity.sh
}

run_skill_doctrine() {
  section "skill doctrine"
  run_gate "check-skill-doctrine.sh" bash tests/check-skill-doctrine.sh
}

run_skill_overlap() {
  section "skill trigger overlap"
  run_gate "check-skill-overlap.sh" bash tests/check-skill-overlap.sh
}

run_evals() {
  section "skill evals"
  run_gate "test-pr-review-eval.sh" bash tests/scripts/test-pr-review-eval.sh
  run_gate "test-skill-eval-run.sh" bash tests/scripts/test-skill-eval-run.sh
}

# Shared by --links and --online-links: the exclude list must stay identical to
# the lychee step in .github/workflows/validate.yml, so it lives in one place.
# tests/fixtures is excluded because fixtures are deliberately malformed inputs,
# not documentation.
run_lychee() {
  local gate="$1" section_name="$2"
  shift 2
  section "$section_name"
  if ! command -v lychee >/dev/null 2>&1; then
    printf 'WARN: lychee not installed locally; skipping %s.\n' "$gate"
    return 0
  fi
  run_gate "$gate" lychee --no-progress --include-fragments "$@" \
    --exclude-path workspace \
    --exclude-path .omc \
    --exclude-path node_modules \
    --exclude-path tests/fixtures \
    './**/*.md' \
    '.claude/**/*.md'
}

run_links() {
  run_lychee "lychee offline markdown links" "markdown internal-link check" --offline
}

run_links_online() {
  # PR CI stays offline on purpose: private Atlassian/GitHub links 401 from a
  # fork, and link rot is not a merge blocker. This opt-in run is how a human
  # audits external links without forcing that noise onto every PR.
  run_lychee "lychee online markdown links" "markdown external-link check" \
    --max-retries 2 --timeout 20
}

collect_changed_files() {
  local default_branch base_ref
  default_branch=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)
  if [[ -z "$default_branch" ]]; then
    default_branch=$(git remote show origin 2>/dev/null | awk '/HEAD branch:/ {print $NF; exit}' || true)
  fi
  default_branch=${default_branch:-main}
  base_ref="origin/$default_branch"

  {
    git diff --name-only 2>/dev/null || true
    git diff --cached --name-only 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null || true
    if git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
      git diff --name-only "$base_ref"...HEAD 2>/dev/null || true
    fi
  } | sort -u
}

run_changed_extras() {
  local changed
  changed=$(collect_changed_files)
  section "changed-path routing"
  if [[ -z "$changed" ]]; then
    printf 'No changed files detected after fast gate.\n'
    return 0
  fi
  printf '%s\n' "$changed" | sed 's/^/[changed] /'

  # tests/lib/ for the same reason as the scripts branch below: 3 hook tests source
  # tests/lib/assert.sh.
  # settings.json is what the hook tests assert wiring and guard registration against.
  if grep -qE '^(\.claude/hooks/|\.claude/lib/|\.claude/settings\.json$|tests/hooks/|tests/lib/)' <<< "$changed"; then
    run_hook_tests
  fi
  # tests/lib/ is in this list because 18 script tests source tests/lib/assert.sh: editing
  # the shared assertion helper changes what every one of them checks, and without this
  # it triggered no test run at all.
  # Script tests also read the prose and config the scripts consume: command and doc files
  # (skill-safety-boundaries, terminology-discovery, jev-judge, slack-draft-templates,
  # trace-role, workspace-quality-scan), roles.yaml (roles-schema), the workflows
  # (github-actions-hardening), and the `tests/check-*.sh` gates that tests probe directly.
  # An edit to only those files used to trigger none of them.
  if grep -qE '^(\.claude/scripts/|\.claude/commands/|\.claude/docs/|\.claude/roles\.yaml$|\.github/workflows/|tests/scripts/|tests/lib/|tests/check-[^/]*\.sh$|workspace/skills/scripts/)' <<< "$changed"; then
    run_script_tests
  fi
  run_shellcheck_changed "$changed"
  if grep -qE '^\.claude/commands/nase/[^/]+\.md$' <<< "$changed"; then
    run_skill_bash_blocks
  fi
  if grep -qE '^(\.claude/commands/nase/[^/]+\.md|workspace/skills/[^/]+\.md|tests/check-skill-overlap\.sh)$' <<< "$changed"; then
    run_skill_overlap
  fi
  if grep -qE '^\.claude/docs/[^/]+\.md$' <<< "$changed"; then
    run_shared_doc_bash_blocks
  fi
  if grep -qE '^(\.claude/docs/(repo-resolution|kb-staleness)\.md|\.claude/commands/nase/onboard\.md|\.claude/scripts/(kb-domain-resolve\.sh|kb-hygiene-scan\.py)|tests/check-kb-domain-map-contract\.sh)$' <<< "$changed"; then
    run_kb_domain_map_contract
  fi
  if grep -qE '^(\.claude/commands/nase/[^/]+\.md|workspace/skills/[^/]+\.md|\.claude/docs/language-config\.md|\.claude/scripts/check-canonical-pointers\.py|tests/check-canonical-pointers\.sh)$' <<< "$changed"; then
    run_canonical_pointers
  fi
  if grep -qE '^(\.claude/scripts/check-effort-pointer-integrity\.py|tests/check-effort-pointer-integrity\.sh|\.claude/docs/effort-(lifecycle|model|drift|transitions)\.md|\.claude/commands/nase/kb-review\.md)$' <<< "$changed"; then
    run_effort_pointer_integrity
  fi
  if grep -qE '^(evals/(pr-review|core-workflows)/|\.claude/scripts/(pr-review-eval|skill-eval-run)\.py|tests/scripts/test-(pr-review-eval|skill-eval-run)\.sh)' <<< "$changed"; then
    run_evals
  fi

  # No separate "changed test files" pass. Every shape a changed test file can take
  # already triggers a routing branch above that runs the whole set containing it:
  # `tests/hooks/test-*.sh` matches the hooks branch, and both `tests/scripts/test-*.sh`
  # and `workspace/skills/scripts/test-*.sh` match the scripts branch, whose
  # run_script_tests globs both directories (SCRIPT_TESTS). `ran_test_files` is what keeps
  # any overlap - including FAST_SCRIPT_TESTS, which run_fast already executed - from
  # running a second time and double-counting its failure.
}

run_fast() {
  run_bash_syntax
  run_python_syntax
  run_ruff
  run_python_floor
  run_json
  run_actionlint
  run_hook_wiring
  run_command_catalog
  run_boundary_terms
  run_shared_doc_refs
  run_canonical_pointers
  run_review_gate_optionality
  run_kb_domain_map_contract
  run_effort_pointer_integrity
  run_skill_doctrine
  run_skill_overlap
  run_fast_script_tests
}

run_full() {
  run_bash_syntax
  run_python_syntax
  run_ruff
  run_python_floor
  run_json
  run_shellcheck_scripts
  run_actionlint
  run_hook_wiring
  run_command_catalog
  run_skill_bash_blocks
  run_shared_doc_bash_blocks
  run_hook_tests
  run_workspace_validation
  run_local_sensitive_scan
  run_boundary_terms
  run_script_tests
  run_shared_doc_refs
  run_canonical_pointers
  run_review_gate_optionality
  run_kb_domain_map_contract
  run_effort_pointer_integrity
  run_skill_doctrine
  run_skill_overlap
  run_links
}

print_summary() {
  local row section_name gate exit_code duration rerun
  if [[ "$failed" -eq 0 ]]; then
    printf '\nAll gates passed.\n'
    return 0
  fi

  printf '\n%d gate(s) failed.\n' "$failed" >&2
  printf '\n| Section | Gate | Exit | Duration | Rerun |\n' >&2
  printf '|---|---|---:|---:|---|\n' >&2
  # Reached only when failed > 0, and record_gate_result is the only writer of either,
  # incrementing `failed` and appending a row together, so the array is non-empty here.
  # The `+` guard is belt-and-braces for bash 3.2 (what macOS ships), where "${arr[@]}"
  # on an EMPTY array trips `set -u`.
  for row in "${failures[@]+"${failures[@]}"}"; do
    IFS='|' read -r section_name gate exit_code duration rerun <<< "$row"
    printf '| %s | %s | %s | %s | `%s` |\n' "$section_name" "$gate" "$exit_code" "$duration" "$rerun" >&2
  done
}

# tests/scripts/test-check-all-routing.sh sources this file for its functions only.
if [[ -n "${NASE_CHECK_ALL_SOURCE_ONLY:-}" ]]; then
  return 0
fi

if [[ "$MODE" == "--list" ]]; then
  list_modes
  exit 0
fi

case "$MODE" in
  --full) run_full ;;
  --fast) run_fast ;;
  --changed) run_fast; run_changed_extras ;;
  --evals) run_evals ;;
  --links) run_links ;;
  --online-links) run_links_online ;;
esac

print_summary
exit "$failed"
