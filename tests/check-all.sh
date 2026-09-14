#!/usr/bin/env bash
# Run local validation gates that mirror CI (`.github/workflows/validate.yml`).
#
# Run from repo root:
#   bash tests/check-all.sh            # full gate, no local lychee
#   bash tests/check-all.sh --fast
#   bash tests/check-all.sh --changed
#   bash tests/check-all.sh --evals
#   bash tests/check-all.sh --links
#   bash tests/check-all.sh --list
#
# Exit 0 = all gates pass, exit N = N failed gates.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

MODE="${1:---full}"
case "$MODE" in
  --full|--fast|--changed|--evals|--links|--list) ;;
  -h|--help)
    cat <<'EOF'
Usage: bash tests/check-all.sh [--full|--fast|--changed|--evals|--links|--list]

Modes:
  --full     Default full validation gate, excluding local lychee.
  --fast     Fast syntax/catalog/doctrine/subagent/core-script gate.
  --changed  Fast gate plus path-targeted regression tests for changed files.
  --evals    PR review eval schema/scorer tests only.
  --links    Local lychee markdown link check; skips with warning when missing.
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

# Test files are the wall clock: 70 of them, every one building its own fixtures under
# its own mktemp root, none touching repo state. They are subprocess-spawn bound rather
# than CPU bound, so the useful width is higher than the core count. Override with
# NASE_TEST_JOBS=1 to get a serial run back when debugging an interleaved failure.
if [[ -n "${NASE_TEST_JOBS:-}" ]]; then
  TEST_JOBS="$NASE_TEST_JOBS"
else
  TEST_JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
  [[ "$TEST_JOBS" =~ ^[0-9]+$ ]] || TEST_JOBS=4
  # Twice the core count, because these tests spend most of their time waiting on
  # subprocess startup rather than computing. Measured on a 14-core machine over the 53
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

# Every tracked shell file. `bash -n` and shellcheck read the same list so a new
# script cannot land in one gate and miss the other.
SHELL_FILES=()
for _shell_file in .claude/hooks/*.sh .claude/scripts/*.sh tests/*.sh tests/hooks/*.sh \
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
  tests/scripts/test-voice-profile-routing.sh
  tests/scripts/test-shared-workflow-extraction.sh
  tests/scripts/test-command-skill-size-budget.sh
  tests/scripts/test-skill-usage-report.sh
  tests/scripts/test-workspace-write-guard.sh
  tests/scripts/test-skill-overlap.sh
  tests/scripts/test-canonical-pointers.sh
  tests/scripts/test-boundary-terms.sh
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
  local test_file
  for test_file in "$@"; do
    run_gate "$(basename "$test_file")" bash "$test_file"
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
  local idx=0 pids=() rc duration
  for test_file in "$@"; do
    if [[ ! -f "$test_file" ]]; then
      case "$test_file" in
        workspace/skills/scripts/*)
          printf '[skip] optional workspace skill test missing: %s\n' "$test_file"
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
      bash "$test_file" >"$run_dir/$idx.out" 2>&1
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

Major gate groups:
  syntax: bash hooks/scripts, Python helpers, settings JSON
  lint: ruff over Python, shellcheck over every shell file, actionlint - each when installed
  catalog: command_catalog.py --check-readme
  wiring: hook registrations and workspace validation
  docs: shared-doc reference integrity, canonical pointer wording, KB domain-map contract, skill doctrine, and advisory skill trigger overlap
  regressions: hook tests and script tests
  links: lychee markdown link check, only in --links
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

run_json() {
  section "JSON"
  run_gate "settings.json parses" bash -c 'python3 -m json.tool .claude/settings.json >/dev/null'
}

run_shellcheck_scripts() {
  section "shellcheck (all shell)"
  if [[ -n "$SHELLCHECK_BIN" ]]; then
    run_gate "shellcheck ${#SHELL_FILES[@]} shell file(s)" \
      "$SHELLCHECK_BIN" -S warning "${SHELL_FILES[@]}"
  else
    printf '%s\n' "$SHELLCHECK_SKIP"
  fi
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

run_links() {
  section "markdown internal-link check"
  if command -v lychee >/dev/null 2>&1; then
    # Keep this exclude list identical to the lychee step in
    # .github/workflows/validate.yml; a divergence means the local gate passes
    # and CI fails. tests/fixtures is excluded because fixtures are deliberately
    # malformed inputs, not documentation.
    run_gate "lychee offline markdown links" lychee --offline --no-progress --include-fragments \
      --exclude-path workspace \
      --exclude-path .omc \
      --exclude-path node_modules \
      --exclude-path tests/fixtures \
      './**/*.md' \
      '.claude/**/*.md'
  else
    printf 'WARN: lychee not installed locally; skipping --links gate.\n'
  fi
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
  if printf '%s\n' "$changed" | grep -qE '^(\.claude/hooks/|tests/hooks/|tests/lib/)'; then
    run_hook_tests
  fi
  # tests/lib/ is in this list because 18 script tests source tests/lib/assert.sh: editing
  # the shared assertion helper changes what every one of them checks, and without this
  # it triggered no test run at all.
  if printf '%s\n' "$changed" | grep -qE '^(\.claude/scripts/|tests/scripts/|tests/lib/|workspace/skills/scripts/|tests/check-all\.sh)'; then
    run_script_tests
  fi
  if printf '%s\n' "$changed" | grep -qE '^\.claude/commands/nase/[^/]+\.md$'; then
    run_skill_bash_blocks
  fi
  if printf '%s\n' "$changed" | grep -qE '^(\.claude/commands/nase/[^/]+\.md|workspace/skills/[^/]+\.md|tests/check-skill-overlap\.sh)$'; then
    run_skill_overlap
  fi
  if printf '%s\n' "$changed" | grep -qE '^\.claude/docs/[^/]+\.md$'; then
    run_shared_doc_bash_blocks
  fi
  if printf '%s\n' "$changed" | grep -qE '^(\.claude/docs/(repo-resolution|kb-staleness)\.md|\.claude/commands/nase/onboard\.md|\.claude/scripts/(kb-domain-resolve\.sh|kb-hygiene-scan\.py)|tests/check-kb-domain-map-contract\.sh)$'; then
    run_kb_domain_map_contract
  fi
  if printf '%s\n' "$changed" | grep -qE '^(\.claude/commands/nase/[^/]+\.md|workspace/skills/[^/]+\.md|\.claude/docs/language-config\.md|\.claude/scripts/check-canonical-pointers\.py|tests/check-canonical-pointers\.sh)$'; then
    run_canonical_pointers
  fi
  if printf '%s\n' "$changed" | grep -qE '^(\.claude/scripts/check-effort-pointer-integrity\.py|tests/check-effort-pointer-integrity\.sh|\.claude/docs/effort-(lifecycle|model|drift|transitions)\.md|\.claude/commands/nase/kb-review\.md)$'; then
    run_effort_pointer_integrity
  fi
  if printf '%s\n' "$changed" | grep -qE '^(evals/(pr-review|core-workflows)/|\.claude/scripts/(pr-review-eval|skill-eval-run)\.py|tests/scripts/test-(pr-review-eval|skill-eval-run)\.sh)'; then
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
esac

print_summary
exit "$failed"
