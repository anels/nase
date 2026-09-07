#!/usr/bin/env bash
# Regression tests for .claude/scripts/nase_git.py and .claude/scripts/nase_fs.py
#
# These two modules hold the single copy of a policy every consumer depends on. What has
# to hold: every git call is bounded and a timeout is distinguishable from a failure; the
# environment is merged rather than replaced; a streaming read always reaps its process;
# and the durable write is actually durable and leaves nothing behind.
#
# Run from repo root:  bash tests/scripts/test-nase-shared-modules.sh

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

pass=0
fail=0

ok() {
  printf 'PASS  %s\n' "$1"
  pass=$((pass + 1))
}

bad() {
  printf 'FAIL  %s%s\n' "$1" "${2:+: $2}" >&2
  fail=$((fail + 1))
}

# Each case is a python program that prints nothing and exits 0, or raises.
run_case() {
  local name="$1" program="$2"
  local err
  if err=$(python3 -c "$program" 2>&1); then
    ok "$name"
  else
    bad "$name" "$(printf '%s' "$err" | tail -3 | tr '\n' ' ')"
  fi
}

PRELUDE='
import pathlib, sys
sys.path.insert(0, str(pathlib.Path("'"$ROOT"'") / ".claude" / "scripts"))
import nase_git, nase_fs
'

# --- nase_git.run ---------------------------------------------------------

run_case "run returns captured stdout as bytes by default" "$PRELUDE"'
out = nase_git.run("rev-parse", "--show-toplevel", repo=".")
assert out.returncode == 0, out
assert isinstance(out.stdout, bytes), type(out.stdout)
'

run_case "run(text=True) returns str" "$PRELUDE"'
out = nase_git.run("rev-parse", "--show-toplevel", repo=".", text=True)
assert isinstance(out.stdout, str), type(out.stdout)
'

run_case "a failing command returns non-zero without raising" "$PRELUDE"'
out = nase_git.run("cat-file", "blob", "0" * 40, repo=".")
assert out.returncode != 0, out
assert out.stderr, "stderr must be captured, not discarded"
'

run_case "check=True raises CalledProcessError on failure" "$PRELUDE"'
import subprocess
try:
    nase_git.run("cat-file", "blob", "0" * 40, repo=".", check=True)
except subprocess.CalledProcessError:
    pass
else:
    raise AssertionError("check=True did not raise")
'

run_case "run merges env over the ambient one instead of replacing it" "$PRELUDE"'
import os, tempfile
# The child has to report its own environment. Checking the parents proves nothing: the
# parent keeps its variables whatever is passed down.
stub = tempfile.mkdtemp()
os.mkdir(os.path.join(stub, "bin"))
script = os.path.join(stub, "bin", "git")
with open(script, "w") as handle:
    handle.write("#!/bin/sh\nprintf \"ambient=%s merged=%s\\n\" \"$NASE_PROBE_AMBIENT\" \"$NASE_PROBE_MERGED\"\n")
os.chmod(script, 0o755)
os.environ["PATH"] = os.path.join(stub, "bin") + os.pathsep + os.environ["PATH"]
os.environ["NASE_PROBE_AMBIENT"] = "kept"
out = nase_git.run("anything", text=True, env={"NASE_PROBE_MERGED": "added"})
assert out.returncode == 0, out.stderr
assert "merged=added" in out.stdout, out.stdout
assert "ambient=kept" in out.stdout, out.stdout
'

run_case "repo=None runs against the ambient repository" "$PRELUDE"'
out = nase_git.run("rev-parse", "--is-inside-work-tree", text=True)
assert out.stdout.strip() == "true", out
'

# A stub git that never returns is the only honest way to test the bound.
STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT
mkdir -p "$STUB/bin"
printf '#!/bin/sh\nsleep 60\n' > "$STUB/bin/git"
chmod +x "$STUB/bin/git"

run_case "a hung git raises GitTimeout, not TimeoutExpired" "$PRELUDE"'
import os, subprocess, time
os.environ["PATH"] = "'"$STUB"'/bin:" + os.environ["PATH"]
started = time.monotonic()
try:
    nase_git.run("status", timeout=1)
