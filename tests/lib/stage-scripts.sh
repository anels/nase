#!/usr/bin/env bash
# Stage a script into a fixture repo together with the local modules it imports.
#
# Three fixtures used to list the closure by hand, and introducing nase_fs.py and
# nase_git.py broke all three at once with ModuleNotFoundError. The failure was loud, so
# this is about cost rather than risk: the next shared module should not need three
# separate `cp` lists edited to keep the suite green.
#
# Usage:  stage_scripts <dest-scripts-dir> <script.py> [more.py ...]
#
# Resolution is transitive and only follows imports that name a module living in
# .claude/scripts, so a stdlib or third-party import is ignored. A `.sh` argument is
# copied as given, since shell scripts declare no importable closure.

stage_scripts() {
  local dest="$1"
  shift
  [ -n "$dest" ] || { printf 'stage_scripts: no destination\n' >&2; return 1; }
  mkdir -p "$dest"

  # Derived from this file's own location, not from cwd: callers run with cwd inside a
  # fixture repo, and `git rev-parse` there would resolve to the fixture.
  local root
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

  local resolved
  resolved=$(
    STAGE_ROOT="$root" python3 - "$@" <<'PY'
import ast
import os
import pathlib
import sys

root = pathlib.Path(os.environ["STAGE_ROOT"])
scripts = root / ".claude" / "scripts"
# Only a module that exists here can be a local import; anything else is stdlib or a
# dependency and is already importable in the fixture.
local = {path.stem: path for path in scripts.glob("*.py")}

pending = [pathlib.Path(name).name for name in sys.argv[1:]]
seen: set[str] = set()
order: list[str] = []
while pending:
    name = pending.pop()
    if name in seen:
        continue
    seen.add(name)
    order.append(name)
    source = scripts / name
    if source.suffix != ".py" or not source.is_file():
        continue
    # ast.walk, not .body: an import inside a function or a try block is still a
    # local import, and missing it puts the fixture back to ModuleNotFoundError.
    for node in ast.walk(ast.parse(source.read_text(encoding="utf-8"))):
        if isinstance(node, ast.ImportFrom):
            if node.module in local:
                pending.append(f"{node.module}.py")
        elif isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name in local:
                    pending.append(f"{alias.name}.py")

print("\n".join(order))
PY
  ) || { printf 'stage_scripts: could not resolve the import closure\n' >&2; return 1; }

  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ ! -f "$root/.claude/scripts/$name" ]; then
      printf 'stage_scripts: no such script: %s\n' "$name" >&2
      return 1
    fi
    cp "$root/.claude/scripts/$name" "$dest/$name"
  done <<< "$resolved"
}
