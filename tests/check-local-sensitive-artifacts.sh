#!/usr/bin/env bash
# High-confidence scan for sensitive values in ignored local debug artifacts.

set -uo pipefail

SOURCE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ROOT="${NASE_SENSITIVE_SCAN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT" || exit 1

if [ "${1:-}" = "--stdin" ]; then
  python3 - "$SOURCE_ROOT" 3<&0 <<'PY'
import importlib.util
import os
import pathlib
import sys

module_path = pathlib.Path(sys.argv[1]).resolve() / ".claude" / "scripts" / "codex-verify-bundle.py"
spec = importlib.util.spec_from_file_location("codex_verify_bundle", module_path)
if spec is None or spec.loader is None:
    raise SystemExit(2)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with os.fdopen(3, "rb") as stream:
    match = module.scan_stream_for_secret(stream)
if match:
    print(f"FAIL: possible {match[0]} in input; value is redacted.", file=sys.stderr)
    raise SystemExit(1)
PY
  exit $?
fi

if [ "${1:-}" = "--manifest" ]; then
  if [ "$#" -ne 3 ]; then
    printf 'Usage: %s --manifest SOURCE_DIR OUTPUT_JSON\n' "$0" >&2
    exit 2
  fi
  python3 - "$2" "$3" <<'PY'
import hashlib
import json
import os
import pathlib
import stat
import sys

source = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
manifest = {}
if not source.is_dir() or source.is_symlink():
    raise SystemExit("FAIL: snapshot source is missing or unsafe.")


def walk_error(_error):
    raise SystemExit("FAIL: snapshot manifest coverage is incomplete.")


for directory, dirnames, filenames in os.walk(
    source, topdown=True, onerror=walk_error, followlinks=False
):
    parent = pathlib.Path(directory)
    if parent == source:
        dirnames[:] = [name for name in dirnames if name != "tmp"]
    for name in list(dirnames):
        path = parent / name
        try:
            metadata = path.lstat()
        except OSError:
            raise SystemExit("FAIL: snapshot manifest coverage is incomplete.") from None
        if stat.S_ISLNK(metadata.st_mode):
            raise SystemExit("FAIL: snapshot manifest contains an unsafe directory entry.")
        if not stat.S_ISDIR(metadata.st_mode):
            raise SystemExit("FAIL: snapshot manifest contains a non-directory entry.")
        manifest[path.relative_to(source).as_posix()] = {
            "mode": stat.S_IMODE(metadata.st_mode),
            "type": "directory",
        }
    for name in filenames:
        path = parent / name
        relative = path.relative_to(source).as_posix()
        try:
            descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            try:
                metadata = os.fstat(descriptor)
                if not stat.S_ISREG(metadata.st_mode):
                    raise OSError("not a regular file")
                digest = hashlib.sha256()
                with os.fdopen(descriptor, "rb", closefd=False) as stream:
                    while chunk := stream.read(64 * 1024):
                        digest.update(chunk)
            finally:
                os.close(descriptor)
        except OSError:
            raise SystemExit("FAIL: snapshot manifest coverage is incomplete.") from None
        manifest[relative] = {
            "mode": stat.S_IMODE(metadata.st_mode),
            "sha256": digest.hexdigest(),
            "type": "file",
        }
output.write_text(json.dumps(manifest, ensure_ascii=False, sort_keys=True), encoding="utf-8")
PY
  exit $?
fi

if [ "${1:-}" = "--archive" ]; then
  if [ "$#" -ne 3 ]; then
    printf 'Usage: %s --archive ZIP MANIFEST_JSON\n' "$0" >&2
    exit 2
  fi
  python3 - "$SOURCE_ROOT" "$2" "$3" <<'PY'
import hashlib
import importlib.util
import json
import pathlib
import stat
import sys
import zipfile

source_root = pathlib.Path(sys.argv[1]).resolve()
archive_path = pathlib.Path(sys.argv[2])
manifest_path = pathlib.Path(sys.argv[3])
module_path = source_root / ".claude" / "scripts" / "codex-verify-bundle.py"
spec = importlib.util.spec_from_file_location("codex_verify_bundle", module_path)
if spec is None or spec.loader is None:
    raise SystemExit("FAIL: cannot load the shared secret scanner.")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def safe_member(raw):
    encoded = raw.encode("utf-8", "surrogateescape")
    if (
        any(ord(character) < 32 or 0xD800 <= ord(character) <= 0xDFFF for character in raw)
        or module.secret_kind(encoded)
    ):
        return f"<redacted-member:{hashlib.sha256(encoded).hexdigest()[:12]}>"
    return raw


