#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

python3 - "$ROOT" <<'PY'
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from unittest import mock

root = Path(sys.argv[1])
script = root / ".claude/scripts/workspace-archive.py"
spec = importlib.util.spec_from_file_location("workspace_archive", script)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


def lesson(text="same body"):
    return f"## debugging -- 2020-01-01 -- title\n\n{text}\n\n> Promoted → kb.md\n\n"


def dated_lesson(date, text):
    return f"## debugging -- {date} -- title\n\n{text}\n\n> Promoted → kb.md\n\n"


def trend(year, text="body"):
    return f"## Tech Digest — {year}-01-01\n\n{text}\n\n"


def make_root():
    fixture = Path(tempfile.mkdtemp())
    (fixture / "workspace/tasks").mkdir(parents=True)
    (fixture / "workspace/kb/general").mkdir(parents=True)
    return fixture


# Archive failure leaves the source byte-identical.
fixture = make_root()
source = fixture / "workspace/tasks/lessons.md"
source.write_text("# Lessons\n\n" + lesson(), encoding="utf-8")
original = source.read_bytes()
with mock.patch.object(module, "atomic_replace", side_effect=OSError("disk full")):
    try:
        module.rotate_lessons(fixture)
    except OSError:
        pass
assert source.read_bytes() == original
print("PASS  archive failure preserves source bytes")

# Archive commit followed by source replacement failure is idempotent on retry.
fixture = make_root()
source = fixture / "workspace/tasks/lessons.md"
source.write_text("# Lessons\n\n" + lesson(), encoding="utf-8")
real_replace = module.atomic_replace


def fail_source(path, content, validate):
    if path == source:
        raise OSError("injected source failure")
    return real_replace(path, content, validate)


with mock.patch.object(module, "atomic_replace", side_effect=fail_source):
    try:
        module.rotate_lessons(fixture)
    except OSError:
        pass
archive = fixture / "workspace/tasks/lessons-archive.md"
assert archive.read_text(encoding="utf-8").count(module.MARKER_PREFIX) == 1
assert module.journal_path(fixture, "lessons").exists()
source.write_text("# Lessons\n\nunrelated preamble edit\n\n" + lesson(), encoding="utf-8")
try:
    module.rotate_lessons(fixture)
except module.ArchiveError:
    pass
assert archive.read_text(encoding="utf-8").count(module.MARKER_PREFIX) == 1
assert module.journal_path(fixture, "lessons").exists()
assert "## debugging" in source.read_text(encoding="utf-8")
assert "unrelated preamble edit" in source.read_text(encoding="utf-8")
print("PASS  retry after source drift preserves source, journal, and archive")

# An unchanged source retry finishes cleanup without appending twice.
fixture = make_root()
source = fixture / "workspace/tasks/lessons.md"
source.write_text("# Lessons\n\n" + lesson(), encoding="utf-8")
with mock.patch.object(module, "atomic_replace", side_effect=fail_source):
    try:
        module.rotate_lessons(fixture)
    except OSError:
        pass
archive = fixture / "workspace/tasks/lessons-archive.md"
module.rotate_lessons(fixture)
assert archive.read_text(encoding="utf-8").count(module.MARKER_PREFIX) == 1
assert "## debugging" not in source.read_text(encoding="utf-8")
assert not module.journal_path(fixture, "lessons").exists()
print("PASS  unchanged retry finishes cleanup without duplicate append")

# A pending retry uses the journal-bound after-image instead of a later cutoff.
fixture = make_root()
source = fixture / "workspace/tasks/lessons.md"
source.write_text(
    "# Lessons\n\n"
    + dated_lesson("2025-12-31", "initially eligible")
    + dated_lesson("2026-01-15", "eligible only on retry"),
    encoding="utf-8",
)


class InitialClock(datetime):
    @classmethod
    def now(cls, tz=None):
        return cls(2026, 4, 1, tzinfo=tz)


class RetryClock(datetime):
    @classmethod
    def now(cls, tz=None):
        return cls(2026, 5, 1, tzinfo=tz)


