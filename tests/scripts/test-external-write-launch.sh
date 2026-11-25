#!/usr/bin/env bash
# How external-write-action.py picks the program it launches. A file planted in the working
# directory must never run on the guarded write path. Every CLI here is a local fake and
# the PATH under test holds nothing else, so no real external write can happen.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

python3 - "$ROOT/.claude/scripts/external-write-action.py" "$TMPDIR_TEST" <<'PY'
import importlib.util
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(sys.argv[1])
TMP = Path(sys.argv[2]).resolve()
WINDOWS = os.name == "nt"
# A developer shell may set this, which would hide the Windows behaviour under test.
os.environ.pop("NODEFAULTCURRENTDIRECTORYINEXEPATH" if WINDOWS else "NoDefaultCurrentDirectoryInExePath", None)

spec = importlib.util.spec_from_file_location("external_write_action", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

failures = 0


def check(name, ok, detail=""):
    global failures
    if ok:
        print(f"PASS  {name}")
    else:
        failures += 1
        print(f"FAIL  {name} {detail}".rstrip(), file=sys.stderr)


def script_file(path, batch, shell):
    path.parent.mkdir(parents=True, exist_ok=True)
    if WINDOWS:
        path.write_text("@echo off\n" + batch + "\n", encoding="utf-8", newline="\r\n")
    else:
        path.write_text("#!/bin/sh\n" + shell + "\n", encoding="utf-8", newline="\n")
        path.chmod(0o755)


def program(directory, name, batch="exit /b 0", shell="exit 0", suffix=".cmd"):
    path = directory / (name + suffix if WINDOWS else name)
    script_file(path, batch, shell)
    return path


# --- resolution ----------------------------------------------------------------------

work = TMP / "work"
tools = TMP / "tools"
later = TMP / "later"
for directory in (work, work / "rel"):
    for name in ("gh", "onlyhere"):
        program(directory, name)
        if WINDOWS:
            program(directory, name, suffix=".bat")
            shutil.copy(sys.executable, directory / f"{name}.exe")
fake_gh = program(tools, "gh")
program(later, "gh")
os.chdir(work)


def resolve(argv, *entries):
    os.environ["PATH"] = os.pathsep.join(str(entry) for entry in entries)
    try:
        return module.launch_argv(argv)
    except FileNotFoundError as exc:
        return exc


def resolves_to(name, argv, expected, *entries):
    result = resolve(argv, *entries)
    ok = (
        isinstance(result, list)
        and os.path.normcase(result[0]) == os.path.normcase(str(expected))
        and result[1:] == argv[1:]
    )
    check(name, ok, repr(result))


def refused(name, argv, *entries):
    result = resolve(argv, *entries)
    check(name, isinstance(result, FileNotFoundError) and argv[0] in str(result), repr(result))


resolves_to("a PATH program wins over files in the working directory",
            ["gh", "pr", "a b"], fake_gh, tools, later)

if WINDOWS:
    drive, rooted = os.path.splitdrive(str(tools))
    resolves_to("empty and relative PATH entries are skipped",
                ["gh"], fake_gh, "", ".", "rel", rooted, drive + "rel", tools)
    refused("a program only in the working directory is not launched", ["onlyhere"], tools)
    refused("an empty PATH entry does not search the working directory", ["onlyhere"], "", tools)
    refused("a dot PATH entry does not search the working directory", ["onlyhere"], ".")
    refused("a relative PATH entry is not searched", ["onlyhere"], "rel")
    refused("a drive-relative PATH entry is not searched", ["onlyhere"], drive + "rel")
    refused("a rooted PATH entry without a drive is not searched", ["gh"], rooted)
    refused("an unset PATH resolves nothing", ["gh"])
    for kind, relative in (
        ("dot", ".\\gh.cmd"),
        ("dot, forward slash", "./gh"),
        ("subdirectory", "rel\\gh"),
        ("drive-relative", drive + "gh"),
        ("rooted without a drive", rooted + "\\gh"),
    ):
        refused(f"a program path that is not fully qualified is refused ({kind})",
                [relative], tools)
    resolves_to("a fully qualified program path is kept", [str(fake_gh)], fake_gh)
    resolves_to("a fully qualified path without a suffix is completed",
                [str(tools / "gh")], fake_gh)
    resolves_to("a name with its suffix resolves from PATH", ["gh.cmd"], fake_gh, tools)
    resolves_to("a quoted PATH entry resolves", ["gh"], fake_gh, f'"{tools}"')
    both = TMP / "both"
    program(both, "gh")
    shutil.copy(sys.executable, both / "gh.exe")
    resolves_to("an .exe is preferred over a .cmd in one directory",
                ["gh"], both / "gh.exe", both, tools)
else:
    check("POSIX keeps the bare name when PATH lacks the program",
          resolve(["onlyhere", "x"], tools) == ["onlyhere", "x"])
    check("POSIX keeps a relative program path",
          resolve(["./gh"], tools) == ["./gh"])

# --- prepare, authorize, execute -----------------------------------------------------

# The planted files sit in the workspace root, which is both the caller's directory and
# the directory the CLI runs in.
workspace = TMP / "workspace-root"
fakes = TMP / "fakes"
(workspace / "workspace" / "tmp").mkdir(parents=True)
(workspace / "workspace" / "config.md").write_text(
    "github_org: owner\ngh_account: expected\nwork_gh_account: expected\n", encoding="utf-8"
)
planted_marker = TMP / "planted.txt"
fake_marker = TMP / "fake.txt"
RECORD_PLANTED = {
    "batch": 'echo planted>>"%NASE_PLANTED_MARKER%"',
    "shell": 'echo planted >> "$NASE_PLANTED_MARKER"',
}
for name in ("gh", "az", "kubectl", "nested-helper"):
    program(workspace, name, **RECORD_PLANTED)
    if WINDOWS:
        program(workspace, name, suffix=".bat", **RECORD_PLANTED)
if WINDOWS:
    # An .exe cannot write the marker, so a run of this copy shows in the exit code.
    shutil.copy(
        Path(os.environ["SYSTEMROOT"]) / "System32" / "whoami.exe", workspace / "kubectl.exe"
    )

program(
    fakes, "gh",
    batch='if "%1 %2"=="auth token" (echo test-token& exit /b 0)\n'
          'if "%1 %2"=="api user" (echo expected& exit /b 0)\n'
          'echo gh>>"%NASE_FAKE_MARKER%"',
    shell='case "$1 $2" in\n'
          '  "auth token") echo test-token; exit 0 ;;\n'
          '  "api user") echo expected; exit 0 ;;\n'
          'esac\n'
          'echo gh >> "$NASE_FAKE_MARKER"',
)
program(fakes, "az", batch='echo az>>"%NASE_FAKE_MARKER%"',
        shell='echo az >> "$NASE_FAKE_MARKER"')
# A wrapper that runs a helper by bare name, as some installed wrappers do.
program(fakes, "terraform",
        batch='call nested-helper 2>nul\necho terraform>>"%NASE_FAKE_MARKER%"',
        shell='nested-helper 2>/dev/null\necho terraform >> "$NASE_FAKE_MARKER"')
empty = TMP / "empty"
empty.mkdir()


def cli(path_entry, *args):
    environment = dict(os.environ)
    environment.update(
        PATH=str(path_entry),
        GH_CONFIG_DIR=str(TMP / "gh-config"),
        NASE_PLANTED_MARKER=str(planted_marker),
        NASE_FAKE_MARKER=str(fake_marker),
    )
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--root", str(workspace), *args],
        cwd=workspace, env=environment, capture_output=True, text=True,
        stdin=subprocess.DEVNULL, timeout=120, check=False,
    )


