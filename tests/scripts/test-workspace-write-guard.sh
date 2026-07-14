#!/usr/bin/env bash
# Regression tests for .claude/scripts/workspace-write-guard.py

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/workspace-write-guard.py"
TMPROOT=$(mktemp -d)
failures=0
source "$ROOT/tests/lib/assert.sh"

cleanup() {
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

json_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

path, field = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
value = data
for part in field.split("."):
    value = value[part]
print(value)
PY
}

file_mode() {
  python3 - "$1" <<'PY'
import os
import sys

print(format(os.stat(sys.argv[1]).st_mode & 0o7777, "o"))
PY
}

mkdir -p "$TMPROOT/workspace/kb/projects" "$TMPROOT/workspace/tmp" "$TMPROOT/.claude/commands/nase/workspace"
mkdir -p "$TMPROOT/workspace/journals"

target="$TMPROOT/workspace/kb/projects/demo.md"
proposal="$TMPROOT/proposal.md"
stage_json="$TMPROOT/stage.json"
apply_json="$TMPROOT/apply.json"

printf 'old\n' > "$target"
printf 'new\n' > "$proposal"

python3 "$SCRIPT" stage \
  --root "$TMPROOT" \
  --target workspace/kb/projects/demo.md \
  --content-file "$proposal" \
  --skill kb-update > "$stage_json"
stage_rc=$?

assert_cmd "stage exits 0" test "$stage_rc" = "0"
staged=$(json_field "$stage_json" staged_abs)
mtime_ns=$(json_field "$stage_json" target.mtime_ns)
sha256=$(json_field "$stage_json" target.sha256)

assert_cmd "stage creates staged file" test -f "$staged"
assert_cmd "stage keeps target unchanged" grep -qx 'old' "$target"
assert_cmd "staged file has proposed content" grep -qx 'new' "$staged"
assert_cmd "stage records mtime" test "$mtime_ns" != "missing"
assert_cmd "stage records sha256" test "$sha256" != "missing"

python3 "$SCRIPT" diff \
  --root "$TMPROOT" \
  --target workspace/kb/projects/demo.md \
  --staged "$staged" > "$TMPROOT/diff.txt"
assert_cmd "diff shows old line" grep -q '^-old' "$TMPROOT/diff.txt"
assert_cmd "diff shows new line" grep -q '^+new' "$TMPROOT/diff.txt"

python3 "$SCRIPT" apply \
  --root "$TMPROOT" \
  --target workspace/kb/projects/demo.md \
  --staged "$staged" \
  --expected-mtime-ns "$mtime_ns" \
  --expected-sha256 "$sha256" > "$apply_json"
apply_rc=$?

assert_cmd "apply exits 0" test "$apply_rc" = "0"
assert_cmd "apply updates target" grep -qx 'new' "$target"
assert_cmd "apply reports target" grep -q '"target": "workspace/kb/projects/demo.md"' "$apply_json"

move_source="$TMPROOT/workspace/efforts/move.md"
move_destination="$TMPROOT/workspace/efforts/done/move.md"
mkdir -p "$(dirname "$move_source")"
printf 'old move\n' > "$move_source"
chmod 600 "$move_source"
printf 'new move\n' > "$proposal"
python3 "$SCRIPT" stage \
  --root "$TMPROOT" \
  --target workspace/efforts/move.md \
  --content-file "$proposal" \
  --skill efforts > "$stage_json"
move_staged=$(json_field "$stage_json" staged_abs)
move_mtime_ns=$(json_field "$stage_json" target.mtime_ns)
move_sha256=$(json_field "$stage_json" target.sha256)

python3 "$SCRIPT" apply-move \
  --root "$TMPROOT" \
  --target workspace/efforts/move.md \
  --destination workspace/efforts/done/move.md \
  --staged "$move_staged" \
  --expected-mtime-ns "$move_mtime_ns" \
  --expected-sha256 "$move_sha256" > "$TMPROOT/apply-move.json"
assert_cmd "apply-move removes source" test ! -e "$move_source"
assert_cmd "apply-move writes staged destination" grep -qx 'new move' "$move_destination"
assert_cmd "apply-move preserves source mode" test "$(file_mode "$move_destination")" = "600"

collision_source="$TMPROOT/workspace/efforts/collision.md"
collision_destination="$TMPROOT/workspace/efforts/done/collision.md"
printf 'source\n' > "$collision_source"
printf 'existing\n' > "$collision_destination"
printf 'replacement\n' > "$proposal"
python3 "$SCRIPT" stage \
  --root "$TMPROOT" \
  --target workspace/efforts/collision.md \
  --content-file "$proposal" \
  --skill efforts > "$stage_json"
collision_staged=$(json_field "$stage_json" staged_abs)
collision_mtime_ns=$(json_field "$stage_json" target.mtime_ns)
collision_sha256=$(json_field "$stage_json" target.sha256)

