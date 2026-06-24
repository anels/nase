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

SHELLCHECK_BIN=$(command -v shellcheck 2>/dev/null || true)
SHELLCHECK_SKIP='SKIP: shellcheck is not installed locally; GitHub Actions still runs this gate.'
ACTIONLINT_BIN=$(command -v actionlint 2>/dev/null || true)
ACTIONLINT_SKIP='SKIP: actionlint is not installed locally; GitHub Actions still runs this gate.'

HOOK_TESTS=(
  tests/hooks/test-block-dangerous-git.sh
  tests/hooks/test-external-write-guards.sh
  tests/hooks/test-style-edit-detect.sh
  tests/hooks/test-session-start.sh
  tests/hooks/test-stop-backup-safety.sh
  tests/hooks/test-post-edit-shellcheck.sh
  tests/hooks/test-pre-edit-write-fact-force.sh
  tests/hooks/test-track-kb-read.sh
)

SCRIPT_TESTS=(
  tests/scripts/test-date-resolve.sh
  tests/scripts/test-kb-gap-scan.sh
  tests/scripts/test-help-summary.sh
  tests/scripts/test-kb-domain-resolve.sh
  tests/scripts/test-kb-hygiene-scan.sh
  tests/scripts/test-kb-usage-report.sh
  tests/scripts/test-kb-search.sh
  tests/scripts/test-today-stats.sh
  tests/scripts/test-tool-availability.sh
  tests/scripts/test-local-parallel-subagents.sh
  tests/scripts/test-cli-tooling-integration.sh
  tests/scripts/test-github-actions-hardening.sh
  tests/scripts/test-pr-github-helper.sh
  tests/scripts/test-statusline-context.sh
  tests/scripts/test-fsd-preflight.sh
  tests/scripts/test-pr-review-eval.sh
  tests/scripts/test-voice-profile-routing.sh
  tests/scripts/test-local-sensitive-artifacts.sh
  tests/scripts/test-shared-workflow-extraction.sh
  tests/scripts/test-workspace-data-scan.sh
  tests/scripts/test-workspace-write-guard.sh
  workspace/skills/scripts/test-lesson-skill-optimizer.sh
)