with (
    mock.patch.object(module, "datetime", InitialClock),
    mock.patch.object(module, "atomic_replace", side_effect=fail_source),
):
    try:
        module.rotate_lessons(fixture)
    except OSError:
        pass
with mock.patch.object(module, "datetime", RetryClock):
    module.rotate_lessons(fixture)
live = source.read_text(encoding="utf-8")
archived = (fixture / "workspace/tasks/lessons-archive.md").read_text(encoding="utf-8")
assert "initially eligible" not in live
assert "eligible only on retry" in live
assert "initially eligible" in archived
assert "eligible only on retry" not in archived
assert archived.count(module.MARKER_PREFIX) == 1
print("PASS  pending retry never expands cleanup when another section crosses cutoff")

# The transaction journal must be directory-durable before any archive commit.
fixture = make_root()
source = fixture / "workspace/tasks/lessons.md"
source.write_text("# Lessons\n\n" + lesson(), encoding="utf-8")
original = source.read_bytes()
with mock.patch.object(module, "fsync_dir", side_effect=OSError("fsync failed")):
    try:
        module.rotate_lessons(fixture)
    except OSError:
        pass
assert source.read_bytes() == original
archive = fixture / "workspace/tasks/lessons-archive.md"
assert not archive.exists()
assert module.journal_path(fixture, "lessons").exists()
module.rotate_lessons(fixture)
assert archive.read_text(encoding="utf-8").count(module.MARKER_PREFIX) == 1
assert "## debugging" not in source.read_text(encoding="utf-8")
print("PASS  journal directory fsync failure precedes archive commits")

# Source promotion can succeed before its directory fsync fails. The cleaned
# after-image hash lets retry finish the journal without replaying the archive.
fixture = make_root()
source = fixture / "workspace/tasks/lessons.md"
source.write_text("# Lessons\n\n" + lesson(), encoding="utf-8")
real_fsync_dir = module.fsync_dir
source_dir_fsyncs = 0


def fail_source_dir(path):
    global source_dir_fsyncs
    if path == source.parent:
        source_dir_fsyncs += 1
        if source_dir_fsyncs == 2:
            raise OSError("source directory fsync failed")
    return real_fsync_dir(path)


with mock.patch.object(module, "fsync_dir", side_effect=fail_source_dir):
    try:
        module.rotate_lessons(fixture)
    except OSError:
        pass
archive = fixture / "workspace/tasks/lessons-archive.md"
assert "## debugging" not in source.read_text(encoding="utf-8")
assert archive.read_text(encoding="utf-8").count(module.MARKER_PREFIX) == 1
assert module.journal_path(fixture, "lessons").exists()
module.rotate_lessons(fixture)
assert archive.read_text(encoding="utf-8").count(module.MARKER_PREFIX) == 1
assert not module.journal_path(fixture, "lessons").exists()
print("PASS  promoted source after-image lets retry clear durable journal")


def make_pending(kind):
    fixture = make_root()
    if kind == "lessons":
        source = fixture / "workspace/tasks/lessons.md"
        source.write_text("# Lessons\n\n" + lesson(), encoding="utf-8")
        rotate = module.rotate_lessons
    else:
        source = fixture / "workspace/kb/general/tech-trends.md"
        source.write_text("# Trends\n\n" + trend("2020"), encoding="utf-8")
        rotate = module.rotate_tech_trends
    real_atomic_replace = module.atomic_replace

    def fail_source_replace(path, content, validate):
        if path == source:
            raise OSError("injected source failure")
        return real_atomic_replace(path, content, validate)

    with mock.patch.object(module, "atomic_replace", side_effect=fail_source_replace):
        try:
            rotate(fixture)
        except OSError:
            pass
    journal = module.journal_path(fixture, kind)
    assert journal.exists()
    return fixture, source, journal, rotate


