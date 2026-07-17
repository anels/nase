#!/usr/bin/env python3
"""Stage and apply durable workspace writes with drift checks."""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from workspace_lock import LockError, held  # noqa: E402


ALLOWED_DIRS = (
    "workspace/kb",
    "workspace/tasks",
    "workspace/skills",
    "workspace/efforts",
    "workspace/journals",
    "workspace/logs",
    ".claude/commands/nase/workspace",
)
ALLOWED_FILES = (
    "workspace/context.md",
    "workspace/communication-style.md",
)
DISALLOWED_DIRS = (
    "workspace/tmp",
)


class GuardError(Exception):
    def __init__(self, message: str, code: int = 2) -> None:
        super().__init__(message)
        self.code = code


def die(message: str, code: int = 2) -> None:
    raise GuardError(message, code)


def relpath(path: Path, root: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return str(path)


def root_path(value: str | None) -> Path:
    if value:
        return Path(value).expanduser().resolve()
    return Path.cwd().resolve()


def resolve_under_root(root: Path, value: str, label: str) -> Path:
    raw = Path(value).expanduser()
    candidate = raw if raw.is_absolute() else root / raw
    resolved = candidate.resolve(strict=False)
    if not resolved.is_relative_to(root):
        die(f"{label} is outside workspace root: {value}")
    return resolved


def lexical_under_root(root: Path, value: str, label: str) -> Path:
    raw = Path(value).expanduser()
    candidate = raw if raw.is_absolute() else root / raw
    lexical = Path(os.path.abspath(candidate))
    if not lexical.is_relative_to(root):
        die(f"{label} is outside workspace root: {value}")
    return lexical


def validate_target(root: Path, value: str) -> Path:
    target = resolve_under_root(root, value, "target")
    rel = relpath(target, root)

    for directory in DISALLOWED_DIRS:
        if target == root / directory or target.is_relative_to(root / directory):
            die(f"target is not a durable workspace path: {rel}")

    if rel in ALLOWED_FILES:
        return target

    for directory in ALLOWED_DIRS:
        allowed = root / directory
        if target.is_relative_to(allowed):
            return target

    die(f"target is not managed by workspace-write-guard: {rel}")
    return target


def validate_staged(root: Path, value: str) -> Path:
    staged = resolve_under_root(root, value, "staged")
    tmp_root = root / "workspace" / "tmp"
    if not staged.is_relative_to(tmp_root):
        die(f"staged file must be under workspace/tmp: {relpath(staged, root)}")
    if not staged.is_file():
        die(f"staged file does not exist: {relpath(staged, root)}")
    return staged


def sha256_file(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def file_state(path: Path) -> dict[str, object]:
    if not path.exists():
        return {"exists": False, "mtime_ns": "missing", "mode": "missing", "sha256": "missing"}
    if not path.is_file():
        die(f"target is not a regular file: {path}")
    stat = path.stat()
    return {
        "exists": True,
        "mtime_ns": str(stat.st_mtime_ns),
        "mode": format(stat.st_mode & 0o7777, "o"),
        "sha256": sha256_file(path),
    }


def slugify(value: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", value.strip())
    slug = slug.strip("-._")
    return slug[:80] or "write"


def staged_path(root: Path, target: Path, skill: str) -> Path:
    tmp_dir = root / "workspace" / "tmp"
    tmp_dir.mkdir(parents=True, exist_ok=True)
    target_slug = slugify(relpath(target, root).replace("/", "-"))
    skill_slug = slugify(skill)
    suffix = target.suffix or ".txt"
    return tmp_dir / f"staged-{skill_slug}-{target_slug}-{time.time_ns()}{suffix}"


def cmd_stage(args: argparse.Namespace) -> None:
    root = root_path(args.root)
    target = validate_target(root, args.target)
    content = resolve_under_root(root, args.content_file, "content file")
    if not content.is_file():
        die(f"content file does not exist: {relpath(content, root)}")

    staged = staged_path(root, target, args.skill)
    shutil.copyfile(content, staged)
    staged_sha256 = sha256_file(staged)

    output = {
        "mode": "stage",
        "target_path": relpath(target, root),
        "target_abs": str(target),
        "staged": relpath(staged, root),
        "staged_abs": str(staged),
        "staged_sha256": staged_sha256,
        "target": file_state(target),
        "diff_command": (
            "python3 .claude/scripts/workspace-write-guard.py diff "
            f"--target {relpath(target, root)} --staged {relpath(staged, root)}"
        ),
    }
    print(json.dumps(output, indent=2, sort_keys=True))


def text_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return path.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)


def cmd_diff(args: argparse.Namespace) -> None:
    root = root_path(args.root)
    target = validate_target(root, args.target)
    staged = validate_staged(root, args.staged)
    diff = difflib.unified_diff(
        text_lines(target),
        text_lines(staged),
        fromfile=relpath(target, root),
        tofile=relpath(staged, root),
    )
    sys.stdout.writelines(diff)


def states_match(state: dict[str, object], expected_mtime_ns: str, expected_sha256: str) -> bool:
    return state["mtime_ns"] == expected_mtime_ns and state["sha256"] == expected_sha256


def require_staged_sha(staged: Path, expected_sha256: str, root: Path) -> None:
    if sha256_file(staged) != expected_sha256:
        die(
            "Staged file changed after review; "
            f"staged file preserved at {relpath(staged, root)}; rerun stage",
            code=3,
        )


def fsync_file(path: Path) -> None:
    with path.open("rb") as handle:
        os.fsync(handle.fileno())


def fsync_dir(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def cmd_apply(args: argparse.Namespace) -> None:
    root = root_path(args.root)
    target = validate_target(root, args.target)
    staged = validate_staged(root, args.staged)
    nonce = f"{os.getpid()}-{time.time_ns()}"
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp_target = target.parent / f".{target.name}.tmp-{nonce}"
    backup = target.parent / f".{target.name}.write-backup-{nonce}"
    claimed = False
    published_identity: tuple[int, int] | None = None

    def restore_backup() -> str:
        if not claimed or not backup.exists():
            return ""
        if target.exists():
            return f"; original preserved at {relpath(backup, root)}"
        try:
            os.link(backup, target)
            fsync_dir(target.parent)
            backup.unlink()
            fsync_dir(target.parent)
            return ""
        except OSError:
            return f"; original preserved at {relpath(backup, root)}"

    try:
        with held(root, timeout_ms=5000):
            require_staged_sha(staged, args.expected_staged_sha256, root)
            shutil.copyfile(staged, tmp_target)
            current = file_state(target)
            mode = int(str(current["mode"]), 8) if current["exists"] else staged.stat().st_mode & 0o7777
            os.chmod(tmp_target, mode)
            fsync_file(tmp_target)
            if sha256_file(tmp_target) != args.expected_staged_sha256:
                die("Staged file changed while copying; staged file preserved", code=3)

            if current["exists"]:
                os.rename(target, backup)
                claimed = True
                claimed_state = file_state(backup)
                if not states_match(claimed_state, args.expected_mtime_ns, args.expected_sha256):
                    note = restore_backup()
                    die(
                        "Target changed while drafting; "
                        f"staged file preserved at {relpath(staged, root)}{note}",
                        code=3,
                    )
            elif not states_match(current, args.expected_mtime_ns, args.expected_sha256):
                die(
                    "Target changed while drafting; "
                    f"staged file preserved at {relpath(staged, root)}",
                    code=3,
                )

            try:
                tmp_stat = tmp_target.stat()
                published_identity = (tmp_stat.st_dev, tmp_stat.st_ino)
                os.link(tmp_target, target)
            except FileExistsError:
                note = restore_backup()
                die(
                    "Target was recreated while applying; "
                    f"staged file preserved at {relpath(staged, root)}{note}",
                    code=5,
                )
            stat = target.stat()
            if (stat.st_dev, stat.st_ino) != published_identity:
                die("Published target was replaced while applying", code=5)
            if sha256_file(target) != args.expected_staged_sha256:
                die("Published target changed while applying", code=5)
            fsync_dir(target.parent)
            if backup.exists():
                backup.unlink()
                fsync_dir(target.parent)
    except LockError as exc:
        die(f"{exc}; staged file preserved at {relpath(staged, root)}", code=5)
    except GuardError:
        if published_identity is not None and target.exists():
            stat = target.stat()
            if (stat.st_dev, stat.st_ino) == published_identity:
                target.unlink()
        restore_backup()
        raise
    except OSError as exc:
        note = restore_backup()
        die(
            f"Apply failed: {exc}; staged file preserved at {relpath(staged, root)}{note}",
            code=5,
        )
    finally:
        if tmp_target.exists():
            tmp_target.unlink()

    output = {
        "applied": True,
        "target": relpath(target, root),
        "target_abs": str(target),
        "staged": relpath(staged, root),
        "target_state": file_state(target),
    }
    print(json.dumps(output, indent=2, sort_keys=True))


def cmd_apply_move_unlocked(args: argparse.Namespace) -> None:
    root = root_path(args.root)
    source = validate_target(root, args.target)
    destination = validate_target(root, args.destination)
    staged = validate_staged(root, args.staged)
    current = file_state(source)
    if not current["exists"]:
        die(
            "Source does not exist; "
            f"staged file preserved at {relpath(staged, root)}",
            code=3,
        )
    if not states_match(current, args.expected_mtime_ns, args.expected_sha256):
        die(
            "Target changed while drafting; "
            f"staged file preserved at {relpath(staged, root)}",
            code=3,
        )
    if destination.exists():
        die(
            "Destination already exists; "
            f"staged file preserved at {relpath(staged, root)}",
            code=4,
        )

    destination.parent.mkdir(parents=True, exist_ok=True)
    nonce = f"{os.getpid()}-{time.time_ns()}"
    tmp_destination = destination.parent / f".{destination.name}.tmp-{nonce}"
    backup_source = source.parent / f".{source.name}.move-backup-{nonce}"
    recovery_source = root / "workspace" / "tmp" / f"move-recovery-{nonce}{source.suffix}"
    rollback_path = root / "workspace" / "tmp" / f"move-rollback-{nonce}{destination.suffix}"
    destination_created = False
    destination_identity: tuple[int, int] | None = None
    source_moved = False
    restored = False
    preserve_backup = False
    committed = False
    staged_sha256 = sha256_file(staged)
    source_mode = int(str(current["mode"]), 8)

    def path_is_created_destination(path: Path) -> bool:
        if not destination_created or destination_identity is None:
            return False
        try:
            stat = path.stat()
            return (
                (stat.st_dev, stat.st_ino) == destination_identity
                and (stat.st_mode & 0o7777) == source_mode
                and sha256_file(path) == staged_sha256
            )
        except OSError:
            return False

    def created_destination_is_intact() -> bool:
        return path_is_created_destination(destination)

    def restore_source() -> tuple[bool, bool]:
        if source.exists():
            return False, False
        candidate = backup_source if backup_source.exists() else recovery_source
        if not candidate.exists():
            return False, False
        try:
            os.link(candidate, source)
        except OSError:
            if not candidate.is_dir():
                return False, False
            try:
                shutil.copytree(candidate, source)
                fsync_dir(source.parent)
            except OSError:
                return False, False
            return True, True
        try:
            fsync_dir(source.parent)
        except OSError:
            return False, False
        return True, False

    def rollback_destination() -> tuple[bool, Path | None]:
        if not destination_created:
            return False, None
        try:
            os.rename(destination, rollback_path)
        except OSError:
            return False, None
        try:
            fsync_dir(destination.parent)
            if rollback_path.parent != destination.parent:
                fsync_dir(rollback_path.parent)
        except OSError:
            return False, rollback_path
        return True, rollback_path

    def abort(message: str, code: int) -> None:
        nonlocal preserve_backup, restored
        restored, preserve_backup = restore_source()
        destination_rolled_back, displaced_destination = rollback_destination()
        recovery_note = ""
        if source_moved and (not restored or preserve_backup):
            preserved = backup_source if backup_source.exists() else recovery_source
            recovery_note = f"; original preserved at {relpath(preserved, root)}"
        destination_note = ""
        if displaced_destination is not None:
            destination_note = (
                "; rolled-back destination preserved at "
                f"{relpath(displaced_destination, root)}"
            )
        elif destination_created and not destination_rolled_back and destination.exists():
            destination_note = f"; destination preserved at {relpath(destination, root)}"
        raise GuardError(
            f"{message}; staged file preserved at {relpath(staged, root)}"
            f"{recovery_note}{destination_note}",
            code,
        )

    try:
        shutil.copyfile(staged, tmp_destination)
        os.chmod(tmp_destination, source_mode)
        fsync_file(tmp_destination)
        stat = tmp_destination.stat()
        destination_identity = (stat.st_dev, stat.st_ino)
        os.link(tmp_destination, destination)
        destination_created = True
        fsync_dir(destination.parent)
        tmp_destination.unlink()
        fsync_dir(destination.parent)
        if not created_destination_is_intact():
            abort("Destination changed while moving", 5)

        os.rename(source, backup_source)
        source_moved = True
        fsync_dir(source.parent)
        try:
            backup_state = file_state(backup_source)
        except GuardError as exc:
            abort(str(exc), exc.code)
        if (
            not states_match(backup_state, args.expected_mtime_ns, args.expected_sha256)
            or int(str(backup_state["mode"]), 8) != source_mode
        ):
            abort("Target changed while moving", 3)

        shutil.copy2(backup_source, recovery_source)
        fsync_file(recovery_source)
        fsync_dir(recovery_source.parent)
        try:
            backup_state = file_state(backup_source)
        except GuardError as exc:
            abort(str(exc), exc.code)
        if (
            not states_match(backup_state, args.expected_mtime_ns, args.expected_sha256)
            or int(str(backup_state["mode"]), 8) != source_mode
        ):
            abort("Target changed while preserving recovery copy", 3)

        if source.exists():
            abort("Source path was recreated while moving", 5)
        if not created_destination_is_intact():
            abort("Destination changed while moving", 5)

        backup_source.unlink()
        fsync_dir(source.parent)
        if source.exists():
            abort("Source path was recreated while committing move", 5)
        if not created_destination_is_intact():
            abort("Destination changed while committing move", 5)
        committed = True
    except FileExistsError:
        abort("Destination already exists", 4)
    except OSError as exc:
        abort(f"Move failed: {exc}", 5)
    finally:
        if tmp_destination.exists():
            tmp_destination.unlink()
        if (committed or (restored and not preserve_backup)) and backup_source.exists():
            backup_source.unlink()
        if (committed or (restored and not preserve_backup)) and recovery_source.exists():
            recovery_source.unlink()

    output = {
        "applied": True,
        "source": relpath(source, root),
        "destination": relpath(destination, root),
        "staged": relpath(staged, root),
        "destination_state": file_state(destination),
    }
    print(json.dumps(output, indent=2, sort_keys=True))


def cmd_apply_move(args: argparse.Namespace) -> None:
    root = root_path(args.root)
    staged = validate_staged(root, args.staged)
    try:
        with held(root, timeout_ms=5000):
            require_staged_sha(staged, args.expected_staged_sha256, root)
            cmd_apply_move_unlocked(args)
    except LockError as exc:
        die(f"{exc}; staged file preserved at {relpath(staged, root)}", code=5)


def cmd_move_existing(args: argparse.Namespace) -> None:
    root = root_path(args.root)
    lexical_source = lexical_under_root(root, args.target, "target")
    source = validate_target(root, args.target)
    destination = validate_target(root, args.destination)
    try:
        with held(root, timeout_ms=args.lock_timeout_ms):
            try:
                source_mode = lexical_source.lstat().st_mode
            except OSError as exc:
                die(f"Source cannot be inspected: {relpath(lexical_source, root)}: {exc}", code=3)
            if (
                lexical_source != source
                or not stat.S_ISREG(source_mode)
                or lexical_source.suffix != ".md"
            ):
                die(
                    "Source must be a lexical regular .md file: "
                    f"{relpath(lexical_source, root)}",
                    code=3,
                )
            age_seconds = time.time() - source.stat().st_mtime
            if age_seconds <= args.older_than_days * 86400:
                die(f"Source is not older than {args.older_than_days} days", code=3)
            if destination.exists():
                die(f"Destination already exists: {relpath(destination, root)}", code=4)
            state = file_state(source)
            staged = staged_path(root, source, "archive-existing")
            shutil.copyfile(source, staged)
            move_args = argparse.Namespace(
                root=str(root),
                target=relpath(source, root),
                destination=relpath(destination, root),
                staged=relpath(staged, root),
                expected_mtime_ns=state["mtime_ns"],
                expected_sha256=state["sha256"],
                expected_staged_sha256=sha256_file(staged),
            )
            cmd_apply_move_unlocked(move_args)
            staged.unlink(missing_ok=True)
    except LockError as exc:
        die(str(exc), code=5)
    except GuardError:
        raise
    except OSError as exc:
        die(f"Move failed: {exc}", code=5)
    print(
        json.dumps(
            {
                "moved": True,
                "source": relpath(source, root),
                "destination": relpath(destination, root),
                "destination_state": file_state(destination),
            },
            indent=2,
            sort_keys=True,
        )
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    stage = sub.add_parser("stage", help="Stage a proposed full-file replacement.")
    stage.add_argument("--root", default=None)
    stage.add_argument("--target", required=True)
    stage.add_argument("--content-file", required=True)
    stage.add_argument("--skill", required=True)
    stage.set_defaults(func=cmd_stage)

    diff = sub.add_parser("diff", help="Print a unified diff from target to staged file.")
    diff.add_argument("--root", default=None)
    diff.add_argument("--target", required=True)
    diff.add_argument("--staged", required=True)
    diff.set_defaults(func=cmd_diff)

    apply = sub.add_parser("apply", help="Apply a staged file if target metadata still matches.")
    apply.add_argument("--root", default=None)
    apply.add_argument("--target", required=True)
    apply.add_argument("--staged", required=True)
    apply.add_argument("--expected-mtime-ns", required=True)
    apply.add_argument("--expected-sha256", required=True)
    apply.add_argument("--expected-staged-sha256", required=True)
    apply.set_defaults(func=cmd_apply)

    apply_move = sub.add_parser(
        "apply-move",
        help="Apply a staged file at a new path without overwriting an existing file.",
    )
    apply_move.add_argument("--root", default=None)
    apply_move.add_argument("--target", required=True)
    apply_move.add_argument("--destination", required=True)
    apply_move.add_argument("--staged", required=True)
    apply_move.add_argument("--expected-mtime-ns", required=True)
    apply_move.add_argument("--expected-sha256", required=True)
    apply_move.add_argument("--expected-staged-sha256", required=True)
    apply_move.set_defaults(func=cmd_apply_move)

    move_existing = sub.add_parser(
        "move-existing",
        help="Move an old file without overwriting an existing destination.",
    )
    move_existing.add_argument("--root", default=None)
    move_existing.add_argument("--target", required=True)
    move_existing.add_argument("--destination", required=True)
    move_existing.add_argument("--older-than-days", type=int, required=True)
    move_existing.add_argument("--lock-timeout-ms", type=int, default=5000)
    move_existing.set_defaults(func=cmd_move_existing)

    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        args.func(args)
        return 0
    except GuardError as exc:
        print(str(exc), file=sys.stderr)
        return exc.code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
