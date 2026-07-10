#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

PYTHON_BIN=$(command -v python3)
SCRIPT=".claude/scripts/tool-availability.py"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

mkdir -p "$TMPDIR_TEST/bin"

failures=0
source "$ROOT/tests/lib/assert.sh"

json_file="$TMPDIR_TEST/all.json"
PATH="$TMPDIR_TEST/bin" "$PYTHON_BIN" "$SCRIPT" --all --format json > "$json_file"

assert_cmd "all json parses" bash -c '"$1" -m json.tool "$2" >/dev/null' _ "$PYTHON_BIN" "$json_file"

assert_cmd "binary/formula mappings are stable" "$PYTHON_BIN" - "$json_file" <<'PY'
import json
import sys

rows = json.load(open(sys.argv[1], encoding="utf-8"))
by_tool = {row["tool"]: row for row in rows}
expected = {
    "httpie": ("http", "httpie"),
    "markitdown": ("markitdown", None),
    "pdftotext": ("pdftotext", "poppler"),
    "imagemagick": ("magick", "imagemagick"),
    "miller": ("mlr", "miller"),
    "difftastic": ("difft", "difftastic"),
    "ripgrep-all": ("rga", "ripgrep-all"),
    "universal-ctags": ("ctags", "universal-ctags"),
}
for tool, (binary, brew) in expected.items():
    row = by_tool[tool]
    assert row["binary"] == binary, (tool, row)
    assert row["brew"] == brew, (tool, row)
assert by_tool["markitdown"]["install"] == "uv tool install 'markitdown[all]'"
PY

cat > "$TMPDIR_TEST/bin/rg" <<'SH'
#!/usr/bin/env sh
exit 0
SH
chmod +x "$TMPDIR_TEST/bin/rg"

baseline_json="$TMPDIR_TEST/baseline.json"
PATH="$TMPDIR_TEST/bin" "$PYTHON_BIN" "$SCRIPT" --group baseline --format json > "$baseline_json"

assert_cmd "fake rg is detected" "$PYTHON_BIN" - "$baseline_json" <<'PY'
import json
import sys

rows = json.load(open(sys.argv[1], encoding="utf-8"))
by_binary = {row["binary"]: row for row in rows}
assert by_binary["rg"]["status"] == "ok"
assert by_binary["yq"]["status"] == "missing"
PY

install_out="$TMPDIR_TEST/install.txt"
PATH="$TMPDIR_TEST/bin" "$PYTHON_BIN" "$SCRIPT" --group baseline --missing --install brew > "$install_out"

assert_cmd "install output excludes installed rg" bash -c "! grep -q 'ripgrep' '$install_out'"
assert_cmd "install output includes missing yq" grep -q 'yq' "$install_out"
assert_cmd "baseline install excludes actionlint" bash -c "! grep -q 'actionlint' '$install_out'"
assert_cmd "baseline install excludes lychee" bash -c "! grep -q 'lychee' '$install_out'"

table_out="$TMPDIR_TEST/table.txt"
PATH="$TMPDIR_TEST/bin" "$PYTHON_BIN" "$SCRIPT" --group api --format table > "$table_out"
assert_cmd "table output names missing httpie formula" grep -q 'brew install httpie' "$table_out"

docs_table_out="$TMPDIR_TEST/docs-table.txt"
PATH="$TMPDIR_TEST/bin" "$PYTHON_BIN" "$SCRIPT" --group docs --format table > "$docs_table_out"
assert_cmd "docs table names markitdown install hint" grep -q "uv tool install 'markitdown\\[all\\]'" "$docs_table_out"

security_json="$TMPDIR_TEST/security.json"
PATH="$TMPDIR_TEST/bin" "$PYTHON_BIN" "$SCRIPT" --group security --format json > "$security_json"
assert_cmd "security group includes gitleaks and hadolint" "$PYTHON_BIN" - "$security_json" <<'PY'
import json
import sys

tools = {row["tool"] for row in json.load(open(sys.argv[1], encoding="utf-8"))}
assert {"gitleaks", "hadolint"} <= tools
PY

ci_json="$TMPDIR_TEST/ci.json"
PATH="$TMPDIR_TEST/bin" "$PYTHON_BIN" "$SCRIPT" --group ci --format json > "$ci_json"
assert_cmd "ci group includes actionlint" "$PYTHON_BIN" - "$ci_json" <<'PY'
import json
import sys

tools = {row["tool"] for row in json.load(open(sys.argv[1], encoding="utf-8"))}
assert tools == {"actionlint"}
PY

if [[ "$failures" -eq 0 ]]; then
  printf '\ntool-availability tests passed.\n'
  exit 0
fi

printf '\n%d tool-availability assertion(s) failed.\n' "$failures" >&2
exit 1
