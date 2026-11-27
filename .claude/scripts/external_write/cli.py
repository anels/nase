"""Prepare, authorize, and execute one payload-bound external CLI mutation."""

from __future__ import annotations

import argparse
import signal
import sys
from pathlib import Path

import shell_scan

from .base import ActionError
from .guard import cmd_guard
from .ledger import cmd_audit
from .lifecycle import (
    EXECUTE_TIMEOUT_SECONDS,
    TOKEN_TTL_SECONDS,
    cmd_authorize,
    cmd_execute,
    cmd_prepare,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=Path, default=Path(__file__).resolve().parents[3]
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare = subparsers.add_parser("prepare", help="write an action manifest")
    prepare.add_argument(
        "--system",
        required=True,
        choices=("github", "azure", "kubernetes", "terraform", "confluence"),
    )
    prepare.add_argument("--summary", required=True)
    prepare.add_argument("--github-owner")
    prepare.add_argument("argv", nargs=argparse.REMAINDER)
    prepare.set_defaults(func=cmd_prepare)

    authorize = subparsers.add_parser(
        "authorize", help="write one short-lived approval token"
    )
    authorize.add_argument("--manifest", required=True, type=Path)
    authorize.add_argument(
        "--ttl-seconds",
        "--ttl",
        dest="ttl_seconds",
        type=int,
        default=TOKEN_TTL_SECONDS,
    )
    authorize.set_defaults(func=cmd_authorize)

    execute = subparsers.add_parser(
        "execute", help="run an authorized action without a shell"
    )
    execute.add_argument("--manifest", required=True, type=Path)
    execute.add_argument(
        "--timeout-seconds",
        dest="timeout_seconds",
        type=int,
        default=EXECUTE_TIMEOUT_SECONDS,
        help=f"kill the CLI after this many seconds (default {EXECUTE_TIMEOUT_SECONDS})",
    )
    execute.set_defaults(func=cmd_execute)

    guard = subparsers.add_parser("guard", help="reject raw known mutation commands")
    guard.add_argument(
        "--command", help="command text; read from stdin when omitted"
    )
    guard.add_argument(
        "--cwd", help="working directory of the command; resolves `query=@file` reads"
    )
    guard.add_argument(
        "--inexact-text",
        action="store_true",
        help="the text differs from what the shell runs; refuse the exact-word rules",
    )
    guard.add_argument(
        "--raw-line",
        action="store_true",
        help="stdin opens with the exact command as one JSON string line",
    )
    guard.add_argument(
        "--powershell", action="store_true", help="PowerShell runs the command"
    )
    guard.set_defaults(func=cmd_guard)

    audit = subparsers.add_parser(
        "audit", help="count prepared manifests against the outcome ledger"
    )
    audit.set_defaults(func=cmd_audit)
    return parser


def main() -> int:
    if hasattr(signal, "alarm") and sys.argv[1:2] == ["guard"]:
        signal.alarm(shell_scan.SCAN_TIMEOUT_SECONDS)
    args = build_parser().parse_args()
    args.root = args.root.resolve()
    try:
        return args.func(args)
    except ActionError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
