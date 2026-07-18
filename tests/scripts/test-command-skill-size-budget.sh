#!/usr/bin/env bash
# Keep every command entrypoint and its routing metadata bounded.

set -euo pipefail

max_entry_lines=250
max_entry_bytes=12000
max_description_chars=240
max_description_total=9000
failures=0

check_budget() {
  local file="$1" max_lines="$2" max_bytes="$3" label="$4"
  local lines bytes
  lines=$(wc -l < "$file" | tr -d ' ')
  bytes=$(wc -c < "$file" | tr -d ' ')
  if (( lines <= max_lines && bytes <= max_bytes )); then
    printf 'PASS  %s %s: %s lines, %s bytes (budget: %s lines, %s bytes)\n' \
      "$label" "$file" "$lines" "$bytes" "$max_lines" "$max_bytes"
  else
    printf 'FAIL  %s %s: %s lines, %s bytes (budget: %s lines, %s bytes)\n' \
      "$label" "$file" "$lines" "$bytes" "$max_lines" "$max_bytes" >&2
    failures=$((failures + 1))
  fi
}

while IFS= read -r skill; do
  check_budget "$skill" "$max_entry_lines" "$max_entry_bytes" entry
done < <(find .claude/commands/nase workspace/skills -maxdepth 1 -type f -name '*.md' | sort)

if ! python3 - "$max_description_chars" "$max_description_total" <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, "tests/lib")
from frontmatter import description_from_frontmatter

per_description = int(sys.argv[1])
total_budget = int(sys.argv[2])
paths = sorted(Path(".claude/commands/nase").glob("*.md")) + sorted(Path("workspace/skills").glob("*.md"))
rows = [(path, description_from_frontmatter(path.read_text(encoding="utf-8", errors="replace"))) for path in paths]
failures = [f"{path}: description {len(description)} chars > {per_description}" for path, description in rows if len(description) > per_description]
total = sum(len(description) for _, description in rows)
if total > total_budget:
    failures.append(f"description catalog: {total} chars > {total_budget}")
if failures:
    print("\n".join(f"FAIL  {failure}" for failure in failures), file=sys.stderr)
    raise SystemExit(1)
print(f"PASS  description catalog: {total} chars (budget: {total_budget})")
PY
then
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  exit 1
fi
