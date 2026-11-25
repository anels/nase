#!/usr/bin/env bash
# Golden table for the external-write classifier.
#
# tests/fixtures/external-write-golden.tsv records, per command, what the guard answers and
# whether `prepare` accepts it. The second check runs every row of the kubectl value-option
# table past the shared scanner, which both guards read.
#
# Run from repo root:  bash tests/scripts/test-external-write-golden.sh

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PYTHONDONTWRITEBYTECODE=1 python3 - "$TMP" <<'PY'
import argparse
import contextlib
import io
import os
import shlex
import sys
from pathlib import Path

sys.path.insert(0, str(Path(".claude/scripts").resolve()))
import nase_script  # noqa: E402
import shell_scan  # noqa: E402

os.environ.pop("GH_HOST", None)
ewa = nase_script.load_script(
    "external_write_action", Path(".claude/scripts/external-write-action.py").resolve()
)

root = Path(sys.argv[1]).resolve()
(root / "workspace").mkdir()
(root / "workspace" / "config.md").write_text(
    "github_org: owner\ngh_account: expected\nwork_gh_account: expected\n", encoding="utf-8"
)
(root / "q.graphql").write_text("query { viewer { login } }\n", encoding="utf-8")
(root / "m.graphql").write_text("mutation { x }\n", encoding="utf-8")

BLOCKS = {
    "raw external mutation": "block:mutation",
    "unrecognized external": "block:unrecognized",
}


def guard(command):
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        rc = ewa.cmd_guard(argparse.Namespace(command=command, cwd=str(root), root=root))
    if rc == 0:
        return "allow"
    return next((v for k, v in BLOCKS.items() if k in err.getvalue()), "block:unparsed")


def prepare(command):
    ewa.GRAPHQL_FILE_BASE.clear()
    argv = shlex.split(command)
    system = ewa.classify(argv).system
    owner = "owner" if system in (None, "github") else None
    try:
        ewa.action_payload(root, system or "github", "golden", argv, owner)
    except ewa.ActionError as exc:
        return "refuse:" + str(exc).split(";")[0][:60]
    return f"accept:{system}"


passed = failed = 0


def check(name, want, got):
    global passed, failed
    if want == got:
        passed += 1
    else:
        failed += 1
        print(f"FAIL  {name}: expected {want}, got {got}")


table = Path("tests/fixtures/external-write-golden.tsv").read_text(encoding="utf-8")
for line in table.splitlines():
    if not line or line.startswith("#"):
        continue
    want_guard, want_prepare, command = line.split("\t", 2)
    check(command, (want_guard, want_prepare), (guard(command), prepare(command)))

# Every value option the scanner skipped before the two tables became one.
for option in (
    "--as --as-group --as-uid --cache-dir --certificate-authority --client-certificate "
    "--client-key --cluster --context --kubeconfig --log-backtrace-at --log-dir --log-file "
    "--log-file-max-size --log-flush-frequency --namespace --output --password "
    "--request-timeout --selector --server --stderrthreshold --tls-server-name --token "
    "--user --username --vmodule -l -n -o -s -v"
).split():
    command = f"kubectl {option} value exec pod -- git status"
    names = [inv.name for inv in shell_scan.scan(command).invocations]
    check(f"scanner skips the value of {option}", True, "git" in names)

print(f"\n--- {passed} pass, {failed} fail ---")
sys.exit(1 if failed else 0)
PY
