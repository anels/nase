#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

python3 - "$ROOT" <<'PY'
import importlib.util
import os
import subprocess
import sys
import tempfile
import time
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
module.rotate_lessons(fixture)
assert archive.read_text(encoding="utf-8").count(module.MARKER_PREFIX) == 1
assert "## debugging" not in source.read_text(encoding="utf-8")
print("PASS  retry cleans source without duplicate archive append")

# Identical sections get distinct occurrence markers.
fixture = make_root()
source = fixture / "workspace/tasks/lessons.md"
entry = lesson()
source.write_text("# Lessons\n\n" + entry + entry, encoding="utf-8")
module.rotate_lessons(fixture)
archived = (fixture / "workspace/tasks/lessons-archive.md").read_text(encoding="utf-8")
assert archived.count(module.MARKER_PREFIX) == 2
assert archived.count("same body") == 2
print("PASS  identical sections preserve both occurrences")

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
module.rotate_tech_trends(fixture)
assert "## Tech Digest" not in source.read_text(encoding="utf-8")
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
