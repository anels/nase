#!/usr/bin/env bash
# Run all local validation gates that mirror CI (`.github/workflows/validate.yml`).
#
# Run from repo root:  bash tests/check-all.sh
# Exit 0 = all gates pass, exit N = N failed gates.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

failed=0
section() { printf '\n=== %s ===\n' "$1"; }

section "bash syntax (hooks)"
for f in .claude/hooks/*.sh; do
  bash -n "$f" || failed=$((failed+1))
done

section "shellcheck (hooks)"
shellcheck -S warning .claude/hooks/*.sh || failed=$((failed+1))

section "JSON (settings.json)"
python3 -m json.tool .claude/settings.json >/dev/null || failed=$((failed+1))

section "hook wiring"
OPT_IN_REGEX='^(edit-typecheck)$'
missing_hook=0
for f in .claude/hooks/*.sh; do
  name=$(basename "$f" .sh)
  [[ "$name" =~ $OPT_IN_REGEX ]] && continue
  if ! grep -q "${name}.sh" .claude/settings.json; then
    printf 'FAIL: %s.sh not wired in settings.json\n' "$name"
    missing_hook=1
  fi
done
[[ "$missing_hook" -eq 0 ]] || failed=$((failed+1))

section "command inventory"
missing_cmd=0
while IFS= read -r cmd; do
  file=".claude/commands/nase/${cmd}.md"
  if [ ! -f "$file" ]; then
    printf 'FAIL: README references /nase:%s but %s does not exist\n' "$cmd" "$file"
    missing_cmd=1
  fi
done < <(grep -oE '/nase:[a-z-]+' README.md | sed 's|/nase:||' | sort -u)
[[ "$missing_cmd" -eq 0 ]] || failed=$((failed+1))

section "skill bash syntax + shellcheck"
skill_fail=0
for f in .claude/commands/nase/*.md; do
  blocks=$(awk '/```bash/{p=1;next} /```/{p=0} p' "$f")
  [ -z "$blocks" ] && continue
  if ! err=$(echo "$blocks" | bash -n 2>&1); then
    printf 'FAIL: invalid bash syntax in %s: %s\n' "$f" "$err"
    skill_fail=1
  fi
  if ! sc=$(echo "$blocks" | shellcheck --shell=bash -S error - 2>&1); then
    printf 'FAIL: shellcheck errors in %s:\n%s\n' "$f" "$sc"
    skill_fail=1
  fi
done
[[ "$skill_fail" -eq 0 ]] || failed=$((failed+1))

section "shared-doc bash syntax"
doc_bash_fail=0
for f in .claude/docs/*.md; do
  blocks=$(awk '/```bash/{p=1;next} /```/{p=0} p' "$f")
  [ -z "$blocks" ] && continue
  if ! err=$(printf '%s\n' "$blocks" | bash -n 2>&1); then
    printf 'FAIL: invalid bash syntax in %s: %s\n' "$f" "$err"
    doc_bash_fail=1
  fi
done
[[ "$doc_bash_fail" -eq 0 ]] || failed=$((failed+1))

section "hook regression tests"
bash tests/hooks/test-block-dangerous-git.sh || failed=$((failed+1))
bash tests/hooks/test-external-write-guards.sh || failed=$((failed+1))
bash tests/hooks/test-style-edit-detect.sh || failed=$((failed+1))
bash tests/hooks/test-session-start.sh || failed=$((failed+1))
bash tests/hooks/test-stop-backup-safety.sh || failed=$((failed+1))

section "workspace validation"
bash .claude/scripts/validate-workspace.sh || failed=$((failed+1))

section "script regression tests"
bash tests/scripts/test-date-resolve.sh || failed=$((failed+1))
bash tests/scripts/test-kb-gap-scan.sh || failed=$((failed+1))
bash tests/scripts/test-help-summary.sh || failed=$((failed+1))
bash tests/scripts/test-kb-hygiene-scan.sh || failed=$((failed+1))
bash tests/scripts/test-kb-search.sh || failed=$((failed+1))

section "shared-doc reference integrity"
bash tests/check-shared-doc-refs.sh || failed=$((failed+1))

section "skill doctrine"
bash tests/check-skill-doctrine.sh || failed=$((failed+1))

section "markdown internal-link check"
if command -v lychee >/dev/null 2>&1; then
  lychee --offline --no-progress --include-fragments \
    --exclude-path workspace \
    --exclude-path .omc \
    --exclude-path node_modules \
    './**/*.md' || failed=$((failed+1))
else
  printf 'SKIP: lychee not installed locally; GitHub Actions still runs this gate.\n'
fi

if [[ "$failed" -eq 0 ]]; then
  printf '\nAll gates passed.\n'
  exit 0
fi

printf '\n%d gate(s) failed.\n' "$failed" >&2
exit "$failed"
