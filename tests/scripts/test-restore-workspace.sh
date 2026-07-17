#!/usr/bin/env bash
# Regression tests for transactional workspace restore.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/restore-workspace.py"
TMPROOT=$(mktemp -d)
failures=0
source "$ROOT/tests/lib/assert.sh"
trap 'rm -rf "$TMPROOT"' EXIT

SEVEN_ZIP=$(command -v 7z 2>/dev/null || command -v 7zz 2>/dev/null || true)
assert_cmd "real 7z binary is available" test -n "$SEVEN_ZIP"

make_zip() {
  local source=$1 destination=$2
  (cd "$source" && zip -qr "$destination" .)
}

case_dir="$TMPROOT/flat"
mkdir -p "$case_dir/root/workspace" "$case_dir/source/kb"
printf 'old\n' > "$case_dir/root/workspace/local-only.md"
printf 'context\n' > "$case_dir/source/context.md"
printf 'knowledge\n' > "$case_dir/source/kb/a.md"
make_zip "$case_dir/source" "$case_dir/flat.zip"
python3 "$SCRIPT" inspect --root "$case_dir/root" --archive "$case_dir/flat.zip" --manifest-out "$case_dir/manifest.json" > "$case_dir/inspect.out"
assert_cmd "flat zip shape is inspected" test "$(jq -r .payload_shape "$case_dir/manifest.json")" = flat
assert_cmd "local deletion preview is persisted" test "$(jq -r '.local_only[0]' "$case_dir/manifest.json")" = local-only.md
python3 "$SCRIPT" apply --root "$case_dir/root" --manifest "$case_dir/manifest.json" > "$case_dir/apply.out"
snapshot=$(jq -r .snapshot "$case_dir/apply.out")
assert_cmd "flat zip restores content" test "$(cat "$case_dir/root/workspace/context.md")" = context
assert_cmd "non-empty workspace is renamed into snapshot" test "$(cat "$snapshot/workspace/local-only.md")" = old
assert_cmd "successful apply removes journal" test ! -e "$case_dir/root/.nase-restore/transaction.json"

case_dir="$TMPROOT/wrapped"
mkdir -p "$case_dir/root" "$case_dir/source/workspace/kb"
printf 'wrapped\n' > "$case_dir/source/workspace/context.md"
printf 'value\n' > "$case_dir/source/workspace/kb/a.md"
make_zip "$case_dir/source" "$case_dir/wrapped.zip"
python3 "$SCRIPT" inspect --root "$case_dir/root" --archive "$case_dir/wrapped.zip" --manifest-out "$case_dir/manifest.json" >/dev/null
python3 "$SCRIPT" apply --root "$case_dir/root" --manifest "$case_dir/manifest.json" > "$case_dir/apply.out"
assert_cmd "wrapped zip restores missing workspace" test "$(cat "$case_dir/root/workspace/context.md")" = wrapped
assert_cmd "missing workspace needs no snapshot" test "$(jq -r .snapshot "$case_dir/apply.out")" = null

case_dir="$TMPROOT/empty"
mkdir -p "$case_dir/root/workspace" "$case_dir/source"
printf 'empty-start\n' > "$case_dir/source/context.md"
make_zip "$case_dir/source" "$case_dir/archive.zip"
python3 "$SCRIPT" inspect --root "$case_dir/root" --archive "$case_dir/archive.zip" --manifest-out "$case_dir/manifest.json" >/dev/null
python3 "$SCRIPT" apply --root "$case_dir/root" --manifest "$case_dir/manifest.json" > "$case_dir/apply.out"
assert_cmd "empty workspace restores without snapshot" test "$(jq -r .snapshot "$case_dir/apply.out")" = null

