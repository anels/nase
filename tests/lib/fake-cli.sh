#!/usr/bin/env bash
# Make a fake CLI launchable by a native Windows Python.
#
# Source this file and call one helper on each fake after writing it. Windows cannot launch
# an extensionless script, so a bare `gh` would resolve to the real CLI further down PATH.
# Off Windows both helpers only make the script executable.
#
#   fake_cli PATH        add PATH.cmd, which runs PATH with bash. cmd.exe re-reads the
#                        arguments: a newline ends them and `& | < > ^` are interpreted,
#                        so use it only for a fake whose arguments are plain words.
#   fake_cli_exact PATH  add PATH.exe, which hands every argument through unchanged. It
#                        runs PATH with python when the first line names python, else with
#                        bash. Needs pip, whose vendored launcher it reuses.

_fake_cli_windows() {
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) return 0 ;;
  esac
  return 1
}

fake_cli() {
  chmod +x "$1"
  _fake_cli_windows || return 0
  # The running bash by absolute path: a bare `bash` can resolve to the WSL one in
  # System32, and a test that narrows PATH would not find it at all.
  printf '@"%s" "%%~dp0%s" %%*\n' "$(cygpath -w "$BASH")" "${1##*/}" > "$1.cmd"
}

fake_cli_exact() {
  chmod +x "$1"
  _fake_cli_windows || return 0
  python3 - "$(cygpath -m "$1")" "$(cygpath -m "$BASH")" <<'PY'
import io
import pathlib
import sys
import zipfile

from pip._vendor import distlib

script, bash = sys.argv[1], sys.argv[2]
if b"python" in pathlib.Path(script).read_bytes().split(b"\n", 1)[0]:
    main = f"""
import runpy, sys
sys.argv[0] = {script!r}
runpy.run_path({script!r}, run_name="__main__")
"""
else:
    # MSYS bash re-parses a command line built by a native process and loses quotes in it,
    # so the arguments travel in a NUL-separated file that a second bash reads back.
    forwarder = script + ".forward"
    pathlib.Path(forwarder).write_bytes(
        b'mapfile -d "" -t args < "$1"\nrm -f "$1"\nexec "$BASH" "$2" "${args[@]}"\n'
    )
    main = f"""
import os, subprocess, sys, tempfile
handle, argv_file = tempfile.mkstemp()
with os.fdopen(handle, "wb") as out:
    out.write(b"".join(a.encode("utf-8", "surrogateescape") + bytes(1) for a in sys.argv[1:]))
sys.exit(subprocess.call([{bash!r}, {forwarder!r}, argv_file, {script!r}]))
"""

bundle = io.BytesIO()
with zipfile.ZipFile(bundle, "w") as archive:
    archive.writestr("__main__.py", main)
# distlib's console launcher: it reads the shebang appended after it, then runs itself as
# a zip archive with that interpreter.
launcher = pathlib.Path(distlib.__file__).with_name("t64.exe").read_bytes()
shebang = f'#!"{sys.executable}"\n'.encode()
pathlib.Path(script + ".exe").write_bytes(launcher + shebang + bundle.getvalue())
PY
}
