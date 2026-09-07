#!/usr/bin/env bash
# Keep every command entrypoint, its routing metadata, and the docs it pulls in bounded.

set -euo pipefail

max_entry_lines=250
max_entry_bytes=12000
max_description_chars=240
max_description_total=9000
# Entrypoint plus the `.claude/docs` files it names directly. The entrypoint budget alone
# missed where the weight is: the entrypoint is a median of 54 lines and its depth-1
# closure a median of 444. This is a backstop rather than a forcing function - today's
# worst case is design.md at 1992 lines, so the ceiling leaves about ten percent of room
# and catches the next doc appended without thought. design.md is also the case that
# shows why this is an over-approximation: its auto, grill, and review mode docs are
# mutually exclusive, so no single run loads all of them.
max_closure_lines=2200
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

if ! python3 - "$max_closure_lines" <<'PY'
import pathlib
import re
import sys

budget = int(sys.argv[1])
DOC_RE = re.compile(r"\.claude/docs/([A-Za-z0-9_.-]+\.md)")

docs = {
    path.name: len(path.read_text(encoding="utf-8", errors="replace").splitlines())
    for path in pathlib.Path(".claude/docs").glob("*.md")
}
entries = sorted(pathlib.Path(".claude/commands/nase").glob("*.md")) + sorted(
    pathlib.Path("workspace/skills").glob("*.md")
)

rows = []
for entry in entries:
    text = entry.read_text(encoding="utf-8", errors="replace")
    # Depth 1 only: a doc that points at another doc is not followed, so this is a floor
    # on what a session loads, never the whole closure.
    named = sorted({name for name in DOC_RE.findall(text) if name in docs})
    rows.append((len(text.splitlines()) + sum(docs[name] for name in named), entry, named))

over = [row for row in rows if row[0] > budget]
for total, entry, named in sorted(over, reverse=True):
    print(f"FAIL  closure {entry}: {total} lines > {budget}", file=sys.stderr)
    for name in sorted(named, key=lambda n: -docs[n])[:5]:
        print(f"        {docs[name]:>5}  {name}", file=sys.stderr)
    print("        split the largest doc, or point at the section that is actually needed",
          file=sys.stderr)
if over:
    raise SystemExit(1)

worst = max(rows)
print(f"PASS  depth-1 closure: worst is {worst[1].name} at {worst[0]} lines "
      f"(budget: {budget}); median {sorted(row[0] for row in rows)[len(rows) // 2]}")
PY
then
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  exit 1
fi