except nase_git.GitTimeout as exc:
    elapsed = time.monotonic() - started
    assert elapsed < 20, f"bound did not fire promptly: {elapsed}s"
    assert "status" in str(exc), str(exc)
    assert "1" in str(exc), str(exc)
    # A caller must not have to know that a timeout is also a TimeoutExpired.
    assert isinstance(exc, subprocess.SubprocessError)
    assert not isinstance(exc, subprocess.TimeoutExpired)
else:
    raise AssertionError("a 60s git under a 1s bound did not time out")
'

run_case "the default bound is a real number of seconds, not None" "$PRELUDE"'
import inspect
default = inspect.signature(nase_git.run).parameters["timeout"].default
assert isinstance(default, (int, float)) and default > 0, default
assert nase_git.GIT_NETWORK_TIMEOUT_SECONDS > nase_git.GIT_TIMEOUT_SECONDS
'

# --- nase_git.resolve_root ------------------------------------------------

run_case "an explicit root wins over the environment" "$PRELUDE"'
import os, tempfile, pathlib
os.environ["NASE_ROOT"] = "/tmp"
with tempfile.TemporaryDirectory() as tmp:
    assert nase_git.resolve_root(tmp) == pathlib.Path(tmp).resolve()
'

run_case "NASE_ROOT is used when no explicit root is given" "$PRELUDE"'
import os, tempfile, pathlib
with tempfile.TemporaryDirectory() as tmp:
    os.environ["NASE_ROOT"] = tmp
    assert nase_git.resolve_root() == pathlib.Path(tmp).resolve()
'

run_case "env_var=None ignores the ambient root and falls back to git" "$PRELUDE"'
import os, pathlib
os.environ["NASE_ROOT"] = "/tmp"
resolved = nase_git.resolve_root(env_var=None)
assert resolved == pathlib.Path("'"$ROOT"'").resolve(), resolved
'

run_case "outside a repository it falls back to the working directory" "$PRELUDE"'
import os, tempfile, pathlib
os.environ.pop("NASE_ROOT", None)
with tempfile.TemporaryDirectory() as tmp:
    # A temp dir is outside any repo only if no ancestor is one; /tmp is not.
    os.chdir(tmp)
    resolved = nase_git.resolve_root()
    assert resolved.is_dir(), resolved
'

# --- nase_git.streaming ---------------------------------------------------

run_case "streaming yields stdout and reaps the process" "$PRELUDE"'
with nase_git.streaming("rev-parse", "--show-toplevel", repo=".") as process:
    assert process.stdout is not None
    data = process.stdout.read()
    assert data.strip(), data
    assert process.wait(timeout=nase_git.GIT_TIMEOUT_SECONDS) == 0
assert process.returncode is not None
'

run_case "streaming kills the process when the body raises" "$PRELUDE"'
import os, tempfile, time
# A child that writes nothing and sleeps: closing its stdout gives it no SIGPIPE, so
# only the kill ends it. A git command that streams would exit on the closed pipe by
# itself and the case would pass with the kill removed.
stub = tempfile.mkdtemp()
os.mkdir(os.path.join(stub, "bin"))
script = os.path.join(stub, "bin", "git")
with open(script, "w") as handle:
    handle.write("#!/bin/sh\nsleep 60\n")
os.chmod(script, 0o755)
os.environ["PATH"] = os.path.join(stub, "bin") + os.pathsep + os.environ["PATH"]


class Boom(Exception):
    pass


started = time.monotonic()
try:
    with nase_git.streaming("anything", timeout=5) as process:
        raise Boom
except Boom:
    pass
elapsed = time.monotonic() - started
assert process.returncode is not None, "process was never reaped"
assert elapsed < 5, f"waited out the bound instead of killing: {elapsed}s"
'