def assert_journal_tamper_rejected(kind, mutate):
    fixture, source, journal, rotate = make_pending(kind)
    data = json.loads(journal.read_text(encoding="utf-8"))
    mutate(data)
    journal.write_text(json.dumps(data), encoding="utf-8")
    source_before = source.read_bytes()
    archives_before = {
        path: path.read_bytes()
        for path in fixture.glob("workspace/**/*archive*.md")
    }
    try:
        rotate(fixture)
    except module.ArchiveError:
        pass
    else:
        raise AssertionError("tampered journal was accepted")
    assert source.read_bytes() == source_before
    assert journal.exists()
    assert {
        path: path.read_bytes()
        for path in fixture.glob("workspace/**/*archive*.md")
    } == archives_before


assert_journal_tamper_rejected(
    "lessons", lambda data: data.__setitem__("transaction_id", "A" * 32)
)
assert_journal_tamper_rejected(
    "lessons",
    lambda data: data["entries"][0].__setitem__(
        "marker",
        data["entries"][0]["marker"].replace(
            data["entries"][0]["marker"].split(":", 1)[1].split(" ", 1)[0],
            "0" * 64,
        ),
    ),
)
assert_journal_tamper_rejected(
    "lessons",
    lambda data: data["entries"][0].__setitem__(
        "marker",
        data["entries"][0]["marker"].replace("offset=11", "offset=x"),
    ),
)
assert_journal_tamper_rejected(
    "lessons",
    lambda data: data["entries"][0].__setitem__(
        "destination", "workspace/tasks/not-lessons-archive.md"
    ),
)


def tamper_after_image(data):
    data["cleaned_text"] = "# attacker-selected after-image\n"
    data["cleaned_sha"] = module.sha256_bytes(data["cleaned_text"].encode("utf-8"))


def tamper_archived_entry(data):
    entry = data["entries"][0]
    entry["text"] = dated_lesson("2020-01-01", "attacker-selected section")
    entry["section_sha"] = module.sha256_bytes(entry["text"].encode("utf-8"))
    entry["marker"] = entry["marker"].rsplit("section=", 1)[0] + (
        f"section={entry['section_sha']} -->\n"
    )


assert_journal_tamper_rejected("lessons", tamper_after_image)
assert_journal_tamper_rejected("lessons", tamper_archived_entry)


def tamper_tech_year(data):
    data["entries"][0]["destination"] = (
        "workspace/kb/general/tech-trends-archive-2021.md"
    )
    data["entries"][0]["header"] = "# Tech Trends Archive \u2014 2021\n"


assert_journal_tamper_rejected("tech-trends", tamper_tech_year)
print("PASS  tampered journal plan, identity, marker, destination, and year fail closed")


def run_archive_cli(fixture, kind="lessons"):
    return subprocess.run(
        [sys.executable, str(script), kind, "--root", str(fixture)],
        capture_output=True,
        text=True,
        timeout=3,
    )


# Archive and journal paths must reject FIFOs and symlinks without blocking.
fixture = make_root()
source = fixture / "workspace/tasks/lessons.md"
source.write_text("# Lessons\n\n" + lesson(), encoding="utf-8")
original = source.read_bytes()
os.mkfifo(fixture / "workspace/tasks/lessons-archive.md")
assert run_archive_cli(fixture).returncode == 1
assert source.read_bytes() == original

fixture = make_root()
source = fixture / "workspace/tasks/lessons.md"
source.write_text("# Lessons\n\n" + lesson(), encoding="utf-8")
original = source.read_bytes()
outside = fixture / "outside.md"
outside.write_text("outside\n", encoding="utf-8")
(fixture / "workspace/tasks/lessons-archive.md").symlink_to(outside)
assert run_archive_cli(fixture).returncode == 1
assert source.read_bytes() == original
assert outside.read_text(encoding="utf-8") == "outside\n"

fixture = make_root()
source = fixture / "workspace/tasks/lessons.md"
source.write_text("# Lessons\n\n" + lesson(), encoding="utf-8")
original = source.read_bytes()
journal = module.journal_path(fixture, "lessons")
journal.parent.mkdir()
os.mkfifo(journal)
assert run_archive_cli(fixture).returncode == 1
assert source.read_bytes() == original

