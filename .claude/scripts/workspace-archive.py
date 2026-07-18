#!/usr/bin/env python3
"""Archive stale workspace sections without deleting source data first."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from workspace_lock import LockBusyError, LockError, held  # noqa: E402


LESSONS_HEADER = (
    "# Lessons Archive\n\n"
    "> Promoted lessons older than 90 days. Moved here by pre-compact-archive.sh.\n\n"
)
MARKER_PREFIX = "<!-- nase-archive:"
JOURNAL_VERSION = 1
LESSONS_PATTERN = re.compile(r"(?m)^## [a-z]+ -- (\d{4}-\d{2}-\d{2})")
SECTION_PATTERN = re.compile(r"(?m)^## ")
TECH_TRENDS_PATTERN = re.compile(
    r"(?m)^## Tech Digest \u2014 (\d{4}-\d{2}-\d{2})"
)
MARKER_PATTERN = re.compile(
    r"<!-- nase-archive:([0-9a-f]{64}) source=([0-9a-f]{64}) "
    r"offset=(\d+) occurrence=(\d+) content-occurrence=(\d+) "
    r"section=([0-9a-f]{64}) -->\n"
)


class ArchiveError(RuntimeError):
    pass


@dataclass(frozen=True)
class Section:
    text: str
    date: datetime | None
    offset: int
    occurrence: int
    content_occurrence: int


def sha256_bytes(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def fsync_dir(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def safe_parent(root: Path, path: Path, *, create: bool = False) -> Path:
    lexical_root = Path(os.path.abspath(root))
    lexical_path = Path(os.path.abspath(path))
    if not lexical_path.is_relative_to(lexical_root):
        raise ArchiveError(f"archive path is outside repository root: {path}")
    try:
        root_metadata = lexical_root.lstat()
    except OSError as exc:
        raise ArchiveError(f"repository root cannot be inspected: {lexical_root}: {exc}") from exc
    if not stat.S_ISDIR(root_metadata.st_mode) or lexical_root.is_symlink():
        raise ArchiveError(f"repository root is not a lexical directory: {lexical_root}")
    current = lexical_root
    for part in lexical_path.relative_to(lexical_root).parts[:-1]:
        current /= part
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            if not create:
                raise ArchiveError(f"archive parent does not exist: {current}")
            current.mkdir()
            metadata = current.lstat()
        except OSError as exc:
            raise ArchiveError(f"archive parent cannot be inspected: {current}: {exc}") from exc
        if not stat.S_ISDIR(metadata.st_mode) or current.is_symlink():
            raise ArchiveError(f"archive parent is not a lexical directory: {current}")
    return lexical_path


def open_safe_regular(root: Path, path: Path, label: str) -> int:
    lexical_path = safe_parent(root, path)
    try:
        metadata = lexical_path.lstat()
    except OSError as exc:
        raise ArchiveError(f"{label} cannot be inspected: {lexical_path}: {exc}") from exc
    if not stat.S_ISREG(metadata.st_mode) or lexical_path.is_symlink():
        raise ArchiveError(f"{label} is not a lexical regular file: {lexical_path}")
    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(lexical_path, flags)
    except OSError as exc:
        raise ArchiveError(f"{label} cannot be opened safely: {lexical_path}: {exc}") from exc
    opened = os.fstat(descriptor)
    if (
        not stat.S_ISREG(opened.st_mode)
        or opened.st_dev != metadata.st_dev
        or opened.st_ino != metadata.st_ino
    ):
        os.close(descriptor)
        raise ArchiveError(f"{label} changed while opening: {lexical_path}")
    return descriptor


def read_safe_regular(
    root: Path,
    path: Path,
    label: str,
    *,
    missing_ok: bool = False,
    create_parent: bool = False,
) -> bytes | None:
    state = read_safe_regular_state(
        root, path, label, missing_ok=missing_ok, create_parent=create_parent
    )
    return state[0] if state is not None else None


def read_safe_regular_state(
    root: Path,
    path: Path,
    label: str,
    *,
    missing_ok: bool = False,
    create_parent: bool = False,
) -> tuple[bytes, os.stat_result] | None:
    lexical_path = safe_parent(root, path, create=create_parent)
    try:
        lexical_path.lstat()
    except FileNotFoundError:
        if missing_ok:
            return None
        raise ArchiveError(f"{label} does not exist: {lexical_path}")
    descriptor = open_safe_regular(root, lexical_path, label)
    with os.fdopen(descriptor, "rb") as handle:
        return handle.read(), os.fstat(handle.fileno())


def matches_safe_snapshot(
    root: Path,
    path: Path,
    snapshot: tuple[bytes, os.stat_result] | None,
    label: str,
) -> bool:
    current = read_safe_regular_state(
        root, path, label, missing_ok=True, create_parent=True
    )
    if snapshot is None:
        return current is None
    if current is None:
        return False
    original_bytes, original_metadata = snapshot
    current_bytes, current_metadata = current
    return (
        current_metadata.st_dev == original_metadata.st_dev
        and current_metadata.st_ino == original_metadata.st_ino
        and current_metadata.st_mtime_ns == original_metadata.st_mtime_ns
        and sha256_bytes(current_bytes) == sha256_bytes(original_bytes)
    )


def fsync_file(root: Path, path: Path, label: str) -> None:
    descriptor = open_safe_regular(root, path, label)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def recover_orphaned_backup(root: Path, path: Path, label: str) -> None:
    lexical_path = safe_parent(root, path, create=True)
    if os.path.lexists(lexical_path):
        return
    backups: list[Path] = []
    for candidate in lexical_path.parent.glob(f".{lexical_path.name}.backup-*"):
        try:
            metadata = candidate.lstat()
        except OSError as exc:
            raise ArchiveError(f"{label} backup cannot be inspected: {candidate}: {exc}") from exc
        if stat.S_ISREG(metadata.st_mode):
            backups.append(candidate)
    if not backups:
        return
    if len(backups) != 1:
        raise ArchiveError(f"{label} has multiple orphaned backups: {lexical_path}")
    backup = backups[0]
    try:
        os.link(backup, lexical_path, follow_symlinks=False)
    except FileExistsError:
        return
    fsync_dir(lexical_path.parent)
    backup.unlink()
    fsync_dir(lexical_path.parent)


def snapshot_matches(path: Path, snapshot: tuple[bytes, os.stat_result] | None) -> bool:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return snapshot is None
    if snapshot is None or not stat.S_ISREG(metadata.st_mode):
        return False
    original_bytes, original_metadata = snapshot
    if (
        metadata.st_dev != original_metadata.st_dev
        or metadata.st_ino != original_metadata.st_ino
        or metadata.st_mtime_ns != original_metadata.st_mtime_ns
    ):
        return False
    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0)
    with os.fdopen(os.open(path, flags), "rb") as handle:
        return sha256_bytes(handle.read()) == sha256_bytes(original_bytes)


def atomic_replace(
    path: Path,
    content: bytes,
    validate,
    snapshot: tuple[bytes, os.stat_result] | None,
) -> None:
    try:
        existing = path.lstat()
    except FileNotFoundError:
        mode = 0o644
    else:
        if not stat.S_ISREG(existing.st_mode):
            raise ArchiveError(f"replacement target is not a lexical regular file: {path}")
        mode = stat.S_IMODE(existing.st_mode)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.tmp-", dir=path.parent)
    tmp = Path(tmp_name)
    backup = path.with_name(f".{path.name}.backup-{uuid.uuid4().hex}")
    claimed = False
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        validate(tmp)
        if snapshot is None:
            try:
                os.link(tmp, path, follow_symlinks=False)
            except FileExistsError as exc:
                raise ArchiveError(f"replacement target appeared before publish: {path}") from exc
        else:
            try:
                os.rename(path, backup)
            except FileNotFoundError as exc:
                raise ArchiveError(f"replacement target disappeared before publish: {path}") from exc
            claimed = True
            if not snapshot_matches(backup, snapshot):
                try:
                    os.link(backup, path, follow_symlinks=False)
                    backup.unlink()
                    claimed = False
                except FileExistsError:
                    pass
                raise ArchiveError(f"replacement target changed before publish: {path}")
            try:
                os.link(tmp, path, follow_symlinks=False)
            except FileExistsError as exc:
                raise ArchiveError(f"replacement target reappeared before publish: {path}") from exc
            backup.unlink()
            claimed = False
        fsync_dir(path.parent)
    finally:
        tmp.unlink(missing_ok=True)
        if claimed:
            try:
                if not os.path.lexists(path):
                    os.link(backup, path, follow_symlinks=False)
                    backup.unlink()
            except OSError:
                pass


def parse_sections(text: str, pattern: re.Pattern[str]) -> tuple[str, list[Section]]:
    matches = list(SECTION_PATTERN.finditer(text))
    if not matches:
        return text, []
    sections: list[Section] = []
    content_counts: dict[str, int] = {}
    canonical_occurrence = 0
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        section_text = text[match.start() : end]
        dated = pattern.match(text, match.start())
        if dated is None:
            date = None
            occurrence = -1
            content_occurrence = -1
        else:
            date = datetime.strptime(dated.group(1), "%Y-%m-%d")
            section_sha = sha256_bytes(section_text.encode("utf-8"))
            occurrence = canonical_occurrence
            content_occurrence = content_counts.get(section_sha, 0)
            content_counts[section_sha] = content_occurrence + 1
            canonical_occurrence += 1
        sections.append(
            Section(
                text=section_text,
                date=date,
                offset=len(text[: match.start()].encode("utf-8")),
                occurrence=occurrence,
                content_occurrence=content_occurrence,
            )
        )
    return text[: matches[0].start()], sections


def marker(transaction_id: str, sequence: int, source_sha: str, section: Section) -> str:
    section_sha = sha256_bytes(section.text.encode("utf-8"))
    transaction = hashlib.sha256(
        f"{transaction_id}:{sequence}".encode("ascii")
    ).hexdigest()
    return (
        f"{MARKER_PREFIX}{transaction} source={source_sha} offset={section.offset} "
        f"occurrence={section.occurrence} content-occurrence={section.content_occurrence} "
        f"section={section_sha} -->\n"
    )


def marker_identity(value: str) -> str:
    return value.split(" source=", 1)[0]


def entry_is_intact(content: str, value: str, section_text: str) -> bool:
    identity = marker_identity(value)
    if content.count(identity) != 1:
        return False
    marker_start = content.index(identity)
    marker_end = content.find("\n", marker_start)
    if marker_end < 0:
        return False
    marker_line = content[marker_start:marker_end]
    return marker_line == value.rstrip("\n") and content.startswith(
        section_text, marker_end + 1
    )


def append_sections(
    root: Path, path: Path, header: str, entries: list[tuple[str, str]]
) -> None:
    recover_orphaned_backup(root, path, "archive")
    original_state = read_safe_regular_state(
        root, path, "archive", missing_ok=True, create_parent=True
    )
    original_bytes = original_state[0] if original_state is not None else None
    original = original_bytes.decode("utf-8") if original_bytes is not None else header
    for value, section_text in entries:
        if marker_identity(value) in original and not entry_is_intact(
            original, value, section_text
        ):
            raise ArchiveError(f"archive entry validation failed for {path}")
    additions = [
        value + section_text
        for value, section_text in entries
        if marker_identity(value) not in original
    ]
    if not additions:
        fsync_file(root, path, "archive")
        fsync_dir(path.parent)
        return
    content = (original + "".join(additions)).encode("utf-8")

    def validate(tmp: Path) -> None:
        written = tmp.read_text(encoding="utf-8")
        if any(
            not entry_is_intact(written, value, section_text)
            for value, section_text in entries
        ):
            raise ArchiveError(f"archive validation failed for {path}")
        if not matches_safe_snapshot(root, path, original_state, "archive"):
            raise ArchiveError(f"archive changed before publish: {path}")
        safe_parent(root, path)

    atomic_replace(path, content, validate, original_state)


def journal_path(root: Path, kind: str) -> Path:
    return root / ".nase-locks" / f"workspace-archive-{kind}.json"


def load_journal(root: Path, kind: str, source: Path) -> dict[str, object] | None:
    path = journal_path(root, kind)
    raw = read_safe_regular(
        root, path, "archive journal", missing_ok=True, create_parent=True
    )
    if raw is None:
        return None
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ArchiveError(f"archive journal is unreadable: {path}: {exc}") from exc
    if (
        not isinstance(data, dict)
        or data.get("version") != JOURNAL_VERSION
        or data.get("kind") != kind
        or data.get("source") != source.relative_to(root).as_posix()
        or not isinstance(data.get("transaction_id"), str)
        or re.fullmatch(r"[0-9a-f]{32}", data["transaction_id"]) is None
        or not isinstance(data.get("source_sha"), str)
        or re.fullmatch(r"[0-9a-f]{64}", data["source_sha"]) is None
        or not isinstance(data.get("cleaned_sha"), str)
        or re.fullmatch(r"[0-9a-f]{64}", data["cleaned_sha"]) is None
        or not isinstance(data.get("cleaned_text"), str)
        or type(data.get("source_mtime_ns")) is not int
        or data["source_mtime_ns"] < 0
        or not isinstance(data.get("entries"), list)
    ):
        raise ArchiveError(f"archive journal has invalid metadata: {path}")
    try:
        cleaned_sha = sha256_bytes(data["cleaned_text"].encode("utf-8"))
    except UnicodeEncodeError as exc:
        raise ArchiveError(f"archive journal after-image is invalid: {path}") from exc
    if cleaned_sha != data["cleaned_sha"]:
        raise ArchiveError(f"archive journal after-image hash is invalid: {path}")
    for sequence, entry in enumerate(data["entries"]):
        if not isinstance(entry, dict) or not all(
            isinstance(entry.get(key), expected)
            for key, expected in (
                ("sequence", int),
                ("marker", str),
                ("section_sha", str),
                ("text", str),
                ("destination", str),
                ("header", str),
            )
        ):
            raise ArchiveError(f"archive journal has invalid entries: {path}")
        if type(entry["sequence"]) is not int or entry["sequence"] != sequence:
            raise ArchiveError(f"archive journal sequence is invalid: {path}")
        destination = (root / entry["destination"]).resolve(strict=False)
        if not destination.is_relative_to((root / "workspace").resolve(strict=False)):
            raise ArchiveError(f"archive journal destination is invalid: {destination}")
        if kind == "lessons":
            valid_destination = entry["destination"] == "workspace/tasks/lessons-archive.md"
            valid_header = entry["header"] == LESSONS_HEADER
        else:
            match = re.fullmatch(
                r"workspace/kb/general/tech-trends-archive-(\d{4})\.md",
                entry["destination"],
            )
            valid_destination = match is not None
            valid_header = bool(
                match and entry["header"] == f"# Tech Trends Archive \u2014 {match.group(1)}\n"
            )
            section_year = re.match(
                r"^## Tech Digest \u2014 (\d{4})-\d{2}-\d{2}", entry["text"]
            )
            valid_destination = bool(
                valid_destination and section_year and section_year.group(1) == match.group(1)
            )
        if not valid_destination or not valid_header:
            raise ArchiveError(f"archive journal target is invalid: {path}")
        if sha256_bytes(entry["text"].encode("utf-8")) != entry["section_sha"]:
            raise ArchiveError(f"archive journal section hash is invalid: {path}")
        marker_match = MARKER_PATTERN.fullmatch(entry["marker"])
        expected_identity = hashlib.sha256(
            f"{data['transaction_id']}:{sequence}".encode("ascii")
        ).hexdigest()
        if (
            marker_match is None
            or marker_match.group(1) != expected_identity
            or marker_match.group(2) != data["source_sha"]
            or marker_match.group(6) != entry["section_sha"]
        ):
            raise ArchiveError(f"archive journal marker is invalid: {path}")
    return data


def write_journal(root: Path, kind: str, data: dict[str, object]) -> None:
    path = journal_path(root, kind)
    safe_parent(root, path, create=True)
    if read_safe_regular_state(
        root, path, "archive journal", missing_ok=True, create_parent=True
    ) is not None:
        raise ArchiveError(f"archive transaction already exists: {path}")
    encoded = (json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode(
        "utf-8"
    )

    def validate(tmp: Path) -> None:
        if json.loads(tmp.read_text(encoding="utf-8")) != data:
            raise ArchiveError(f"archive journal validation failed: {path}")
        safe_parent(root, path)

    atomic_replace(path, encoded, validate, None)


def delete_journal(root: Path, kind: str) -> None:
    path = journal_path(root, kind)
    descriptor = open_safe_regular(root, path, "archive journal")
    os.close(descriptor)
    path.unlink()
    fsync_dir(path.parent)


def prove_existing_archives(root: Path, data: dict[str, object]) -> None:
    grouped: dict[str, list[tuple[str, str]]] = {}
    entries = data["entries"]
    assert isinstance(entries, list)
    for entry in entries:
        assert isinstance(entry, dict)
        grouped.setdefault(str(entry["destination"]), []).append(
            (str(entry["marker"]), str(entry["text"]))
        )
    for destination, values in sorted(grouped.items()):
        path = root / destination
        content = read_safe_regular(root, path, "archive")
        assert content is not None
        decoded = content.decode("utf-8")
        if any(
            not entry_is_intact(decoded, value, section_text)
            for value, section_text in values
        ):
            raise ArchiveError(f"archive proof failed for {path}")
        fsync_file(root, path, "archive")
        fsync_dir(path.parent)


def pending_snapshot_state(
    source: Path,
    source_sha: str,
    source_mtime_ns: int,
    data: dict[str, object],
) -> str:
    if source_sha == data["cleaned_sha"]:
        return "cleaned"
    if (
        source_sha != data["source_sha"]
        or source_mtime_ns != data["source_mtime_ns"]
    ):
        raise ArchiveError(
            "source changed after archive commit; source and journal preserved; "
            f"transaction={data['transaction_id']}"
        )
    return "original"


def delete_journal_after_cleanup(
    root: Path, kind: str, source: Path, data: dict[str, object]
) -> None:
    try:
        metadata = source.lstat()
    except OSError as exc:
        raise ArchiveError(
            "cleaned source is unavailable; journal preserved; "
            f"transaction={data['transaction_id']}: {exc}"
        ) from exc
    if (
        not stat.S_ISREG(metadata.st_mode)
        or source.is_symlink()
        or sha256_file(source) != data["cleaned_sha"]
    ):
        raise ArchiveError(
            "source cleanup does not match the intended after-image; journal preserved; "
            f"transaction={data['transaction_id']}"
        )
    delete_journal(root, kind)


def prepare_journal(
    root: Path,
    kind: str,
    source: Path,
    source_sha: str,
    source_mtime_ns: int,
    cleaned_content: str,
    selected: list[Section],
    destination_for,
    header_for,
) -> dict[str, object]:
    if load_journal(root, kind, source) is not None:
        raise ArchiveError(f"archive transaction already exists: {journal_path(root, kind)}")
    data = {
        "version": JOURNAL_VERSION,
        "kind": kind,
        "source": source.relative_to(root).as_posix(),
        "transaction_id": uuid.uuid4().hex,
        "source_sha": source_sha,
        "cleaned_sha": sha256_bytes(cleaned_content.encode("utf-8")),
        "cleaned_text": cleaned_content,
        "source_mtime_ns": source_mtime_ns,
        "entries": [],
    }
    entries = data["entries"]
    assert isinstance(entries, list)
    for section in selected:
        section_sha = sha256_bytes(section.text.encode("utf-8"))
        sequence = len(entries)
        destination = destination_for(section)
        entries.append(
            {
                "sequence": sequence,
                "marker": marker(
                    str(data["transaction_id"]), sequence, source_sha, section
                ),
                "section_sha": section_sha,
                "text": section.text,
                "destination": destination.relative_to(root).as_posix(),
                "header": header_for(section),
            }
        )
    write_journal(root, kind, data)
    return data


def derive_cleaned_content(
    kind: str, source_text: str, data: dict[str, object]
) -> str:
    pattern = LESSONS_PATTERN if kind == "lessons" else TECH_TRENDS_PATTERN
    preamble, sections = parse_sections(source_text, pattern)
    entries = data["entries"]
    assert isinstance(entries, list)
    selected_occurrences: set[int] = set()
    for entry in entries:
        assert isinstance(entry, dict)
        marker_match = MARKER_PATTERN.fullmatch(str(entry["marker"]))
        if marker_match is None:
            raise ArchiveError("archive journal marker cannot derive source cleanup")
        occurrence = int(marker_match.group(4))
        offset = int(marker_match.group(3))
        section = next((value for value in sections if value.offset == offset), None)
        if section is None or occurrence in selected_occurrences:
            raise ArchiveError("archive journal occurrence cannot derive source cleanup")
        if (
            section.date is None
            or section.occurrence != occurrence
            or section.content_occurrence != int(marker_match.group(5))
            or section.text != entry["text"]
            or sha256_bytes(section.text.encode("utf-8")) != entry["section_sha"]
            or (kind == "lessons" and "> Promoted \u2192" not in section.text)
        ):
            raise ArchiveError("archive journal section cannot derive source cleanup")
        selected_occurrences.add(occurrence)
    derived = preamble + "".join(
        section.text
        for section in sections
        if section.occurrence not in selected_occurrences
    )
    if (
        derived != data["cleaned_text"]
        or sha256_bytes(derived.encode("utf-8")) != data["cleaned_sha"]
    ):
        raise ArchiveError("archive journal after-image does not match its removal plan")
    return derived


def commit_archives(root: Path, data: dict[str, object]) -> None:
    grouped: dict[tuple[str, str], list[tuple[str, str]]] = {}
    entries = data["entries"]
    assert isinstance(entries, list)
    for entry in entries:
        assert isinstance(entry, dict)
        key = (str(entry["destination"]), str(entry["header"]))
        grouped.setdefault(key, []).append((str(entry["marker"]), str(entry["text"])))
    for (destination, header), values in sorted(grouped.items()):
        append_sections(root, root / destination, header, values)


def replace_source(
    root: Path,
    path: Path,
    content: str,
    original_sha: str,
    original_mtime_ns: int,
    original_state: tuple[bytes, os.stat_result],
) -> None:
    source_state = read_safe_regular_state(root, path, "archive source")
    assert source_state is not None
    current_bytes, current_metadata = source_state
    if (
        current_metadata.st_mtime_ns != original_mtime_ns
        or sha256_bytes(current_bytes) != original_sha
    ):
        raise ArchiveError(
            f"source changed after archive commit; source preserved; transaction source={original_sha}"
        )
    encoded = content.encode("utf-8")
    expected_sha = sha256_bytes(encoded)

    def validate(tmp: Path) -> None:
        if sha256_file(tmp) != expected_sha:
            raise ArchiveError(f"source validation failed for {path}")

    safe_parent(root, path)
    atomic_replace(path, encoded, validate, original_state)


def rotate_lessons(root: Path) -> int:
    source = root / "workspace/tasks/lessons.md"
    destination = root / "workspace/tasks/lessons-archive.md"
    pending = load_journal(root, "lessons", source)
    if pending is not None:
        recover_orphaned_backup(root, source, "archive source")
    source_state = read_safe_regular_state(root, source, "archive source", missing_ok=True)
    if source_state is None:
        if pending is not None:
            raise ArchiveError(
                "source no longer matches pending archive transaction; "
                f"journal preserved; transaction={pending['transaction_id']}"
        )
        return 0
    raw, source_metadata = source_state
    source_sha = sha256_bytes(raw)
    source_mtime_ns = source_metadata.st_mtime_ns
    if pending is not None:
        state = pending_snapshot_state(source, source_sha, source_mtime_ns, pending)
        if state == "cleaned":
            prove_existing_archives(root, pending)
            delete_journal_after_cleanup(root, "lessons", source, pending)
            return 0
        cleaned_content = derive_cleaned_content(
            "lessons", raw.decode("utf-8"), pending
        )
        commit_archives(root, pending)
        selected_count = len(pending["entries"])
        replace_source(
            root, source, cleaned_content, source_sha, source_mtime_ns, source_state
        )
        delete_journal_after_cleanup(root, "lessons", source, pending)
        print(
            f"[pre-compact] archived {selected_count} promoted lesson(s) older than 90 days"
        )
        return selected_count
    preamble, sections = parse_sections(
        raw.decode("utf-8"), LESSONS_PATTERN
    )
    cutoff = datetime.now() - timedelta(days=90)
    selected = [
        section
        for section in sections
        if section.date is not None
        and section.date < cutoff
        and "> Promoted \u2192" in section.text
    ]
    selected_occurrences = {s.occurrence for s in selected}
    cleaned_content = preamble + "".join(
        s.text for s in sections if s.occurrence not in selected_occurrences
    )
    if not selected:
        return 0
    transaction = prepare_journal(
        root,
        "lessons",
        source,
        source_sha,
        source_mtime_ns,
        cleaned_content,
        selected,
        lambda _section: destination,
        lambda _section: LESSONS_HEADER,
    )
    commit_archives(root, transaction)
    selected_count = len(selected)
    replace_source(
        root,
        source,
        cleaned_content,
        source_sha,
        source_mtime_ns,
        source_state,
    )
    delete_journal_after_cleanup(root, "lessons", source, transaction)
    print(f"[pre-compact] archived {selected_count} promoted lesson(s) older than 90 days")
    return selected_count


def rotate_tech_trends(root: Path) -> int:
    source = root / "workspace/kb/general/tech-trends.md"
    pending = load_journal(root, "tech-trends", source)
    if pending is not None:
        recover_orphaned_backup(root, source, "archive source")
    source_state = read_safe_regular_state(root, source, "archive source", missing_ok=True)
    if source_state is None:
        if pending is not None:
            raise ArchiveError(
                "source no longer matches pending archive transaction; "
                f"journal preserved; transaction={pending['transaction_id']}"
        )
        return 0
    raw, source_metadata = source_state
    source_sha = sha256_bytes(raw)
    source_mtime_ns = source_metadata.st_mtime_ns
    if pending is not None:
        state = pending_snapshot_state(source, source_sha, source_mtime_ns, pending)
        if state == "cleaned":
            prove_existing_archives(root, pending)
            delete_journal_after_cleanup(root, "tech-trends", source, pending)
            return 0
        cleaned_content = derive_cleaned_content(
            "tech-trends", raw.decode("utf-8"), pending
        )
        commit_archives(root, pending)
        selected_count = len(pending["entries"])
        replace_source(
            root, source, cleaned_content, source_sha, source_mtime_ns, source_state
        )
        delete_journal_after_cleanup(root, "tech-trends", source, pending)
        print(
            f"[session-start] archived {selected_count} tech digest entries older than 30 days"
        )
        return selected_count
    preamble, sections = parse_sections(
        raw.decode("utf-8"), TECH_TRENDS_PATTERN
    )
    cutoff = datetime.now() - timedelta(days=30)
    selected = [section for section in sections if section.date is not None and section.date < cutoff]
    selected_occurrences = {s.occurrence for s in selected}
    cleaned_content = preamble + "".join(
        s.text for s in sections if s.occurrence not in selected_occurrences
    )
    if not selected:
        return 0

    def tech_destination(section: Section) -> Path:
        assert section.date is not None
        return source.parent / f"tech-trends-archive-{section.date.strftime('%Y')}.md"

    def tech_header(section: Section) -> str:
        assert section.date is not None
        return f"# Tech Trends Archive \u2014 {section.date.strftime('%Y')}\n"

    transaction = prepare_journal(
        root,
        "tech-trends",
        source,
        source_sha,
        source_mtime_ns,
        cleaned_content,
        selected,
        tech_destination,
        tech_header,
    )
    commit_archives(root, transaction)
    selected_count = len(selected)
    replace_source(
        root,
        source,
        cleaned_content,
        source_sha,
        source_mtime_ns,
        source_state,
    )
    delete_journal_after_cleanup(root, "tech-trends", source, transaction)
    print(f"[session-start] archived {selected_count} tech digest entries older than 30 days")
    return selected_count


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("lessons", "tech-trends"))
    parser.add_argument("--root", default=None)
    args = parser.parse_args(argv)
    root = Path(args.root).expanduser().resolve() if args.root else Path.cwd().resolve()
    try:
        with held(root, timeout_ms=250):
            if args.kind == "lessons":
                rotate_lessons(root)
            else:
                rotate_tech_trends(root)
    except LockBusyError as exc:
        print(f"[workspace-archive] WARNING: {exc}; archive skipped", file=sys.stderr)
    except LockError as exc:
        print(f"[workspace-archive] WARNING: {exc}", file=sys.stderr)
        return 1
    except (ArchiveError, OSError, UnicodeError, ValueError) as exc:
        print(f"[workspace-archive] WARNING: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
