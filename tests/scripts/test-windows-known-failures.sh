#!/usr/bin/env bash
# The Windows known-failures list must only name tracked test files. A renamed or deleted
# test would otherwise leave a dead entry that silently skips nothing.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
LIST="$ROOT/tests/windows-known-failures.txt"

pass=0
fail=0

if [ ! -f "$LIST" ]; then
  printf 'FAIL  tests/windows-known-failures.txt is missing\n' >&2
  exit 1
fi

entries=()
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}
  case "$line" in
    '' | '#'*) continue ;;
  esac
  entries+=("$line")
done < "$LIST"

if [ "${#entries[@]}" -gt 0 ]; then
  pass=$((pass + 1))
  printf 'PASS  list has %d entries\n' "${#entries[@]}"
else
  fail=$((fail + 1))
  printf 'FAIL  list has no entries; delete the file and its check-all.sh hook instead\n' >&2
fi

tracked=$(git -C "$ROOT" ls-files 'tests/hooks/test-*.sh' 'tests/scripts/test-*.sh')

for entry in "${entries[@]}"; do
  case "$entry" in
    tests/hooks/test-*.sh | tests/scripts/test-*.sh) ;;
    *)
      fail=$((fail + 1))
      printf 'FAIL  %s is not a repo-relative path to a test file\n' "$entry" >&2
      continue
      ;;
  esac
  if grep -qxF "$entry" <<< "$tracked"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL  %s names no tracked test file; remove or fix the entry\n' "$entry" >&2
  fi
done

dupes=$(printf '%s\n' "${entries[@]}" | sort | uniq -d)
if [ -z "$dupes" ]; then
  pass=$((pass + 1))
  printf 'PASS  no duplicate entries\n'
else
  fail=$((fail + 1))
  printf 'FAIL  duplicate entries:\n%s\n' "$dupes" >&2
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