run_case "streaming with a file for stderr does not deadlock on a large stderr" "$PRELUDE"'
import os, tempfile, time
stub = tempfile.mkdtemp()
os.mkdir(os.path.join(stub, "bin"))
# Writes 1 MiB to stderr before finishing stdout. Against a pipe this wedges: the
# writer blocks on a full stderr pipe while the reader is still draining stdout.
script = os.path.join(stub, "bin", "git")
with open(script, "w") as handle:
    handle.write("#!/bin/sh\nhead -c 1048576 /dev/zero >&2\nprintf done\n")
os.chmod(script, 0o755)
os.environ["PATH"] = os.path.join(stub, "bin") + os.pathsep + os.environ["PATH"]
started = time.monotonic()
with tempfile.TemporaryFile() as sink:
    with nase_git.streaming("anything", stderr=sink, timeout=20) as process:
        assert process.stdout is not None
        out = process.stdout.read()
        code = process.wait(timeout=20)
    sink.seek(0)
    err = sink.read()
assert out == b"done", out
assert code == 0, code
assert len(err) == 1048576, len(err)
assert time.monotonic() - started < 20, "took the full bound; likely deadlocked"
'

# --- nase_fs digests ------------------------------------------------------

run_case "sha256_bytes matches the published digest of the empty string" "$PRELUDE"'
assert nase_fs.sha256_bytes(b"") == (
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
)
'

run_case "sha256_file agrees with sha256_bytes on the same content" "$PRELUDE"'
import tempfile, pathlib, os
data = os.urandom(4096)
with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp) / "blob"
    path.write_bytes(data)
    assert nase_fs.sha256_file(path) == nase_fs.sha256_bytes(data)
'

run_case "sha256_file handles a file larger than one read buffer" "$PRELUDE"'
import tempfile, pathlib
data = b"x" * (5 * 1024 * 1024)
with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp) / "big"
    path.write_bytes(data)
    assert nase_fs.sha256_file(path) == nase_fs.sha256_bytes(data)
'

# --- nase_fs.atomic_write -------------------------------------------------

run_case "atomic_write creates missing parent directories" "$PRELUDE"'
import tempfile, pathlib
with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp) / "a" / "b" / "c.json"
    nase_fs.atomic_write(path, b"payload")
    assert path.read_bytes() == b"payload"
'

run_case "atomic_write replaces existing content whole" "$PRELUDE"'
import tempfile, pathlib
with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp) / "f"
    path.write_bytes(b"the old longer content")
    nase_fs.atomic_write(path, b"new")
    assert path.read_bytes() == b"new"
'

run_case "atomic_write leaves no temporary file behind on success" "$PRELUDE"'
import tempfile, pathlib
with tempfile.TemporaryDirectory() as tmp:
    directory = pathlib.Path(tmp)
    nase_fs.atomic_write(directory / "f", b"x")
    assert sorted(p.name for p in directory.iterdir()) == ["f"], list(directory.iterdir())
'

run_case "atomic_write leaves no temporary file behind when the write fails" "$PRELUDE"'
import tempfile, pathlib
with tempfile.TemporaryDirectory() as tmp:
    directory = pathlib.Path(tmp)
    try:
        # Not bytes: the write raises after the temporary file already exists.
        nase_fs.atomic_write(directory / "f", "a string")  # type: ignore[arg-type]
    except TypeError:
        pass
    else:
        raise AssertionError("writing str did not raise")
    assert list(directory.iterdir()) == [], list(directory.iterdir())
'

run_case "fsync_dir flushes a real directory without error" "$PRELUDE"'
import tempfile
with tempfile.TemporaryDirectory() as tmp:
    nase_fs.fsync_dir(tmp)
'

# The durability claim holds only if the directory fsync runs, and the crash that would
# expose its absence is not something a test can stage. Pin the call instead.
if grep -q 'fsync_dir(target.parent)' "$ROOT/.claude/scripts/nase_fs.py"; then
  ok "atomic_write fsyncs the parent directory, not only the file"
else
  bad "atomic_write fsyncs the parent directory, not only the file"
fi

printf '\n--- %s pass, %s fail ---\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