fixture = make_root()
source = fixture / "workspace/tasks/lessons.md"
source.write_text("# Lessons\n\n" + lesson(), encoding="utf-8")
original = source.read_bytes()
journal = module.journal_path(fixture, "lessons")
journal.parent.mkdir()
outside = fixture / "outside-journal.json"
outside.write_text("{}\n", encoding="utf-8")
journal.symlink_to(outside)
assert run_archive_cli(fixture).returncode == 1
assert source.read_bytes() == original
assert outside.read_text(encoding="utf-8") == "{}\n"

fixture = make_root()
source = fixture / "workspace/tasks/lessons.md"
source.write_text("# Lessons\n\n" + lesson(), encoding="utf-8")
original = source.read_bytes()
outside_parent = fixture / "outside-locks"
outside_parent.mkdir()
(fixture / ".nase-locks").symlink_to(outside_parent, target_is_directory=True)
assert run_archive_cli(fixture).returncode == 1
assert source.read_bytes() == original
assert not list(outside_parent.iterdir())
print("PASS  archive and journal FIFOs and symlinks fail closed without blocking")

# Retry must prove an existing archive file durable before source cleanup.
fixture = make_root()
source = fixture / "workspace/tasks/lessons.md"
source.write_text("# Lessons\n\n" + lesson(), encoding="utf-8")
with mock.patch.object(module, "atomic_replace", side_effect=fail_source):
    try:
        module.rotate_lessons(fixture)
    except OSError:
        pass
original = source.read_bytes()
with mock.patch.object(module, "fsync_file", side_effect=OSError("file fsync failed")):
    try:
        module.rotate_lessons(fixture)
    except OSError:
        pass
assert source.read_bytes() == original
module.rotate_lessons(fixture)
assert "## debugging" not in source.read_text(encoding="utf-8")
print("PASS  retry file fsync failure preserves source")

# A marker without its complete section never authorizes source cleanup.
fixture = make_root()
source = fixture / "workspace/tasks/lessons.md"
source.write_text("# Lessons\n\n" + lesson(), encoding="utf-8")
with mock.patch.object(module, "atomic_replace", side_effect=fail_source):
    try:
        module.rotate_lessons(fixture)
    except OSError:
        pass
archive = fixture / "workspace/tasks/lessons-archive.md"
archive.write_text(archive.read_text(encoding="utf-8").split("## debugging", 1)[0], encoding="utf-8")
original = source.read_bytes()
try:
    module.rotate_lessons(fixture)
except module.ArchiveError:
    pass
assert source.read_bytes() == original
print("PASS  incomplete archived section never permits source cleanup")

# Two marker identities cannot claim the same remaining identical section.
fixture = make_root()
source = fixture / "workspace/tasks/lessons.md"
entry = lesson()
source.write_text("# Lessons\n\n" + entry + entry, encoding="utf-8")
with mock.patch.object(module, "atomic_replace", side_effect=fail_source):
    try:
        module.rotate_lessons(fixture)
    except OSError:
        pass
archive = fixture / "workspace/tasks/lessons-archive.md"
content = archive.read_text(encoding="utf-8")
marker_lines = [line for line in content.splitlines() if line.startswith(module.MARKER_PREFIX)]
header = content.split(module.MARKER_PREFIX, 1)[0]
archive.write_text(
    header + marker_lines[0].removesuffix("-->") + marker_lines[1] + "\n" + entry,
    encoding="utf-8",
)
original = source.read_bytes()
try:
    module.rotate_lessons(fixture)
except module.ArchiveError:
    pass
assert source.read_bytes() == original
print("PASS  malformed duplicate markers cannot alias one archived section")

# Identical sections get distinct stable occurrence markers across retry.
fixture = make_root()
source = fixture / "workspace/tasks/lessons.md"
entry = lesson()
source.write_text("# Lessons\n\n" + entry + entry, encoding="utf-8")
with mock.patch.object(module, "atomic_replace", side_effect=fail_source):
    try:
        module.rotate_lessons(fixture)
    except OSError:
        pass