python3 "$SCRIPT" apply-move \
  --root "$TMPROOT" \
  --target workspace/efforts/collision.md \
  --destination workspace/efforts/done/collision.md \
  --staged "$collision_staged" \
  --expected-mtime-ns "$collision_mtime_ns" \
  --expected-sha256 "$collision_sha256" > "$TMPROOT/collision.out" 2> "$TMPROOT/collision.err"
collision_rc=$?
assert_cmd "apply-move collision exits 4" test "$collision_rc" = "4"
assert_cmd "apply-move collision preserves source" grep -qx 'source' "$collision_source"
assert_cmd "apply-move collision preserves destination" grep -qx 'existing' "$collision_destination"

missing_proposal="$TMPROOT/missing-proposal.md"
printf 'new file\n' > "$missing_proposal"
python3 "$SCRIPT" stage \
  --root "$TMPROOT" \
  --target workspace/efforts/missing.md \
  --content-file "$missing_proposal" \
  --skill efforts > "$stage_json"
missing_staged=$(json_field "$stage_json" staged_abs)
missing_mtime_ns=$(json_field "$stage_json" target.mtime_ns)
missing_sha256=$(json_field "$stage_json" target.sha256)

python3 "$SCRIPT" apply-move \
  --root "$TMPROOT" \
  --target workspace/efforts/missing.md \
  --destination workspace/efforts/done/missing.md \
  --staged "$missing_staged" \
  --expected-mtime-ns "$missing_mtime_ns" \
  --expected-sha256 "$missing_sha256" > "$TMPROOT/missing.out" 2> "$TMPROOT/missing.err"
missing_rc=$?
assert_cmd "apply-move missing source exits 3" test "$missing_rc" = "3"
assert_cmd "apply-move missing source creates no destination" test ! -e "$TMPROOT/workspace/efforts/done/missing.md"
assert_cmd "apply-move missing source preserves staged draft" test -f "$missing_staged"

python3 - "$SCRIPT" "$TMPROOT" <<'PY'
import argparse
import importlib.util
import os
import sys
from pathlib import Path

script, root_arg = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("workspace_write_guard_races", script)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

root = Path(root_arg).resolve()
original_link = module.os.link
original_unlink = module.Path.unlink
original_rename = module.os.rename

for name, race, expected_code in (
    ("final-gap", "destination-at-unlink", 5),
    ("link-return", "destination-after-link", 5),
    ("source-return", "source-at-unlink", 5),
    ("rename-failure", "rename-failure", 5),
    ("source-drift", "source-drift", 3),
    ("source-type", "source-type", 2),
    ("rollback-gap", "destination-at-rollback", 5),
):
    source = root / f"workspace/efforts/{name}.md"
    destination = root / f"workspace/efforts/done/{name}.md"
    staged = root / f"workspace/tmp/staged-{name}.md"
    foreign = root / f"workspace/tmp/foreign-{name}.md"
    source.write_text("source\n", encoding="utf-8")
    source.chmod(0o600)
    staged.write_text("staged\n", encoding="utf-8")
    foreign.write_text("foreign\n", encoding="utf-8")
    state = module.file_state(source)
    args = argparse.Namespace(
        root=str(root),
        target=f"workspace/efforts/{name}.md",
        destination=f"workspace/efforts/done/{name}.md",
        staged=f"workspace/tmp/staged-{name}.md",
        expected_mtime_ns=state["mtime_ns"],
        expected_sha256=state["sha256"],
    )

    def racing_link(src, dst):
        original_link(src, dst)
        if race == "destination-after-link" and Path(dst) == destination:
            os.replace(foreign, destination)

    def racing_unlink(path, *unlink_args, **unlink_kwargs):
        if ".move-backup-" in path.name:
            if race == "destination-at-unlink":
                os.replace(foreign, destination)
            elif race == "source-at-unlink":
                os.replace(foreign, source)
        return original_unlink(path, *unlink_args, **unlink_kwargs)

    def racing_rename(src, dst):
        if race == "destination-at-rollback" and Path(src) == destination:
            os.replace(foreign, destination)
        if race == "destination-at-rollback" and Path(src) == source:
            raise OSError("injected rename failure")
        if race == "rename-failure" and Path(src) == source:
            raise OSError("injected rename failure")
        if race == "source-drift" and Path(src) == source:
            source.write_text("changed\n", encoding="utf-8")
        if race == "source-type" and Path(src) == source:
            source.unlink()
            source.mkdir()
        return original_rename(src, dst)

    module.os.link = racing_link
    module.Path.unlink = racing_unlink
    module.os.rename = racing_rename
    try:
        module.cmd_apply_move(args)
    except module.GuardError as exc:
        assert exc.code == expected_code
    else:
        raise AssertionError(f"expected {name} destination replacement rejection")
    finally:
        module.os.link = original_link
        module.Path.unlink = original_unlink
        module.os.rename = original_rename

    if race == "source-at-unlink":
        assert source.read_text(encoding="utf-8") == "foreign\n"
        assert not destination.exists()
        recoveries = list((root / "workspace/tmp").glob("move-recovery-*"))
        assert any(path.read_text(encoding="utf-8") == "source\n" for path in recoveries)
        assert any((path.stat().st_mode & 0o777) == 0o600 for path in recoveries)
    elif race == "rename-failure":
        assert source.read_text(encoding="utf-8") == "source\n"
        assert not destination.exists()
    elif race == "source-drift":
        assert source.read_text(encoding="utf-8") == "changed\n"
        assert not destination.exists()
    elif race == "source-type":
        assert source.is_dir()
        assert not destination.exists()
        backups = list(source.parent.glob(f".{source.name}.move-backup-*"))
        assert any(path.is_dir() for path in backups)
    elif race in {"destination-at-unlink", "destination-after-link", "destination-at-rollback"}:
        assert source.read_text(encoding="utf-8") == "source\n"
        assert (source.stat().st_mode & 0o777) == 0o600
        assert not destination.exists()
        rollbacks = list((root / "workspace/tmp").glob("move-rollback-*"))
        assert any(path.read_text(encoding="utf-8") == "foreign\n" for path in rollbacks)
    else:
        assert source.read_text(encoding="utf-8") == "source\n"
        assert (source.stat().st_mode & 0o777) == 0o600
        assert not destination.exists()