hits = []
unsafe = set()
unreadable = set()
incomplete = set()
files = 0
actual = {}
try:
    expected = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(expected, dict):
        raise ValueError
except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
    print("FAIL: backup snapshot manifest is unreadable or invalid.", file=sys.stderr)
    raise SystemExit(1)
try:
    with zipfile.ZipFile(archive_path) as archive:
        for info in archive.infolist():
            raw = info.filename.replace("\\", "/")
            parts = pathlib.PurePosixPath(raw).parts
            if not raw or raw.startswith("/") or ".." in parts:
                unsafe.add(safe_member(raw))
                continue
            canonical = pathlib.PurePosixPath(raw).as_posix()
            member = safe_member(canonical)
            mode = (info.external_attr >> 16) & 0xFFFF
            kind = stat.S_IFMT(mode)
            if info.is_dir() or kind == stat.S_IFDIR:
                if canonical in actual:
                    unsafe.add(member)
                    continue
                actual[canonical] = {
                    "mode": stat.S_IMODE(mode),
                    "type": "directory",
                }
                continue
            if info.flag_bits & 0x1:
                unreadable.add(member)
                continue
            if kind not in {0, stat.S_IFREG}:
                unsafe.add(member)
                continue
            if canonical in actual:
                unsafe.add(member)
                continue
            files += 1
            try:
                with archive.open(info) as stream:
                    match = module.scan_stream_for_secret(stream)
                with archive.open(info) as stream:
                    digest = hashlib.sha256()
                    while chunk := stream.read(64 * 1024):
                        digest.update(chunk)
            except (KeyError, NotImplementedError, RuntimeError, OSError):
                unreadable.add(member)
                continue
            actual[canonical] = {
                "mode": stat.S_IMODE(mode),
                "sha256": digest.hexdigest(),
                "type": "file",
            }
            if match:
                secret_kind, offset = match
                try:
                    with archive.open(info) as stream:
                        line = stream.read(offset).count(b"\n") + 1
                except (KeyError, NotImplementedError, RuntimeError, OSError):
                    unreadable.add(member)
                    line = 0
                hits.append((member, line, secret_kind))
except (OSError, zipfile.BadZipFile, zipfile.LargeZipFile):
    print("FAIL: backup snapshot is unreadable or invalid.", file=sys.stderr)
    raise SystemExit(1)

if files == 0:
    unreadable.add("<empty-archive>")
for name in set(expected) - set(actual):
    incomplete.add(f"missing {safe_member(name)}")
for name in set(actual) - set(expected):
    incomplete.add(f"unexpected {safe_member(name)}")
for name in set(expected) & set(actual):
    if expected[name] != actual[name]:
        incomplete.add(f"changed {safe_member(name)}")
if hits or unsafe or unreadable or incomplete:
    if hits:
        print("FAIL: credential-like values found in backup snapshot. Values are redacted:", file=sys.stderr)
        for member, line, kind in sorted(hits):
            suffix = f":{line}" if line else ""
            print(f"{member}{suffix}\t{kind}", file=sys.stderr)
    if unsafe:
        print("FAIL: backup snapshot contains unsafe member(s):", file=sys.stderr)
        for member in sorted(unsafe):
            print(member, file=sys.stderr)
    if unreadable:
        print("FAIL: backup snapshot coverage is incomplete:", file=sys.stderr)
        for member in sorted(unreadable):
            print(member, file=sys.stderr)
    if incomplete:
        print("FAIL: backup snapshot does not match its source manifest:", file=sys.stderr)
        for item in sorted(incomplete):
            print(item, file=sys.stderr)
    raise SystemExit(1)

print("PASS: backup snapshot contains no credential-like values or unsafe members.")
PY
  exit $?
fi

if [ "${1:-}" = "--workspace" ]; then
  python3 - "$SOURCE_ROOT" "$ROOT" <<'PY'
import hashlib
import importlib.util
import os
import pathlib
import stat
import sys

source_root = pathlib.Path(sys.argv[1]).resolve()
root = pathlib.Path(sys.argv[2]).resolve()
module_path = source_root / ".claude" / "scripts" / "codex-verify-bundle.py"
spec = importlib.util.spec_from_file_location("codex_verify_bundle", module_path)
if spec is None or spec.loader is None:
    raise SystemExit("FAIL: cannot load the shared secret scanner.")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

workspace = root / "workspace"
hits = []
unreadable = set()
unsafe_links = set()


