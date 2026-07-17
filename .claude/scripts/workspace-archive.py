#!/usr/bin/env python3
"""Archive stale workspace sections without deleting source data first."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import stat
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from workspace_lock import LockError, held  # noqa: E402


LESSONS_HEADER = (
    "# Lessons Archive\n\n"
    "> Promoted lessons older than 90 days. Moved here by pre-compact-archive.sh.\n\n"
)
MARKER_PREFIX = "<!-- nase-archive:"


class ArchiveError(RuntimeError):
    pass


@dataclass(frozen=True)
class Section:
    text: str
    date: datetime
    offset: int
    occurrence: int


def sha256_bytes(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def fsync_dir(path: Path) -> None:
    try:
        descriptor = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(descriptor)
    except OSError:
        pass
    finally:
        os.close(descriptor)


def atomic_replace(path: Path, content: bytes, validate) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.tmp-", dir=path.parent)
    tmp = Path(tmp_name)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        validate(tmp)
        os.replace(tmp, path)
        fsync_dir(path.parent)
    finally:
        tmp.unlink(missing_ok=True)


def parse_sections(text: str, pattern: re.Pattern[str]) -> tuple[str, list[Section]]:
    matches = list(pattern.finditer(text))
    if not matches:
        return text, []
    sections: list[Section] = []
    for occurrence, match in enumerate(matches):
        end = matches[occurrence + 1].start() if occurrence + 1 < len(matches) else len(text)
        sections.append(
            Section(
                text=text[match.start() : end],
                date=datetime.strptime(match.group(1), "%Y-%m-%d"),
                offset=len(text[: match.start()].encode("utf-8")),
                occurrence=occurrence,
            )
        )
    return text[: matches[0].start()], sections


def marker(source_sha: str, section: Section) -> str:
    transaction = hashlib.sha256(
        f"{source_sha}:{section.offset}:{section.occurrence}".encode("ascii")
    ).hexdigest()
    section_sha = sha256_bytes(section.text.encode("utf-8"))
    return (
        f"{MARKER_PREFIX}{transaction} source={source_sha} offset={section.offset} "
        f"occurrence={section.occurrence} section={section_sha} -->\n"
    )


def append_sections(path: Path, header: str, entries: list[tuple[str, Section]]) -> None:
    original = path.read_text(encoding="utf-8") if path.exists() else header
    additions = [value + section.text for value, section in entries if value not in original]
    if not additions:
        return
    content = (original + "".join(additions)).encode("utf-8")

    def validate(tmp: Path) -> None:
        written = tmp.read_text(encoding="utf-8")
        if any(written.count(value) != 1 for value, _ in entries):
            raise ArchiveError(f"archive validation failed for {path}")

    atomic_replace(path, content, validate)


def replace_source(path: Path, content: str, original_sha: str, original_mtime_ns: int) -> None:
    try:
        current = path.stat()
    except OSError as exc:
        raise ArchiveError(f"source disappeared before cleanup: {path}: {exc}") from exc
    if current.st_mtime_ns != original_mtime_ns or sha256_file(path) != original_sha:
        raise ArchiveError(
            f"source changed after archive commit; source preserved; transaction source={original_sha}"
        )
    encoded = content.encode("utf-8")
    expected_sha = sha256_bytes(encoded)

    def validate(tmp: Path) -> None:
        if sha256_file(tmp) != expected_sha:
            raise ArchiveError(f"source validation failed for {path}")

    atomic_replace(path, encoded, validate)


def rotate_lessons(root: Path) -> int:
    source = root / "workspace/tasks/lessons.md"
    destination = root / "workspace/tasks/lessons-archive.md"
    if not source.is_file() or source.is_symlink():
        return 0
    raw = source.read_bytes()
    source_sha = sha256_bytes(raw)
    source_mtime_ns = source.stat().st_mtime_ns
    preamble, sections = parse_sections(
        raw.decode("utf-8"), re.compile(r"(?m)^## [a-z]+ -- (\d{4}-\d{2}-\d{2})")
    )
    cutoff = datetime.now() - timedelta(days=90)
    selected = [s for s in sections if s.date < cutoff and "> Promoted \u2192" in s.text]
    if not selected:
        return 0
    append_sections(destination, LESSONS_HEADER, [(marker(source_sha, s), s) for s in selected])
    selected_occurrences = {s.occurrence for s in selected}
    replace_source(
        source,
        preamble + "".join(s.text for s in sections if s.occurrence not in selected_occurrences),
        source_sha,
        source_mtime_ns,
    )
    print(f"[pre-compact] archived {len(selected)} promoted lesson(s) older than 90 days")
    return len(selected)


def rotate_tech_trends(root: Path) -> int:
    source = root / "workspace/kb/general/tech-trends.md"
    if not source.is_file() or source.is_symlink():
        return 0
    raw = source.read_bytes()
    source_sha = sha256_bytes(raw)
    source_mtime_ns = source.stat().st_mtime_ns
    preamble, sections = parse_sections(
        raw.decode("utf-8"), re.compile(r"(?m)^## Tech Digest \u2014 (\d{4}-\d{2}-\d{2})")
    )
    cutoff = datetime.now() - timedelta(days=30)
    selected = [s for s in sections if s.date < cutoff]
    if not selected:
        return 0
    by_year: dict[str, list[Section]] = {}
    for section in selected:
        by_year.setdefault(section.date.strftime("%Y"), []).append(section)
    for year, year_sections in sorted(by_year.items()):
        destination = source.parent / f"tech-trends-archive-{year}.md"
        append_sections(
            destination,
            f"# Tech Trends Archive \u2014 {year}\n",
            [(marker(source_sha, s), s) for s in year_sections],
        )
    selected_occurrences = {s.occurrence for s in selected}
    replace_source(
        source,
        preamble + "".join(s.text for s in sections if s.occurrence not in selected_occurrences),
        source_sha,
        source_mtime_ns,
    )
    print(f"[session-start] archived {len(selected)} tech digest entries older than 30 days")
    return len(selected)


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
    except LockError as exc:
        print(f"[workspace-archive] WARNING: {exc}; archive skipped", file=sys.stderr)
    except (ArchiveError, OSError, UnicodeError, ValueError) as exc:
        print(f"[workspace-archive] WARNING: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