def execute(name, system, argv, path_entry, expected_rc, expected_fake):
    for marker in (planted_marker, fake_marker):
        marker.unlink(missing_ok=True)
    prepared = cli(path_entry, "prepare", "--system", system, "--summary", name, "--", *argv)
    if prepared.returncode != 0:
        check(name, False, f"prepare: {prepared.stderr}")
        return
    manifest = json.loads(prepared.stdout)["manifest"]
    authorized = cli(path_entry, "authorize", "--manifest", manifest)
    if authorized.returncode != 0:
        check(name, False, f"authorize: {authorized.stderr}")
        return
    done = cli(path_entry, "execute", "--manifest", manifest)
    fake = fake_marker.read_text(encoding="utf-8").split() if fake_marker.exists() else []
    ok = (
        done.returncode == expected_rc
        and not planted_marker.exists()
        and fake == expected_fake
        and (expected_rc != 12 or "could not launch" in done.stderr)
        and "Traceback" not in done.stderr
    )
    check(name, ok, f"rc={done.returncode} planted={planted_marker.exists()} "
                    f"fake={fake} err={done.stderr!r}")


GH_WRITE = ["gh", "pr", "create", "--draft", "--title", "Example", "--body", "payload",
            "-R", "owner/example"]
AZ_WRITE = ["az", "group", "delete", "--name", "example"]
KUBECTL_WRITE = ["kubectl", "delete", "pod", "example"]

execute("GitHub write and its token lookups run the PATH program",
        "github", GH_WRITE, fakes, 0, ["gh"])
execute("GitHub write fails closed when PATH lacks gh",
        "github", GH_WRITE, empty, 12, [])
execute("Azure write runs the PATH wrapper",
        "azure", AZ_WRITE, fakes, 0, ["az"])
execute("Azure write fails closed when PATH lacks az",
        "azure", AZ_WRITE, empty, 12, [])
execute("Kubernetes write fails closed when PATH lacks kubectl",
        "kubernetes", KUBECTL_WRITE, empty, 12, [])
execute("a PATH wrapper's own bare lookup skips the working directory",
        "terraform", ["terraform", "apply", "-auto-approve"], fakes, 0, ["terraform"])
if WINDOWS:
    execute("a relative program path is not launched",
            "kubernetes", [".\\kubectl.bat", "delete", "pod", "example"], fakes, 12, [])

os.chdir(TMP)
if failures:
    print(f"{failures} check(s) failed", file=sys.stderr)
    raise SystemExit(1)
PY
