#!/usr/bin/env python3
"""Inspect, apply, and recover atomic workspace restores."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata
import uuid
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any

from workspace_lock import LockError, held


VERSION = 1
JOURNAL_RELATIVE = Path(".nase-restore/transaction.json")
SNAPSHOT_TIMESTAMP_RE = re.compile(r"^\d{8}T\d{6}$")


class RestoreError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    parent_existed = path.parent.exists()
    path.parent.mkdir(parents=True, exist_ok=True)
    if not parent_existed:
        fsync_dir(path.parent.parent)
    fd, raw_temp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temp = Path(raw_temp)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, path)
        fsync_dir(path.parent)
    finally:
        try:
            temp.unlink()
        except FileNotFoundError:
            pass


def load_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RestoreError(f"cannot read JSON {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise RestoreError(f"JSON object required: {path}")
    return data


def normalize_member(raw: str) -> str:
    if not raw or "\x00" in raw:
        raise RestoreError("archive contains an empty or NUL member path")
    if raw.startswith(("/", "\\")) or raw.startswith("//"):
        raise RestoreError(f"archive contains an absolute or UNC path: {raw!r}")
    if re.match(r"^[A-Za-z]:[\\/]", raw):
        raise RestoreError(f"archive contains a Windows drive path: {raw!r}")
    raw = raw.replace("\\", "/")
    parts: list[str] = []
    for part in raw.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            raise RestoreError(f"archive contains parent traversal: {raw!r}")
        parts.append(unicodedata.normalize("NFC", part))
    if not parts:
        raise RestoreError(f"archive member has no usable path: {raw!r}")
    return str(PurePosixPath(*parts))


def zip_members(archive: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    try:
        with zipfile.ZipFile(archive) as source:
            for info in source.infolist():
                mode = (info.external_attr >> 16) & 0xFFFF
                kind_bits = stat.S_IFMT(mode)
                is_dir = info.is_dir()
                if info.create_system == 3 and kind_bits:
                    if stat.S_ISDIR(mode):
                        is_dir = True
                    elif not stat.S_ISREG(mode):
                        raise RestoreError(f"zip member is not a regular file or directory: {info.filename!r}")
                records.append(
                    {
                        "archive_path": info.filename,
                        "type": "directory" if is_dir else "file",
                        "size": 0 if is_dir else info.file_size,
                        "mode": stat.S_IMODE(mode) if mode else None,
                    }
                )
    except (OSError, zipfile.BadZipFile) as exc:
        raise RestoreError(f"cannot inspect zip archive: {exc}") from exc
    return records


def seven_zip_binary() -> str:
    binary = shutil.which("7z") or shutil.which("7zz")
    if not binary:
        raise RestoreError("7z or 7zz is required for legacy .7z restore")
    return binary


def seven_zip_members(archive: Path) -> list[dict[str, Any]]:
    result = subprocess.run(
        [seven_zip_binary(), "l", "-slt", str(archive)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode:
        raise RestoreError(f"7z listing failed: {result.stderr.strip()}")
    lines = result.stdout.splitlines()
    try:
        start = next(index for index, line in enumerate(lines) if re.fullmatch(r"-{10,}", line.strip())) + 1
    except StopIteration as exc:
        raise RestoreError("7z listing has no member metadata separator") from exc
    records: list[dict[str, Any]] = []
    current: dict[str, str] = {}
    for line in [*lines[start:], ""]:
        if not line.strip():
            if current:
                path = current.get("Path")
                attrs = current.get("Attributes", "")
                link_keys = {key for key in current if "Link" in key}
                unix_mode = attrs.split()[-1] if attrs.split() else ""
                if not path:
                    raise RestoreError("7z member record is missing Path")
                if link_keys or unix_mode.startswith("l"):
                    raise RestoreError(f"7z link member is not allowed: {path!r}")
                is_dir = current.get("Folder") == "+" or attrs.startswith("D") or unix_mode.startswith("d")
                if not attrs and "Folder" not in current:
                    raise RestoreError(f"7z cannot prove member type is safe: {path!r}")
                if not is_dir and unix_mode and unix_mode[0] not in ("-", ".") and not attrs.startswith("A"):
                    raise RestoreError(f"7z member type is not a regular file: {path!r}")
                try:
                    size = int(current.get("Size", "0"))
                except ValueError as exc:
                    raise RestoreError(f"invalid 7z member size for {path!r}") from exc
                records.append(
                    {
                        "archive_path": path,
                        "type": "directory" if is_dir else "file",
                        "size": 0 if is_dir else size,
                        "mode": None,
                    }
                )
                current = {}
            continue
        if " = " in line:
            key, value = line.split(" = ", 1)
            current[key] = value
    if not records:
        raise RestoreError("archive has no members")
    return records


def validated_members(records: list[dict[str, Any]]) -> tuple[str, list[dict[str, Any]]]:
    normalized: list[tuple[dict[str, Any], str]] = []
    for record in records:
        normalized.append((record, normalize_member(str(record["archive_path"]))))
    has_wrapped = any(path == "workspace" or path.startswith("workspace/") for _, path in normalized)
    has_flat = any(path != "workspace" and not path.startswith("workspace/") for _, path in normalized)
    if has_wrapped and has_flat:
        raise RestoreError("archive mixes flat payload with top-level workspace/ payload")
    shape = "wrapped" if has_wrapped else "flat"
    output: list[dict[str, Any]] = []
    seen_exact: set[str] = set()
    seen_folded: dict[str, str] = {}
    types: dict[str, str] = {}
    for record, archive_path in normalized:
        relative = archive_path
        if shape == "wrapped":
            if archive_path == "workspace":
                if record["type"] != "directory":
                    raise RestoreError("top-level workspace member must be a directory")
                continue
            relative = archive_path.removeprefix("workspace/")
        if relative in seen_exact:
            raise RestoreError(f"archive contains duplicate normalized path: {relative!r}")
        folded = unicodedata.normalize("NFC", relative).casefold()
        if folded in seen_folded and seen_folded[folded] != relative:
            raise RestoreError(f"archive contains Unicode/case collision: {relative!r}")
        seen_exact.add(relative)
        seen_folded[folded] = relative
        types[relative] = str(record["type"])
        item = dict(record)
        item["archive_path"] = archive_path
        item["path"] = relative
        output.append(item)
    if not output:
        raise RestoreError("archive payload is empty")
    for path, kind in types.items():
        parts = PurePosixPath(path).parts
        for index in range(1, len(parts)):
            parent = str(PurePosixPath(*parts[:index]))
            if types.get(parent) == "file":
                raise RestoreError(f"archive has file-directory conflict at {parent!r}")
        if kind == "file" and any(other.startswith(path + "/") for other in types):
            raise RestoreError(f"archive has file-directory conflict at {path!r}")
    return shape, sorted(output, key=lambda item: str(item["path"]))


def inventory(path: Path) -> dict[str, Any]:
    if not path.exists() and not path.is_symlink():
        payload = {"exists": False, "entries": []}
    else:
        entries: list[dict[str, Any]] = []
        if not path.is_dir() or path.is_symlink():
            raise RestoreError(f"workspace is not a real directory: {path}")
        for current, dirs, files in os.walk(path, topdown=True, followlinks=False):
            current_path = Path(current)
            names = sorted([*dirs, *files])
            for name in names:
                entry_path = current_path / name
                relative = entry_path.relative_to(path).as_posix()
                info = entry_path.lstat()
                if stat.S_ISDIR(info.st_mode):
                    kind = "directory"
                    content_hash = None
                elif stat.S_ISREG(info.st_mode):
                    kind = "file"
                    content_hash = sha256_file(entry_path)
                elif stat.S_ISLNK(info.st_mode):
                    kind = "symlink"
                    content_hash = os.readlink(entry_path)
                    if name in dirs:
                        dirs.remove(name)
                else:
                    kind = "special"
                    content_hash = None
                entries.append(
                    {
                        "path": relative,
                        "type": kind,
                        "mode": stat.S_IMODE(info.st_mode),
                        "size": info.st_size,
                        "mtime_ns": info.st_mtime_ns,
                        "sha256": content_hash,
                    }
                )
        payload = {"exists": True, "entries": sorted(entries, key=lambda item: str(item["path"]))}
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    payload["inventory_hash"] = hashlib.sha256(encoded).hexdigest()
    payload["file_count"] = sum(item["type"] == "file" for item in payload["entries"])
    return payload


def archive_records(archive: Path) -> list[dict[str, Any]]:
    suffix = archive.suffix.lower()
    if suffix == ".zip":
        return zip_members(archive)
    if suffix == ".7z":
        return seven_zip_members(archive)
    raise RestoreError("archive must have .zip or .7z extension")


def inspect_archive(root: Path, archive: Path, manifest_out: Path) -> dict[str, Any]:
    root = root.expanduser().resolve()
    archive = archive.expanduser().resolve(strict=True)
    if not archive.is_file():
        raise RestoreError(f"archive is not a regular file: {archive}")
    archive_stat = archive.stat()
    shape, members = validated_members(archive_records(archive))
    current = inventory(root / "workspace")
    archive_files = {str(item["path"]) for item in members if item["type"] == "file"}
    local_files = {str(item["path"]) for item in current["entries"] if item["type"] == "file"}
    manifest = {
        "version": VERSION,
        "root": str(root),
        "archive": {
            "path": str(archive),
            "size": archive_stat.st_size,
            "sha256": sha256_file(archive),
        },
        "payload_shape": shape,
        "members": members,
        "workspace": current,
        "local_only": sorted(local_files - archive_files),
    }
    atomic_write_json(manifest_out.expanduser().resolve(), manifest)
    return manifest


def verify_manifest(root: Path, manifest: dict[str, Any]) -> Path:
    if manifest.get("version") != VERSION or manifest.get("root") != str(root):
        raise RestoreError("manifest version or repository root does not match")
    archive_data = manifest.get("archive")
    if not isinstance(archive_data, dict):
        raise RestoreError("manifest archive metadata is missing")
    archive = Path(str(archive_data.get("path", ""))).resolve(strict=True)
    info = archive.stat()
    if info.st_size != archive_data.get("size") or sha256_file(archive) != archive_data.get("sha256"):
        raise RestoreError("archive changed after inspect; inspect and confirm again")
    expected_workspace = manifest.get("workspace")
    if not isinstance(expected_workspace, dict):
        raise RestoreError("manifest workspace metadata is missing")
    if inventory(root / "workspace")["inventory_hash"] != expected_workspace.get("inventory_hash"):
        raise RestoreError("workspace changed after inspect; inspect and confirm again")
    shape, members = validated_members(archive_records(archive))
    if shape != manifest.get("payload_shape") or members != manifest.get("members"):
        raise RestoreError("archive member metadata changed after inspect")
    return archive


def expected_tree(members: list[dict[str, Any]]) -> tuple[set[str], set[str]]:
    files = {str(item["path"]) for item in members if item["type"] == "file"}
    directories = {str(item["path"]) for item in members if item["type"] == "directory"}
    for path in [*files, *directories]:
        parts = PurePosixPath(path).parts
        directories.update(str(PurePosixPath(*parts[:index])) for index in range(1, len(parts)))
    return files, directories


def validate_candidate(candidate: Path, members: list[dict[str, Any]]) -> dict[str, Any]:
    expected_files, expected_dirs = expected_tree(members)
    actual_files: set[str] = set()
    actual_dirs: set[str] = set()
    inodes: set[tuple[int, int]] = set()
    for current, dirs, files in os.walk(candidate, topdown=True, followlinks=False):
        current_path = Path(current)
        for name in [*dirs, *files]:
            path = current_path / name
            relative = path.relative_to(candidate).as_posix()
            info = path.lstat()
            if stat.S_ISDIR(info.st_mode):
                actual_dirs.add(relative)
            elif stat.S_ISREG(info.st_mode):
                inode = (info.st_dev, info.st_ino)
                if info.st_nlink != 1 or inode in inodes:
                    raise RestoreError(f"candidate contains a hard-link alias: {relative!r}")
                inodes.add(inode)
                actual_files.add(relative)
            else:
                raise RestoreError(f"candidate contains a link or special file: {relative!r}")
    if actual_files != expected_files or actual_dirs != expected_dirs:
        raise RestoreError("extracted candidate does not match inspected archive members")
    return inventory(candidate)


def validate_recovery_candidate(candidate: Path, expected_hash: object) -> dict[str, Any]:
    if not candidate.is_dir() or candidate.is_symlink():
        raise RestoreError(f"validated candidate is missing or unsafe: {candidate}")
    inodes: set[tuple[int, int]] = set()
    for current, dirs, files in os.walk(candidate, topdown=True, followlinks=False):
        current_path = Path(current)
        for name in [*dirs, *files]:
            path = current_path / name
            info = path.lstat()
            if stat.S_ISDIR(info.st_mode):
                continue
            if not stat.S_ISREG(info.st_mode):
                raise RestoreError(f"candidate contains a link or special file: {path}")
            inode = (info.st_dev, info.st_ino)
            if info.st_nlink != 1 or inode in inodes:
                raise RestoreError(f"candidate contains a hard-link alias: {path}")
            inodes.add(inode)
    candidate_inventory = inventory(candidate)
    if candidate_inventory["inventory_hash"] != expected_hash:
        raise RestoreError(f"candidate inventory changed after validation: {candidate}")
    return candidate_inventory


def extract_zip(archive: Path, candidate: Path, members: list[dict[str, Any]]) -> None:
    by_archive = {str(item["archive_path"]): item for item in members}
    with zipfile.ZipFile(archive) as source:
        for info in source.infolist():
            normalized = normalize_member(info.filename)
            item = by_archive.get(normalized)
            if item is None and normalized == "workspace":
                continue
            if item is None:
                raise RestoreError(f"zip member was not in inspected manifest: {info.filename!r}")
            destination = candidate / str(item["path"])
            if item["type"] == "directory":
                destination.mkdir(parents=True, exist_ok=True)
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            with source.open(info) as read_handle, destination.open("xb") as write_handle:
                shutil.copyfileobj(read_handle, write_handle)
                write_handle.flush()
                os.fsync(write_handle.fileno())
            mode = item.get("mode")
            if isinstance(mode, int) and mode:
                destination.chmod(mode)


def copy_verified_archive(root: Path, archive: Path, expected_sha256: str, transaction_id: str) -> Path:
    snapshot = root.parent / f".{root.name}-restore-archive-{transaction_id}{archive.suffix.lower()}"
    digest = hashlib.sha256()
    try:
        with archive.open("rb") as source, snapshot.open("xb") as destination:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
                destination.write(chunk)
            destination.flush()
            os.fsync(destination.fileno())
        if digest.hexdigest() != expected_sha256:
            raise RestoreError("archive changed while preparing restore; inspect and confirm again")
        fsync_dir(root.parent)
        return snapshot
    except Exception:
        try:
            snapshot.unlink()
        except FileNotFoundError:
            pass
        raise


def extract_candidate(
    root: Path, archive: Path, manifest: dict[str, Any], transaction_id: str
) -> tuple[Path, dict[str, Any]]:
    parent = root.parent
    candidate = parent / f".{root.name}-restore-candidate-{transaction_id}"
    if candidate.exists():
        raise RestoreError(f"candidate path already exists: {candidate}")
    members = manifest["members"]
    extraction: Path | None = None
    try:
        if archive.suffix.lower() == ".zip":
            candidate.mkdir(mode=0o700)
            extract_zip(archive, candidate, members)
        else:
            extraction = parent / f".{root.name}-restore-extract-{transaction_id}"
            extraction.mkdir(mode=0o700)
            result = subprocess.run(
                [seven_zip_binary(), "x", "-y", f"-o{extraction}", str(archive)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            if result.returncode:
                raise RestoreError(f"7z extraction failed: {result.stderr.strip()}")
            source = extraction / "workspace" if manifest["payload_shape"] == "wrapped" else extraction
            if not source.is_dir() or source.is_symlink():
                raise RestoreError("7z payload root is not a real directory")
            if source == extraction:
                extraction.rename(candidate)
                extraction = None
            else:
                source.rename(candidate)
                extraction.rmdir()
                extraction = None
        candidate_inventory = validate_candidate(candidate, members)
        fsync_dir(candidate)
        fsync_dir(parent)
        return candidate, candidate_inventory
    except Exception:
        # These paths are UUID-scoped and contain only uncommitted archive output.
        for generated in (candidate, extraction):
            if generated and generated.is_dir() and not generated.is_symlink():
                shutil.rmtree(generated)
        raise


def write_journal(root: Path, journal: dict[str, Any]) -> None:
    atomic_write_json(root / JOURNAL_RELATIVE, journal)


def clear_journal(root: Path) -> None:
    journal_path = root / JOURNAL_RELATIVE
    journal_path.unlink()
    fsync_dir(journal_path.parent)


def validate_journal_paths(root: Path, journal: dict[str, Any]) -> dict[str, Path | None]:
    transaction_id = journal.get("transaction_id")
    if not isinstance(transaction_id, str):
        raise RestoreError("restore journal transaction ID is missing")
    try:
        if uuid.UUID(transaction_id).hex != transaction_id:
            raise ValueError
    except ValueError as exc:
        raise RestoreError("restore journal transaction ID is not a canonical UUID") from exc

    expected_candidate = root.parent / f".{root.name}-restore-candidate-{transaction_id}"
    if journal.get("candidate") != str(expected_candidate):
        raise RestoreError("restore journal candidate path is outside its transaction namespace")

    snapshot_timestamp = journal.get("snapshot_timestamp")
    snapshot_dir_raw = journal.get("snapshot_dir")
    snapshot_workspace_raw = journal.get("snapshot_workspace")
    if journal.get("had_old_content"):
        if not isinstance(snapshot_timestamp, str) or not SNAPSHOT_TIMESTAMP_RE.fullmatch(snapshot_timestamp):
            raise RestoreError("restore journal snapshot timestamp is invalid")
        expected_snapshot_dir = root.parent / f"workspace-pre-restore-{snapshot_timestamp}-{transaction_id}"
        expected_snapshot_workspace = expected_snapshot_dir / "workspace"
        if snapshot_dir_raw != str(expected_snapshot_dir):
            raise RestoreError("restore journal snapshot path is outside its transaction namespace")
        if snapshot_workspace_raw != str(expected_snapshot_workspace):
            raise RestoreError("restore journal snapshot workspace path is malformed")
        if expected_snapshot_dir.is_symlink():
            raise RestoreError("restore snapshot directory cannot be a symlink")
    else:
        if snapshot_timestamp is not None or snapshot_dir_raw is not None or snapshot_workspace_raw is not None:
            raise RestoreError("restore journal unexpectedly contains snapshot paths")
        expected_snapshot_dir = None
        expected_snapshot_workspace = None

    if root.parent.resolve() != root.parent or expected_candidate.parent != root.parent:
        raise RestoreError("restore transaction parent is not canonical")
    if expected_candidate.is_symlink():
        raise RestoreError("restore candidate cannot be a symlink")
    return {
        "candidate": expected_candidate,
        "snapshot_dir": expected_snapshot_dir,
        "snapshot_workspace": expected_snapshot_workspace,
    }


def verified_snapshot(journal: dict[str, Any], paths: dict[str, Path | None]) -> Path | None:
    snapshot = paths["snapshot_workspace"]
    if snapshot is None or not snapshot.exists():
        return None
    if not snapshot.is_dir() or snapshot.is_symlink():
        raise RestoreError(f"restore snapshot is missing or unsafe: {snapshot}")
    if inventory(snapshot)["inventory_hash"] != journal.get("old_inventory_hash"):
        raise RestoreError(f"restore snapshot inventory changed: {snapshot}")
    return snapshot


def rollback_snapshot(
    root: Path, journal: dict[str, Any], paths: dict[str, Path | None] | None = None
) -> bool:
    workspace = root / "workspace"
    paths = paths or validate_journal_paths(root, journal)
    if workspace.exists():
        return False
    snapshot = verified_snapshot(journal, paths)
    if snapshot is None:
        return False
    snapshot.rename(workspace)
    fsync_dir(root)
    fsync_dir(snapshot.parent)
    return True


def promote_candidate(root: Path, journal: dict[str, Any]) -> None:
    workspace = root / "workspace"
    paths = validate_journal_paths(root, journal)
    candidate = paths["candidate"]
    assert candidate is not None
    if workspace.exists() or workspace.is_symlink():
        raise RestoreError(
            "foreign workspace appeared during restore; preserving workspace, snapshot, and candidate: "
            f"{workspace}, {journal.get('snapshot_workspace') or 'none'}, {candidate}"
        )
    validate_recovery_candidate(candidate, journal.get("candidate_inventory_hash"))
    candidate.rename(workspace)
    fsync_dir(root)
    fsync_dir(root.parent)
    journal["state"] = "new_promoted"
    write_journal(root, journal)


def finish_promoted(root: Path, journal: dict[str, Any]) -> dict[str, Any]:
    try:
        live = validate_recovery_candidate(root / "workspace", journal.get("candidate_inventory_hash"))
    except RestoreError as exc:
        raise RestoreError(
            "promoted workspace inventory changed; preserving journal and recovery artifacts: "
            f"{root / 'workspace'}, {journal.get('snapshot_workspace') or 'none'}, {journal.get('candidate')}"
        ) from exc
    clear_journal(root)
    return {
        "status": "restored",
        "workspace": str(root / "workspace"),
        "snapshot": journal.get("snapshot_dir"),
        "file_count": live["file_count"],
        "transaction_id": journal["transaction_id"],
    }


def apply_restore(root: Path, manifest_path: Path) -> dict[str, Any]:
    root = root.expanduser().resolve()
    manifest_path = manifest_path.expanduser().resolve(strict=True)
    manifest = load_json(manifest_path)
    verify_manifest(root, manifest)
    try:
        with held(root, timeout_ms=5000):
            archive = verify_manifest(root, manifest)
            journal_path = root / JOURNAL_RELATIVE
            if journal_path.exists():
                raise RestoreError(f"restore journal already exists; run recover: {journal_path}")
            transaction_id = uuid.uuid4().hex
            archive_snapshot = copy_verified_archive(
                root, archive, str(manifest["archive"]["sha256"]), transaction_id
            )
            try:
                candidate, candidate_inventory = extract_candidate(root, archive_snapshot, manifest, transaction_id)
            finally:
                try:
                    archive_snapshot.unlink()
                    fsync_dir(root.parent)
                except FileNotFoundError:
                    pass
            workspace = root / "workspace"
            old_inventory = inventory(workspace)
            has_old_content = bool(old_inventory["entries"])
            snapshot_timestamp = time.strftime("%Y%m%dT%H%M%S")
            snapshot_dir = root.parent / f"workspace-pre-restore-{snapshot_timestamp}-{transaction_id}"
            journal: dict[str, Any] = {
                "version": VERSION,
                "state": "prepared",
                "transaction_id": transaction_id,
                "root": str(root),
                "archive": str(archive),
                "manifest": str(manifest_path),
                "old_inventory_hash": old_inventory["inventory_hash"],
                "candidate": str(candidate),
                "candidate_inventory_hash": candidate_inventory["inventory_hash"],
                "snapshot_timestamp": snapshot_timestamp if has_old_content else None,
                "snapshot_dir": str(snapshot_dir) if has_old_content else None,
                "snapshot_workspace": str(snapshot_dir / "workspace") if has_old_content else None,
                "had_live_workspace": old_inventory["exists"],
                "had_old_content": has_old_content,
            }
            write_journal(root, journal)
            if has_old_content:
                snapshot_dir.mkdir(mode=0o700)
                fsync_dir(root.parent)
                workspace.rename(snapshot_dir / "workspace")
                fsync_dir(root)
                fsync_dir(snapshot_dir)
            elif workspace.exists():
                workspace.rmdir()
                fsync_dir(root)
            journal["state"] = "old_moved"
            write_journal(root, journal)
            try:
                promote_candidate(root, journal)
            except RestoreError as exc:
                paths = validate_journal_paths(root, journal)
                candidate_path = paths["candidate"]
                assert candidate_path is not None
                if rollback_snapshot(root, journal, paths):
                    snapshot_path = paths["snapshot_dir"]
                    if snapshot_path:
                        try:
                            snapshot_path.rmdir()
                        except OSError:
                            pass
                    clear_journal(root)
                    raise RestoreError(
                        f"{exc}; prior workspace restored; candidate retained at {candidate_path}"
                    ) from exc
                raise
            except Exception:
                paths = validate_journal_paths(root, journal)
                if rollback_snapshot(root, journal, paths):
                    candidate_path = paths["candidate"]
                    assert candidate_path is not None
                    if candidate_path.is_dir() and not candidate_path.is_symlink():
                        shutil.rmtree(candidate_path)
                    snapshot_path = paths["snapshot_dir"]
                    if snapshot_path:
                        try:
                            snapshot_path.rmdir()
                        except OSError:
                            pass
                    clear_journal(root)
                raise
            return finish_promoted(root, journal)
    except LockError as exc:
        raise RestoreError(str(exc)) from exc


def discard_prepared(
    root: Path, journal: dict[str, Any], paths: dict[str, Path | None]
) -> dict[str, Any]:
    candidate = paths["candidate"]
    assert candidate is not None
    validate_recovery_candidate(candidate, journal.get("candidate_inventory_hash"))
    if candidate.is_dir():
        shutil.rmtree(candidate)
    clear_journal(root)
    return {"status": "rolled_back", "workspace": str(root / "workspace")}


def finish_rollback(
    root: Path,
    paths: dict[str, Path | None],
    retained_candidate: Path | None = None,
) -> dict[str, Any]:
    snapshot_dir = paths["snapshot_dir"]
    if snapshot_dir is not None:
        try:
            snapshot_dir.rmdir()
        except OSError:
            pass
    clear_journal(root)
    result: dict[str, Any] = {"status": "rolled_back", "workspace": str(root / "workspace")}
    if retained_candidate is not None:
        result["retained_candidate"] = str(retained_candidate)
    return result


def rollback_invalid_candidate(
    root: Path,
    journal: dict[str, Any],
    paths: dict[str, Path | None],
    cause: RestoreError,
) -> dict[str, Any]:
    candidate = paths["candidate"]
    assert candidate is not None
    try:
        rolled_back = rollback_snapshot(root, journal, paths)
    except RestoreError as snapshot_error:
        raise RestoreError(
            "candidate and rollback snapshot both failed validation; preserving recovery artifacts"
        ) from snapshot_error
    if not rolled_back:
        raise RestoreError(
            "candidate failed validation and no verified rollback snapshot is available; "
            "preserving recovery artifacts"
        ) from cause
    return finish_rollback(root, paths, retained_candidate=candidate)


def foreign_workspace_error(root: Path, paths: dict[str, Path | None]) -> RestoreError:
    return RestoreError(
        "foreign workspace blocks recovery; preserving workspace, snapshot, and candidate: "
        f"{root / 'workspace'}, {paths['snapshot_workspace'] or 'none'}, {paths['candidate']}"
    )


def recover_restore(root: Path) -> dict[str, Any]:
    root = root.expanduser().resolve()
    journal_path = root / JOURNAL_RELATIVE
    try:
        with held(root, timeout_ms=5000):
            journal = load_json(journal_path)
            if journal.get("version") != VERSION or journal.get("root") != str(root):
                raise RestoreError("restore journal version or root does not match")
            paths = validate_journal_paths(root, journal)
            candidate = paths["candidate"]
            assert candidate is not None
            state = journal.get("state")
            workspace = root / "workspace"
            if state == "prepared":
                snapshot_dir = paths["snapshot_dir"]
                snapshot_artifact = snapshot_dir is not None and (
                    snapshot_dir.exists() or snapshot_dir.is_symlink()
                )
                if workspace.exists():
                    if not journal.get("had_live_workspace"):
                        raise foreign_workspace_error(root, paths)
                    if inventory(workspace)["inventory_hash"] != journal.get("old_inventory_hash"):
                        raise RestoreError(
                            "prepared restore workspace drifted; preserving workspace, candidate, and journal"
                        )
                    if snapshot_artifact:
                        if (
                            snapshot_dir is None
                            or not snapshot_dir.is_dir()
                            or snapshot_dir.is_symlink()
                            or any(snapshot_dir.iterdir())
                        ):
                            raise foreign_workspace_error(root, paths)
                        validate_recovery_candidate(
                            candidate, journal.get("candidate_inventory_hash")
                        )
                        snapshot_dir.rmdir()
                        fsync_dir(root.parent)
                    return discard_prepared(root, journal, paths)
                if journal.get("had_old_content") and not snapshot_artifact:
                    raise RestoreError(
                        "prepared restore lost its prior workspace snapshot; preserving candidate and journal"
                    )
                try:
                    promote_candidate(root, journal)
                except RestoreError as exc:
                    return rollback_invalid_candidate(root, journal, paths, exc)
                return finish_promoted(root, journal)
            if state == "old_moved":
                if workspace.exists():
                    raise foreign_workspace_error(root, paths)
                if candidate.exists():
                    try:
                        validate_recovery_candidate(candidate, journal.get("candidate_inventory_hash"))
                    except RestoreError as exc:
                        return rollback_invalid_candidate(root, journal, paths, exc)
                    promote_candidate(root, journal)
                    return finish_promoted(root, journal)
                if rollback_snapshot(root, journal, paths):
                    return finish_rollback(root, paths)
                raise RestoreError("candidate and rollback snapshot are both unavailable")
            if state == "new_promoted":
                if workspace.exists():
                    return finish_promoted(root, journal)
                if rollback_snapshot(root, journal, paths):
                    return finish_rollback(root, paths)
                raise RestoreError("promoted workspace and rollback snapshot are both unavailable")
            raise RestoreError(f"unknown restore journal state: {state!r}")
    except LockError as exc:
        raise RestoreError(str(exc)) from exc


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    inspect_parser = subcommands.add_parser("inspect")
    inspect_parser.add_argument("--root", required=True)
    inspect_parser.add_argument("--archive", required=True)
    inspect_parser.add_argument("--manifest-out", required=True)
    apply_parser = subcommands.add_parser("apply")
    apply_parser.add_argument("--root", required=True)
    apply_parser.add_argument("--manifest", required=True)
    recover_parser = subcommands.add_parser("recover")
    recover_parser.add_argument("--root", required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "inspect":
            result = inspect_archive(Path(args.root), Path(args.archive), Path(args.manifest_out))
            print(
                json.dumps(
                    {
                        "manifest": str(Path(args.manifest_out).expanduser().resolve()),
                        "local_only": result["local_only"],
                    }
                )
            )
        elif args.command == "apply":
            print(json.dumps(apply_restore(Path(args.root), Path(args.manifest)), sort_keys=True))
        else:
            print(json.dumps(recover_restore(Path(args.root)), sort_keys=True))
    except (RestoreError, FileNotFoundError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