case_dir="$TMPROOT/sevenzip"
mkdir -p "$case_dir/root" "$case_dir/source/workspace/kb"
printf 'seven\n' > "$case_dir/source/workspace/context.md"
printf 'archive\n' > "$case_dir/source/workspace/kb/a.md"
(cd "$case_dir/source" && "$SEVEN_ZIP" a -t7z "$case_dir/archive.7z" workspace >/dev/null)
python3 "$SCRIPT" inspect --root "$case_dir/root" --archive "$case_dir/archive.7z" --manifest-out "$case_dir/manifest.json" >/dev/null
assert_cmd "7z metadata Path is not treated as a member" bash -c '! jq -e --arg archive "$1" '\''any(.members[]; .archive_path == $archive)'\'' "$2" >/dev/null' _ "$case_dir/archive.7z" "$case_dir/manifest.json"
python3 "$SCRIPT" apply --root "$case_dir/root" --manifest "$case_dir/manifest.json" >/dev/null
assert_cmd "real 7z payload restores" test "$(cat "$case_dir/root/workspace/context.md")" = seven

case_dir="$TMPROOT/drift"
mkdir -p "$case_dir/root/workspace" "$case_dir/source"
printf 'old\n' > "$case_dir/root/workspace/context.md"
printf 'new\n' > "$case_dir/source/context.md"
make_zip "$case_dir/source" "$case_dir/archive.zip"
python3 "$SCRIPT" inspect --root "$case_dir/root" --archive "$case_dir/archive.zip" --manifest-out "$case_dir/manifest.json" >/dev/null
printf 'changed\n' > "$case_dir/root/workspace/context.md"
python3 "$SCRIPT" apply --root "$case_dir/root" --manifest "$case_dir/manifest.json" > "$case_dir/workspace.out" 2> "$case_dir/workspace.err"
workspace_rc=$?
assert_cmd "workspace drift rejects apply" test "$workspace_rc" = 2
assert_contains "workspace drift explains re-inspect" "$case_dir/workspace.err" "workspace changed after inspect"
printf 'old\n' > "$case_dir/root/workspace/context.md"
python3 "$SCRIPT" inspect --root "$case_dir/root" --archive "$case_dir/archive.zip" --manifest-out "$case_dir/manifest.json" >/dev/null
printf 'tamper' >> "$case_dir/archive.zip"
python3 "$SCRIPT" apply --root "$case_dir/root" --manifest "$case_dir/manifest.json" > "$case_dir/archive.out" 2> "$case_dir/archive.err"
archive_rc=$?
assert_cmd "archive drift rejects apply" test "$archive_rc" = 2
assert_contains "archive drift explains re-inspect" "$case_dir/archive.err" "archive changed after inspect"

python3 - "$TMPROOT" <<'PY'
import stat
import sys
import zipfile
from pathlib import Path

root = Path(sys.argv[1]) / "unsafe"
root.mkdir()
cases = {
    "traversal": ["../escape"],
    "absolute": ["/absolute"],
    "unc": [r"\\server\share\x"],
    "drive": [r"C:\escape"],
    "duplicate": ["same", "./same"],
    "case": ["Readme", "README"],
    "file-dir": ["a", "a/b"],
    "mixed": ["workspace/context.md", "kb/a.md"],
}
for name, members in cases.items():
    with zipfile.ZipFile(root / f"{name}.zip", "w") as archive:
        for member in members:
            archive.writestr(member, b"x")
with zipfile.ZipFile(root / "symlink.zip", "w") as archive:
    info = zipfile.ZipInfo("link")
    info.create_system = 3
    info.external_attr = (stat.S_IFLNK | 0o777) << 16
    archive.writestr(info, b"target")