PY
race_rc=$?
assert_cmd "apply-move preserves data across replacement races" test "$race_rc" = "0"

printf 'draft\n' > "$proposal"
python3 "$SCRIPT" stage \
  --root "$TMPROOT" \
  --target workspace/kb/projects/demo.md \
  --content-file "$proposal" \
  --skill kb-update > "$stage_json"
drift_staged=$(json_field "$stage_json" staged_abs)
drift_mtime_ns=$(json_field "$stage_json" target.mtime_ns)
drift_sha256=$(json_field "$stage_json" target.sha256)
printf 'changed elsewhere\n' > "$target"

python3 "$SCRIPT" apply \
  --root "$TMPROOT" \
  --target workspace/kb/projects/demo.md \
  --staged "$drift_staged" \
  --expected-mtime-ns "$drift_mtime_ns" \
  --expected-sha256 "$drift_sha256" > "$TMPROOT/drift.out" 2> "$TMPROOT/drift.err"
drift_rc=$?

assert_cmd "drift exits 3" test "$drift_rc" = "3"
assert_cmd "drift preserves target" grep -qx 'changed elsewhere' "$target"
assert_cmd "drift preserves staged draft" test -f "$drift_staged"
assert_cmd "drift message names staged file" grep -q 'staged file preserved' "$TMPROOT/drift.err"

python3 "$SCRIPT" stage \
  --root "$TMPROOT" \
  --target ../outside.md \
  --content-file "$proposal" \
  --skill bad > "$TMPROOT/outside.out" 2> "$TMPROOT/outside.err"
outside_rc=$?
assert_cmd "outside target rejected" test "$outside_rc" = "2"

python3 "$SCRIPT" stage \
  --root "$TMPROOT" \
  --target workspace/tmp/not-durable.md \
  --content-file "$proposal" \
  --skill bad > "$TMPROOT/tmp-target.out" 2> "$TMPROOT/tmp-target.err"
tmp_target_rc=$?
assert_cmd "workspace tmp target rejected" test "$tmp_target_rc" = "2"

python3 "$SCRIPT" stage \
  --root "$TMPROOT" \
  --target .claude/commands/nase/workspace/generated.md \
  --content-file "$proposal" \
  --skill extract-skills > "$TMPROOT/wrapper-stage.json"
wrapper_rc=$?
assert_cmd "generated wrapper target allowed" test "$wrapper_rc" = "0"

python3 "$SCRIPT" stage \
  --root "$TMPROOT" \
  --target workspace/journals/2026-06-08.md \
  --content-file "$proposal" \
  --skill wrap-up > "$TMPROOT/journal-stage.json"
journal_rc=$?
assert_cmd "journal rewrite target allowed" test "$journal_rc" = "0"

assert_cmd "guard doc documents helper" grep -q 'workspace-write-guard.py stage' "$ROOT/.claude/docs/workspace-write-guard.md"
assert_cmd "guard doc documents apply-move" grep -q 'workspace-write-guard.py apply-move' "$ROOT/.claude/docs/workspace-write-guard.md"
assert_cmd "design uses helper" grep -q 'workspace-write-guard.py stage' "$ROOT/.claude/commands/nase/design.md"
assert_cmd "kb-update uses helper" grep -q 'workspace-write-guard.py stage' "$ROOT/.claude/commands/nase/kb-update.md"
assert_cmd "wrap-up uses helper" grep -q 'workspace-write-guard.py stage' "$ROOT/.claude/commands/nase/wrap-up.md"

if [[ "$failures" -eq 0 ]]; then
  printf '\nworkspace-write-guard tests passed.\n'
  exit 0
fi

printf '\n%d workspace-write-guard assertion(s) failed.\n' "$failures" >&2
exit "$failures"