FAST_SCRIPT_TESTS=(
  tests/scripts/test-help-summary.sh
  tests/scripts/test-local-parallel-subagents.sh
  tests/scripts/test-cli-tooling-integration.sh
  tests/scripts/test-github-actions-hardening.sh
  tests/scripts/test-pr-github-helper.sh
  tests/scripts/test-statusline-context.sh
  tests/scripts/test-fsd-preflight.sh
  tests/scripts/test-pr-review-eval.sh
  tests/scripts/test-voice-profile-routing.sh
  tests/scripts/test-shared-workflow-extraction.sh
  tests/scripts/test-workspace-write-guard.sh
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

run_gate() {
  local gate="$1"
  shift
  local start end duration rc rerun
  start=$(date +%s)
  printf '[gate] %s\n' "$gate"
  "$@"
  rc=$?
  end=$(date +%s)
  duration=$((end - start))
  if [[ "$rc" -eq 0 ]]; then
    printf '[pass] %s (%ss)\n' "$gate" "$duration"
    return 0
  fi
  rerun=$(format_command "$@")
  printf '[fail] %s (exit %s, %ss)\n' "$gate" "$rc" "$duration" >&2
  failures+=("${current_section}|${gate}|${rc}|${duration}s|${rerun}")
  failed=$((failed + 1))
  return 0
}

run_test_files() {
  local test_file
  for test_file in "$@"; do
    if [[ ! -f "$test_file" ]]; then
      case "$test_file" in
        workspace/skills/scripts/*)
          printf '[skip] optional workspace skill test missing: %s\n' "$test_file"
          continue
          ;;
      esac
      run_gate "$(basename "$test_file")" test -f "$test_file"
      continue
    fi
    run_gate "$(basename "$test_file")" bash "$test_file"
  done
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
  lint: shellcheck when installed, actionlint when installed
  catalog: command_catalog.py --check-readme
  wiring: hook registrations and workspace validation
  docs: shared-doc reference integrity and skill doctrine
  regressions: hook tests and script tests
  links: lychee markdown link check, only in --links
EOF
}

run_bash_syntax() {
  section "bash syntax"
  local f
  for f in .claude/hooks/*.sh .claude/scripts/*.sh tests/*.sh tests/hooks/*.sh tests/scripts/*.sh workspace/skills/scripts/*.sh; do
    [[ -f "$f" ]] || continue
    run_gate "bash -n $f" bash -n "$f"
  done
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

run_json() {
  section "JSON"
  run_gate "settings.json parses" bash -c 'python3 -m json.tool .claude/settings.json >/dev/null'
}

run_shellcheck_hooks() {
  section "shellcheck (hooks)"
  if [[ -n "$SHELLCHECK_BIN" ]]; then
    run_gate "shellcheck .claude/hooks/*.sh" "$SHELLCHECK_BIN" -S warning .claude/hooks/*.sh
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
  local opt_in_regex='^(edit-typecheck)$'
  local f name missing=0
  for f in .claude/hooks/*.sh; do
    name=$(basename "$f" .sh)
    [[ "$name" =~ $opt_in_regex ]] && continue
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
      if ! sc=$(printf '%s\n' "$blocks" | "$SHELLCHECK_BIN" --shell=bash -S error - 2>&1); then
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

run_skill_doctrine() {
  section "skill doctrine"
  run_gate "check-skill-doctrine.sh" bash tests/check-skill-doctrine.sh
}

run_evals() {
  section "PR review evals"
  run_gate "test-pr-review-eval.sh" bash tests/scripts/test-pr-review-eval.sh
}

run_links() {
  section "markdown internal-link check"
  if command -v lychee >/dev/null 2>&1; then
    run_gate "lychee offline markdown links" lychee --offline --no-progress --include-fragments \
      --exclude-path workspace \
      --exclude-path .omc \
      --exclude-path node_modules \
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

  if printf '%s\n' "$changed" | grep -qE '^(\.claude/hooks/|tests/hooks/)'; then
    run_hook_tests
  fi
  if printf '%s\n' "$changed" | grep -qE '^(\.claude/scripts/|tests/scripts/|workspace/skills/scripts/|tests/check-all\.sh)'; then
    run_script_tests
  fi
  if printf '%s\n' "$changed" | grep -qE '^\.claude/commands/nase/[^/]+\.md$'; then
    run_skill_bash_blocks
  fi
  if printf '%s\n' "$changed" | grep -qE '^\.claude/docs/[^/]+\.md$'; then
    run_shared_doc_bash_blocks
  fi
  if printf '%s\n' "$changed" | grep -qE '^(evals/pr-review/|\.claude/scripts/pr-review-eval\.py|tests/scripts/test-pr-review-eval\.sh)'; then
    run_evals
  fi

  local test_file
  section "changed test files"
  while IFS= read -r test_file; do
    case "$test_file" in
      tests/hooks/test-*.sh|tests/scripts/test-*.sh|workspace/skills/scripts/test-*.sh)
        [[ -f "$test_file" ]] && run_gate "$test_file" bash "$test_file"
        ;;
    esac
  done <<< "$changed"
}

run_fast() {
  run_bash_syntax
  run_python_syntax
  run_json
  run_actionlint
  run_hook_wiring
  run_command_catalog
  run_shared_doc_refs
  run_skill_doctrine
  run_fast_script_tests
}

run_full() {
  run_bash_syntax
  run_python_syntax
  run_json
  run_shellcheck_hooks
  run_actionlint
  run_hook_wiring
  run_command_catalog
  run_skill_bash_blocks
  run_shared_doc_bash_blocks
  run_hook_tests
  run_workspace_validation
  run_local_sensitive_scan
  run_script_tests
  run_shared_doc_refs
  run_skill_doctrine
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
  for row in "${failures[@]}"; do
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