PY
for archive in "$TMPROOT"/unsafe/*.zip; do
  name=$(basename "$archive")
  root="$TMPROOT/unsafe-root-${name%.zip}"
  mkdir -p "$root"
  python3 "$SCRIPT" inspect --root "$root" --archive "$archive" --manifest-out "$root/manifest.json" > "$root/out" 2> "$root/err"
  rc=$?
  assert_cmd "unsafe archive is rejected: $name" test "$rc" = 2
done

case_dir="$TMPROOT/link7z"
mkdir -p "$case_dir/root" "$case_dir/source"
printf 'target\n' > "$case_dir/source/file"
ln -s file "$case_dir/source/link"
(cd "$case_dir/source" && "$SEVEN_ZIP" a -t7z -snl "$case_dir/link.7z" . >/dev/null)
python3 "$SCRIPT" inspect --root "$case_dir/root" --archive "$case_dir/link.7z" --manifest-out "$case_dir/manifest.json" > "$case_dir/out" 2> "$case_dir/err"
link_rc=$?
assert_cmd "legacy 7z symlink metadata fails closed" test "$link_rc" = 2
assert_contains "legacy 7z link rejection is explicit" "$case_dir/err" "link member is not allowed"

python3 - "$ROOT" "$TMPROOT/candidate-types" <<'PY'
import importlib.util
import os
import sys
from pathlib import Path

repo, base = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(repo / ".claude/scripts"))
spec = importlib.util.spec_from_file_location("restore_workspace", repo / ".claude/scripts/restore-workspace.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(module)

hard = base / "hard"
hard.mkdir(parents=True)
(hard / "a").write_text("x")
os.link(hard / "a", hard / "b")
try:
    module.validate_candidate(hard, [{"path": "a", "type": "file"}, {"path": "b", "type": "file"}])
except module.RestoreError:
    pass
else:
    raise SystemExit("hard-link candidate was accepted")

special = base / "special"
special.mkdir()
os.mkfifo(special / "fifo")
try:
    module.validate_candidate(special, [{"path": "fifo", "type": "file"}])
except module.RestoreError:
    pass
else:
    raise SystemExit("special-file candidate was accepted")
PY
assert_cmd "candidate hard links and special files are rejected" test "$?" = 0

python3 - "$ROOT" "$TMPROOT/fault" <<'PY'
import importlib.util
import sys
import zipfile
from pathlib import Path
from unittest import mock

repo, base = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(repo / ".claude/scripts"))
spec = importlib.util.spec_from_file_location("restore_workspace", repo / ".claude/scripts/restore-workspace.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(module)

root = base / "root"
(root / "workspace").mkdir(parents=True)
(root / "workspace/old").write_text("old")
archive = base / "archive.zip"
base.mkdir(exist_ok=True)
with zipfile.ZipFile(archive, "w") as target:
    target.writestr("context.md", "new")
manifest = base / "manifest.json"
module.inspect_archive(root, archive, manifest)
with mock.patch.object(module, "promote_candidate", side_effect=OSError("injected promotion failure")):
    try:
        module.apply_restore(root, manifest)
    except OSError:
        pass
    else:
        raise SystemExit("injected promotion failure did not escape")
assert (root / "workspace/old").read_text() == "old"
assert not (root / ".nase-restore/transaction.json").exists()
assert not list(base.glob(".root-restore-candidate-*"))

bound_root = base / "bound-root"
bound_root.mkdir()
bound_archive = base / "bound.zip"
with zipfile.ZipFile(bound_archive, "w") as target:
    target.writestr("context.md", "approved")
bound_manifest = base / "bound-manifest.json"
module.inspect_archive(bound_root, bound_archive, bound_manifest)
original_extract = module.extract_candidate

def mutate_source_after_copy(call_root, extraction_archive, manifest_data, transaction_id):
    assert call_root == bound_root.resolve()
    assert extraction_archive != bound_archive.resolve()
    with zipfile.ZipFile(bound_archive, "w") as target:
        target.writestr("context.md", "unreview")
    return original_extract(call_root, extraction_archive, manifest_data, transaction_id)

with mock.patch.object(module, "extract_candidate", side_effect=mutate_source_after_copy):
    module.apply_restore(bound_root, bound_manifest)
assert (bound_root / "workspace/context.md").read_text() == "approved"
PY
assert_cmd "promotion faults roll back and extraction uses approved archive bytes" test "$?" = 0

python3 - "$ROOT" "$TMPROOT/recover" <<'PY'
import importlib.util
import json
import os
import sys
import uuid
from pathlib import Path

repo, base = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(repo / ".claude/scripts"))
spec = importlib.util.spec_from_file_location("restore_workspace", repo / ".claude/scripts/restore-workspace.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(module)

TIMESTAMP = "20260716T120000"

def tx_paths(root, with_snapshot=True):
    root = root.resolve()
    txid = uuid.uuid4().hex
    candidate = root.parent / f".{root.name}-restore-candidate-{txid}"
    snapshot_dir = root.parent / f"workspace-pre-restore-{TIMESTAMP}-{txid}" if with_snapshot else None
    snapshot = snapshot_dir / "workspace" if snapshot_dir else None
    return txid, candidate, snapshot_dir, snapshot

def write_journal(root, state, txid, candidate, candidate_hash, old_hash, snapshot_dir=None, snapshot=None, overrides=None):
    root = root.resolve()
    payload = {
        "version": 1,
        "state": state,
        "transaction_id": txid,
        "root": str(root),
        "candidate": str(candidate),
        "candidate_inventory_hash": candidate_hash,
        "snapshot_timestamp": TIMESTAMP if snapshot else None,
        "snapshot_dir": str(snapshot_dir) if snapshot_dir else None,
        "snapshot_workspace": str(snapshot) if snapshot else None,
        "had_live_workspace": snapshot is not None,
        "had_old_content": snapshot is not None,
        "old_inventory_hash": old_hash,
    }
    if overrides:
        payload.update(overrides)
    module.atomic_write_json(root / ".nase-restore/transaction.json", payload)
    return root / ".nase-restore/transaction.json"

prepared = base / "prepared"
(prepared / "workspace").mkdir(parents=True)
(prepared / "workspace/old").write_text("old")
old_hash = module.inventory(prepared / "workspace")["inventory_hash"]
txid, candidate, snapshot_dir, snapshot = tx_paths(prepared)
candidate.mkdir()
(candidate / "new").write_text("new")
candidate_hash = module.inventory(candidate)["inventory_hash"]
write_journal(prepared, "prepared", txid, candidate, candidate_hash, old_hash, snapshot_dir, snapshot)
result = module.recover_restore(prepared)
assert result["status"] == "rolled_back"
assert (prepared / "workspace/old").read_text() == "old"
assert not candidate.exists()

prepared_snapshot = base / "prepared-snapshot"
(prepared_snapshot / "workspace").mkdir(parents=True)
(prepared_snapshot / "workspace/old").write_text("old")
old_hash = module.inventory(prepared_snapshot / "workspace")["inventory_hash"]
txid, candidate, snapshot_dir, snapshot = tx_paths(prepared_snapshot)
candidate.mkdir()
(candidate / "new").write_text("new")
candidate_hash = module.inventory(candidate)["inventory_hash"]
snapshot_dir.mkdir()
write_journal(prepared_snapshot, "prepared", txid, candidate, candidate_hash, old_hash, snapshot_dir, snapshot)
result = module.recover_restore(prepared_snapshot)
assert result["status"] == "rolled_back"
assert (prepared_snapshot / "workspace/old").read_text() == "old"
assert not candidate.exists()
assert not snapshot_dir.exists()

rolled_back = base / "rolled-back"
(rolled_back / "workspace").mkdir(parents=True)
(rolled_back / "workspace/old").write_text("old")
old_hash = module.inventory(rolled_back / "workspace")["inventory_hash"]
txid, candidate, snapshot_dir, snapshot = tx_paths(rolled_back)
candidate.mkdir()
(candidate / "new").write_text("new")
snapshot_dir.mkdir()
candidate_hash = module.inventory(candidate)["inventory_hash"]
write_journal(rolled_back, "old_moved", txid, candidate, candidate_hash, old_hash, snapshot_dir, snapshot)
try:
    module.recover_restore(rolled_back)
except module.RestoreError:
    pass
else:
    raise SystemExit("old_moved live workspace with candidate was guessed as owned")
assert (rolled_back / "workspace/old").read_text() == "old"
assert candidate.exists()
assert (rolled_back / ".nase-restore/transaction.json").exists()

old_moved = base / "old-moved"
old_moved.mkdir()
txid, candidate, snapshot_dir, snapshot = tx_paths(old_moved)
candidate.mkdir()
(candidate / "new").write_text("new")
snapshot.mkdir(parents=True)
(snapshot / "old").write_text("old")
candidate_hash = module.inventory(candidate)["inventory_hash"]
old_hash = module.inventory(snapshot)["inventory_hash"]
write_journal(old_moved, "old_moved", txid, candidate, candidate_hash, old_hash, snapshot_dir, snapshot)
result = module.recover_restore(old_moved)
assert result["status"] == "restored"
assert (old_moved / "workspace/new").read_text() == "new"
assert (snapshot / "old").read_text() == "old"

promoted_before_journal = base / "promoted-before-journal"
(promoted_before_journal / "workspace").mkdir(parents=True)
(promoted_before_journal / "workspace/new").write_text("new")
txid, consumed_candidate, snapshot_dir, snapshot = tx_paths(promoted_before_journal)
snapshot.mkdir(parents=True)
(snapshot / "old").write_text("old")
candidate_hash = module.inventory(promoted_before_journal / "workspace")["inventory_hash"]
old_hash = module.inventory(snapshot)["inventory_hash"]
write_journal(promoted_before_journal, "old_moved", txid, consumed_candidate, candidate_hash, old_hash, snapshot_dir, snapshot)
try:
    module.recover_restore(promoted_before_journal)
except module.RestoreError:
    pass
else:
    raise SystemExit("old_moved workspace without a candidate was guessed as owned")
assert (promoted_before_journal / "workspace/new").read_text() == "new"
assert (snapshot / "old").read_text() == "old"
assert (promoted_before_journal / ".nase-restore/transaction.json").exists()

foreign = base / "foreign"
(foreign / "workspace").mkdir(parents=True)
(foreign / "workspace/foreign").write_text("foreign")
txid, candidate, snapshot_dir, snapshot = tx_paths(foreign)
candidate.mkdir()
(candidate / "new").write_text("new")
snapshot.mkdir(parents=True)
(snapshot / "old").write_text("old")
candidate_hash = module.inventory(candidate)["inventory_hash"]
old_hash = module.inventory(snapshot)["inventory_hash"]
write_journal(foreign, "old_moved", txid, candidate, candidate_hash, old_hash, snapshot_dir, snapshot)
try:
    module.recover_restore(foreign)
except module.RestoreError:
    pass
else:
    raise SystemExit("foreign workspace was overwritten")
assert (foreign / "workspace/foreign").read_text() == "foreign"
assert (candidate / "new").read_text() == "new"
assert (snapshot / "old").read_text() == "old"

# Byte-identical foreign recreation is still foreign once a snapshot artifact proves the old workspace moved.
prepared_identical = base / "prepared-identical-foreign"
(prepared_identical / "workspace").mkdir(parents=True)
(prepared_identical / "workspace/old").write_text("old")
txid, candidate, snapshot_dir, snapshot = tx_paths(prepared_identical)
candidate.mkdir()
(candidate / "new").write_text("new")
snapshot.mkdir(parents=True)
(snapshot / "old").write_text("old")
snapshot_stat = (snapshot / "old").stat()
os.utime(prepared_identical / "workspace/old", ns=(snapshot_stat.st_atime_ns, snapshot_stat.st_mtime_ns))
candidate_hash = module.inventory(candidate)["inventory_hash"]
old_hash = module.inventory(snapshot)["inventory_hash"]
assert module.inventory(prepared_identical / "workspace")["inventory_hash"] == old_hash
write_journal(prepared_identical, "prepared", txid, candidate, candidate_hash, old_hash, snapshot_dir, snapshot)
try:
    module.recover_restore(prepared_identical)
except module.RestoreError:
    pass
else:
    raise SystemExit("prepared identical foreign workspace was treated as owned")
assert (prepared_identical / "workspace/old").read_text() == "old"
assert (snapshot / "old").read_text() == "old"
assert (candidate / "new").read_text() == "new"
assert (prepared_identical / ".nase-restore/transaction.json").exists()

old_moved_identical = base / "old-moved-identical-foreign"
(old_moved_identical / "workspace").mkdir(parents=True)
(old_moved_identical / "workspace/old").write_text("old")
txid, candidate, snapshot_dir, snapshot = tx_paths(old_moved_identical)
candidate.mkdir()
(candidate / "new").write_text("new")
snapshot.mkdir(parents=True)
(snapshot / "old").write_text("old")
snapshot_stat = (snapshot / "old").stat()
os.utime(old_moved_identical / "workspace/old", ns=(snapshot_stat.st_atime_ns, snapshot_stat.st_mtime_ns))
candidate_hash = module.inventory(candidate)["inventory_hash"]
old_hash = module.inventory(snapshot)["inventory_hash"]
assert module.inventory(old_moved_identical / "workspace")["inventory_hash"] == old_hash
write_journal(old_moved_identical, "old_moved", txid, candidate, candidate_hash, old_hash, snapshot_dir, snapshot)
try:
    module.recover_restore(old_moved_identical)
except module.RestoreError:
    pass
else:
    raise SystemExit("old_moved identical foreign workspace was treated as owned")
assert (old_moved_identical / "workspace/old").read_text() == "old"
assert (snapshot / "old").read_text() == "old"
assert (candidate / "new").read_text() == "new"
assert (old_moved_identical / ".nase-restore/transaction.json").exists()

promoted = base / "promoted"
(promoted / "workspace").mkdir(parents=True)
(promoted / "workspace/new").write_text("new")
txid, candidate_path, _, _ = tx_paths(promoted, with_snapshot=False)
candidate_hash = module.inventory(promoted / "workspace")["inventory_hash"]
write_journal(promoted, "new_promoted", txid, candidate_path, candidate_hash, "missing", overrides={"had_live_workspace": False})
result = module.recover_restore(promoted)
assert result["status"] == "restored"
assert not (promoted / ".nase-restore/transaction.json").exists()

# A tampered journal must never rename or delete unrelated paths.
tampered = base / "tampered"
(tampered / "workspace").mkdir(parents=True)
(tampered / "workspace/old").write_text("old")
old_hash = module.inventory(tampered / "workspace")["inventory_hash"]
txid, candidate, snapshot_dir, snapshot = tx_paths(tampered)
candidate.mkdir()
(candidate / "new").write_text("new")
candidate_hash = module.inventory(candidate)["inventory_hash"]
unrelated = base / "unrelated"
unrelated.mkdir()
(unrelated / "keep").write_text("keep")
write_journal(tampered, "prepared", txid, candidate, candidate_hash, old_hash, snapshot_dir, snapshot, {"candidate": str(unrelated)})
try:
    module.recover_restore(tampered)
except module.RestoreError:
    pass
else:
    raise SystemExit("tampered candidate path was accepted")
assert (unrelated / "keep").read_text() == "keep"
assert candidate.exists()

write_journal(tampered, "prepared", txid, candidate, candidate_hash, old_hash, snapshot_dir, snapshot, {"snapshot_dir": str(unrelated), "snapshot_workspace": str(unrelated / "workspace")})
try:
    module.recover_restore(tampered)
except module.RestoreError:
    pass
else:
    raise SystemExit("tampered snapshot path was accepted")
assert (unrelated / "keep").read_text() == "keep"

write_journal(tampered, "prepared", txid, candidate, candidate_hash, old_hash, snapshot_dir, snapshot, {"snapshot_workspace": str(unrelated / "workspace")})
try:
    module.recover_restore(tampered)
except module.RestoreError:
    pass
else:
    raise SystemExit("tampered snapshot workspace path was accepted")
assert (unrelated / "keep").read_text() == "keep"

# Exact namespace paths still fail closed when replaced by symlinks.
(candidate / "new").unlink()
candidate.rmdir()
candidate.symlink_to(unrelated, target_is_directory=True)
write_journal(tampered, "prepared", txid, candidate, candidate_hash, old_hash, snapshot_dir, snapshot)
try:
    module.recover_restore(tampered)
except module.RestoreError:
    pass
else:
    raise SystemExit("symlink candidate was accepted")
assert (unrelated / "keep").read_text() == "keep"
candidate.unlink()
candidate.mkdir()
(candidate / "new").write_text("new")
snapshot_dir.symlink_to(unrelated, target_is_directory=True)
write_journal(tampered, "prepared", txid, candidate, module.inventory(candidate)["inventory_hash"], old_hash, snapshot_dir, snapshot)
try:
    module.recover_restore(tampered)
except module.RestoreError:
    pass
else:
    raise SystemExit("symlink snapshot parent was accepted")
assert (unrelated / "keep").read_text() == "keep"

# Candidate drift in prepared state is preserved without touching live workspace.
prepared_drift = base / "prepared-drift"
(prepared_drift / "workspace").mkdir(parents=True)
(prepared_drift / "workspace/old").write_text("old")
old_hash = module.inventory(prepared_drift / "workspace")["inventory_hash"]
txid, candidate, snapshot_dir, snapshot = tx_paths(prepared_drift)
candidate.mkdir()
(candidate / "new").write_text("new")
candidate_hash = module.inventory(candidate)["inventory_hash"]
write_journal(prepared_drift, "prepared", txid, candidate, candidate_hash, old_hash, snapshot_dir, snapshot)
(candidate / "new").write_text("drift")
try:
    module.recover_restore(prepared_drift)
except module.RestoreError:
    pass
else:
    raise SystemExit("prepared candidate drift was deleted")
assert (prepared_drift / "workspace/old").read_text() == "old"
assert (candidate / "new").read_text() == "drift"
assert (prepared_drift / ".nase-restore/transaction.json").exists()

# Candidate drift after old_moved restores only a verified snapshot and retains the candidate.
candidate_drift = base / "candidate-drift"
candidate_drift.mkdir()
txid, candidate, snapshot_dir, snapshot = tx_paths(candidate_drift)
candidate.mkdir()
(candidate / "new").write_text("new")
candidate_hash = module.inventory(candidate)["inventory_hash"]
snapshot.mkdir(parents=True)
(snapshot / "old").write_text("old")
old_hash = module.inventory(snapshot)["inventory_hash"]
write_journal(candidate_drift, "old_moved", txid, candidate, candidate_hash, old_hash, snapshot_dir, snapshot)
(candidate / "new").write_text("drift")
result = module.recover_restore(candidate_drift)
assert result["status"] == "rolled_back"
assert result["retained_candidate"] == str(candidate)
assert (candidate_drift / "workspace/old").read_text() == "old"
assert (candidate / "new").read_text() == "drift"

# If both candidate and snapshot drift, recover preserves both and leaves workspace absent.
both_drift = base / "both-drift"
both_drift.mkdir()
txid, candidate, snapshot_dir, snapshot = tx_paths(both_drift)
candidate.mkdir()
(candidate / "new").write_text("new")
candidate_hash = module.inventory(candidate)["inventory_hash"]
snapshot.mkdir(parents=True)
(snapshot / "old").write_text("old")
old_hash = module.inventory(snapshot)["inventory_hash"]
write_journal(both_drift, "old_moved", txid, candidate, candidate_hash, old_hash, snapshot_dir, snapshot)
(candidate / "new").write_text("candidate drift")
(snapshot / "old").write_text("snapshot drift")
try:
    module.recover_restore(both_drift)
except module.RestoreError:
    pass
else:
    raise SystemExit("drifted snapshot was restored")
assert not (both_drift / "workspace").exists()
assert candidate.exists() and snapshot.exists()

# A promoted workspace that drifts is treated as live/foreign and never overwritten.
promoted_drift = base / "promoted-drift"
(promoted_drift / "workspace").mkdir(parents=True)
(promoted_drift / "workspace/new").write_text("new")
txid, consumed_candidate, snapshot_dir, snapshot = tx_paths(promoted_drift)
candidate_hash = module.inventory(promoted_drift / "workspace")["inventory_hash"]
snapshot.mkdir(parents=True)
(snapshot / "old").write_text("old")
old_hash = module.inventory(snapshot)["inventory_hash"]
write_journal(promoted_drift, "new_promoted", txid, consumed_candidate, candidate_hash, old_hash, snapshot_dir, snapshot)
(promoted_drift / "workspace/new").write_text("live drift")
try:
    module.recover_restore(promoted_drift)
except module.RestoreError:
    pass
else:
    raise SystemExit("drifted live workspace was replaced")
assert (promoted_drift / "workspace/new").read_text() == "live drift"
assert (snapshot / "old").read_text() == "old"
PY
assert_cmd "recovery validates journal namespaces and candidate/snapshot inventories" test "$?" = 0

if [[ "$failures" -eq 0 ]]; then
  printf '\nrestore workspace tests passed.\n'
  exit 0
fi

printf '\n%d restore workspace assertion(s) failed.\n' "$failures" >&2
exit "$failures"