def safe_path(path):
    try:
        raw = pathlib.Path(path).relative_to(root).as_posix()
    except ValueError:
        raw = "<outside-root>"
    encoded = raw.encode("utf-8", "surrogateescape")
    if (
        any(ord(character) < 32 or 0xD800 <= ord(character) <= 0xDFFF for character in raw)
        or module.secret_kind(encoded)
    ):
        return f"<redacted-path:{hashlib.sha256(encoded).hexdigest()[:12]}>"
    return raw


def walk_error(error):
    unreadable.add(safe_path(error.filename or workspace))


if workspace.is_symlink():
    unsafe_links.add(safe_path(workspace))
elif workspace.is_dir():
    for directory, dirnames, filenames in os.walk(
        workspace,
        topdown=True,
        onerror=walk_error,
        followlinks=False,
    ):
        parent = pathlib.Path(directory)
        retained_dirs = []
        for name in dirnames:
            path = parent / name
            try:
                if path.is_symlink():
                    unsafe_links.add(safe_path(path))
                else:
                    retained_dirs.append(name)
            except OSError:
                unreadable.add(safe_path(path))
        dirnames[:] = retained_dirs

        for name in filenames:
            path = parent / name
            try:
                mode = os.lstat(path).st_mode
                if stat.S_ISLNK(mode):
                    unsafe_links.add(safe_path(path))
                    continue
                if not stat.S_ISREG(mode):
                    unreadable.add(safe_path(path))
                    continue
                with path.open("rb") as stream:
                    match = module.scan_stream_for_secret(stream)
            except OSError:
                unreadable.add(safe_path(path))
                continue
            if match:
                kind, offset = match
                try:
                    with path.open("rb") as stream:
                        line = stream.read(offset).count(b"\n") + 1
                except OSError:
                    unreadable.add(safe_path(path))
                    line = 0
                hits.append((safe_path(path), line, kind))

if hits or unreadable or unsafe_links:
    if hits:
        print("FAIL: credential-like values found in the ignored workspace. Values are redacted:", file=sys.stderr)
        for path, line, kind in sorted(hits):
            suffix = f":{line}" if line else ""
            print(f"{path}{suffix}\t{kind}", file=sys.stderr)
    if unreadable:
        print("FAIL: workspace secret scan was incomplete; unreadable file(s):", file=sys.stderr)
        for path in sorted(unreadable):
            print(path, file=sys.stderr)
    if unsafe_links:
        print("FAIL: workspace contains symbolic link(s) that could escape backup scope:", file=sys.stderr)
        for path in sorted(unsafe_links):
            print(path, file=sys.stderr)
    raise SystemExit(1)

print("PASS: no credential-like values found in the ignored workspace.")
PY
  exit $?
fi

if [ "$#" -ne 0 ]; then
  printf 'Usage: %s [--workspace|--stdin|--manifest SOURCE_DIR OUTPUT_JSON|--archive ZIP MANIFEST_JSON]\n' "$0" >&2
  exit 2
fi

if ! command -v rg >/dev/null 2>&1; then
  printf 'FAIL: rg is required for sensitive artifact scan.\n' >&2
  exit 1
fi

targets=(
  ".playwright-cli"
  ".playwright-mcp"
  ".omc"
  ".serena"
  ".full-review"
  ".claude/settings.local.json"
  "workspace/tmp"
  "workspace/logs"
  "workspace/cache"
)

existing_targets=()
for target in "${targets[@]}"; do
  if [ -e "$target" ]; then
    existing_targets+=("$target")
  fi
done

if [ "${#existing_targets[@]}" -eq 0 ]; then
  printf 'PASS: no local sensitive artifact directories found.\n'
  exit 0
fi

pattern='([Aa]uthorization[":[:space:]]*[[:space:]]*[Bb]earer[[:space:]]+[A-Za-z0-9._-]{20,}|(access_token|id_token|refresh_token)[A-Za-z0-9_"[:space:]=:-]{0,24}eyJ[A-Za-z0-9._-]+|-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----)'

hits=$(rg -nIl --hidden --no-ignore \
  -g '*.log' \
  -g '*.json' \
  -g '*.md' \
  -g '*.txt' \
  -g '*.yml' \
  -g '*.yaml' \
  -e "$pattern" \
  "${existing_targets[@]}" 2>/dev/null || true)

if [ -n "$hits" ]; then
  printf 'FAIL: sensitive values found in ignored local artifacts. Remove/rotate before sharing this workspace:\n' >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi

printf 'PASS: no sensitive values found in local artifacts.\n'