module.rotate_lessons(fixture)
archived = (fixture / "workspace/tasks/lessons-archive.md").read_text(encoding="utf-8")
assert archived.count(module.MARKER_PREFIX) == 2
assert archived.count("same body") == 2
print("PASS  identical sections preserve multiplicity across retry")

# A later independent rotation gets a new transaction identity.
fixture = make_root()
source = fixture / "workspace/tasks/lessons.md"
entry = lesson()
source.write_text("# Lessons\n\n" + entry, encoding="utf-8")
module.rotate_lessons(fixture)
assert not module.journal_path(fixture, "lessons").exists()
source.write_text("# Lessons\n\n" + entry, encoding="utf-8")
module.rotate_lessons(fixture)
archived = (fixture / "workspace/tasks/lessons-archive.md").read_text(encoding="utf-8")
assert archived.count(module.MARKER_PREFIX) == 2
assert archived.count("same body") == 2
print("PASS  independent identical rotations retain both occurrences")

# A multi-year archive failure never rewrites source; retry finishes without duplicates.
fixture = make_root()
source = fixture / "workspace/kb/general/tech-trends.md"
source.write_text("# Trends\n\n" + trend("2020") + trend("2021"), encoding="utf-8")
original = source.read_bytes()


def fail_second_year(path, content, validate):
    if path.name == "tech-trends-archive-2021.md":
        raise OSError("injected second archive failure")
    return real_replace(path, content, validate)


with mock.patch.object(module, "atomic_replace", side_effect=fail_second_year):
    try:
        module.rotate_tech_trends(fixture)
    except OSError:
        pass
assert source.read_bytes() == original
assert module.journal_path(fixture, "tech-trends").exists()
assert (fixture / "workspace/kb/general/tech-trends-archive-2020.md").exists()
assert not (fixture / "workspace/kb/general/tech-trends-archive-2021.md").exists()
module.rotate_tech_trends(fixture)
assert "## Tech Digest" not in source.read_text(encoding="utf-8")
assert not module.journal_path(fixture, "tech-trends").exists()
for year in ("2020", "2021"):
    content = (fixture / f"workspace/kb/general/tech-trends-archive-{year}.md").read_text(encoding="utf-8")
    assert content.count(module.MARKER_PREFIX) == 1
print("PASS  multi-year failure preserves source and retry is idempotent")

# Concurrent rotations serialize through the shared lock.
fixture = make_root()
source = fixture / "workspace/tasks/lessons.md"
source.write_text("# Lessons\n\n" + lesson(), encoding="utf-8")
commands = [[sys.executable, str(script), "lessons", "--root", str(fixture)] for _ in range(2)]
processes = [subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for command in commands]
results = [process.communicate(timeout=10) + (process.returncode,) for process in processes]
assert all(result[2] == 0 for result in results), results
archived = (fixture / "workspace/tasks/lessons-archive.md").read_text(encoding="utf-8")
assert archived.count(module.MARKER_PREFIX) == 1
assert "## debugging" not in source.read_text(encoding="utf-8")
print("PASS  concurrent rotations neither lose nor duplicate sections")

# A live owner makes the background helper warn and skip within its bounded wait.
import workspace_lock

fixture = make_root()
source = fixture / "workspace/tasks/lessons.md"
source.write_text("# Lessons\n\n" + lesson(), encoding="utf-8")
original = source.read_bytes()
lease = workspace_lock.acquire(fixture, timeout_ms=0)
started = time.monotonic()
try:
    result = subprocess.run(
        [sys.executable, str(script), "lessons", "--root", str(fixture)],
        capture_output=True,
        text=True,
        timeout=5,
    )
finally:
    workspace_lock.release(lease)
assert result.returncode == 0, result
assert "WARNING" in result.stderr and "archive skipped" in result.stderr, result.stderr
assert time.monotonic() - started < 2
assert source.read_bytes() == original
print("PASS  live lock warns and skips without touching source")
PY

printf '\nworkspace archive tests passed.\n'
