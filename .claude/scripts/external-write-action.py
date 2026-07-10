#!/usr/bin/env python3
"""Prepare, authorize, and execute one payload-bound external CLI mutation."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


TOKEN_TTL_SECONDS = 300
MANIFEST_VERSION = 1
MUTATING_HTTP_METHODS = {"POST", "PUT", "PATCH", "DELETE"}
AZURE_MUTATING_VERBS = {
    "add", "apply", "assign", "cancel", "create", "delete", "invoke-action",
    "purge", "remove", "restart", "resume", "set", "start", "stop", "swap",
    "unassign", "update",
}
AZURE_READ_VERBS = {
    "check", "describe", "exists", "get", "list", "query", "show", "status", "view", "what-if",
}
PAYLOAD_FILE_FLAGS = {"--body-file", "--input", "--file"}
SHELL_SEPARATORS = {";", "&&", "&", "|", "||", "(", ")"}
SHELL_INTERPRETERS = {"bash", "dash", "ksh", "sh", "zsh"}


class ActionError(Exception):
    """A caller supplied an unsafe or invalid action."""


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def sha256(value: Any) -> str:
    return hashlib.sha256(canonical_json(value)).hexdigest()


def file_sha256(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def utc_now() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_timestamp(value: str) -> datetime:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ActionError("token created_at is invalid") from exc


def mutation_system(argv: list[str]) -> str | None:
    if not argv:
        return None
    executable = Path(argv[0]).name.lower()
    words = [word.lower() for word in argv[1:]]

    if executable == "gh":
        if not words:
            return None
        if words[0] == "api":
            if graphql_read_query(argv):
                return None
            method = option_value(argv[2:], "--method", "-X")
            if method is None and any(flag in argv[2:] for flag in ("-f", "-F", "--raw-field", "--field", "--input")):
                method = "POST"
            if method and method.upper() in MUTATING_HTTP_METHODS:
                return "github"
        if len(words) >= 2 and words[0] in {"pr", "issue", "release", "repo", "gist", "label", "variable", "secret", "cache"}:
            if words[1] in {"create", "edit", "close", "reopen", "ready", "review", "merge", "delete", "comment", "set"}:
                return "github"
        if words[:2] == ["workflow", "run"]:
            return "github"
        return None

    if executable == "az":
        if not words:
            return None
        if words[0] == "rest":
            method = option_value(argv[2:], "--method")
            if method and method.upper() in MUTATING_HTTP_METHODS:
                return "azure"
        if words[:2] == ["pipelines", "run"]:
            return "azure"
        if any(word in AZURE_MUTATING_VERBS for word in words):
            return "azure"
        return None

    if executable == "kubectl":
        if words and words[0] in {"annotate", "apply", "cordon", "create", "delete", "drain", "edit", "label", "patch", "replace", "scale", "taint", "uncordon"}:
            return "kubernetes"
        if len(words) >= 2 and words[0] == "rollout" and words[1] in {"pause", "restart", "resume", "undo"}:
            return "kubernetes"
        return None

    if executable == "terraform" and words and words[0] in {"apply", "destroy"}:
        return "terraform"

    return None


def option_value(argv: list[str], *names: str) -> str | None:
    for index, value in enumerate(argv):
        if value in names and index + 1 < len(argv):
            return argv[index + 1]
        for name in names:
            if value.startswith(f"{name}="):
                return value.split("=", 1)[1]
    return None


def graphql_read_query(argv: list[str]) -> bool:
    """Recognize direct `gh api graphql` query requests without opening a write path."""
    if len(argv) < 3 or argv[1:3] != ["api", "graphql"]:
        return False
    query_values: list[str] = []
    for index, value in enumerate(argv[3:]):
        if value in {"-f", "-F", "--raw-field", "--field"} and index + 4 < len(argv):
            candidate = argv[index + 4]
            if candidate.startswith("query="):
                query_values.append(candidate.split("=", 1)[1])
        elif value.startswith(("-f=query=", "-F=query=", "--raw-field=query=", "--field=query=")):
            query_values.append(value.split("query=", 1)[1])
    if len(query_values) != 1:
        return False
    query = query_values[0].lstrip()
    return not re.search(r"\bmutation\b", query, re.IGNORECASE) and (
        query.startswith("query") or query.startswith("{") or query.startswith("fragment")
    )


def external_action_dir(root: Path) -> Path:
    return root / "workspace" / "tmp" / "external-actions"


def token_path(root: Path) -> Path:
    return root / "workspace" / ".external-write-token"


def resolve_payload_path(root: Path, raw_path: str) -> Path:
    path = Path(raw_path)
    if not path.is_absolute():
        path = root / path
    return path.resolve()


def payload_files(root: Path, argv: list[str]) -> list[dict[str, Any]]:
    candidates: list[tuple[int, str]] = []
    for index, value in enumerate(argv):
        if value.startswith("@") and len(value) > 1:
            candidates.append((index, value[1:]))
        if value in PAYLOAD_FILE_FLAGS and index + 1 < len(argv):
            candidates.append((index + 1, argv[index + 1]))
        option, delimiter, option_value_text = value.partition("=")
        if delimiter and (option in PAYLOAD_FILE_FLAGS or option_value_text.startswith("@")):
            candidates.append((index, option_value_text.removeprefix("@")))

    files: list[dict[str, Any]] = []
    seen: set[tuple[int, str]] = set()
    for index, value in candidates:
        key = (index, value)
        if key in seen:
            continue
        seen.add(key)
        path = resolve_payload_path(root, value)
        if not path.is_file():
            raise ActionError(f"payload file does not exist: {value}")
        files.append({"arg_index": index, "path": str(path), "sha256": file_sha256(path)})
    return files


def action_payload(root: Path, system: str, summary: str, argv: list[str]) -> dict[str, Any]:
    actual_system = mutation_system(argv)
    if actual_system is None:
        raise ActionError("command is not an allowlisted external mutation")
    if system != actual_system:
        raise ActionError(f"system must be {actual_system} for this command")
    files = payload_files(root, argv)
    payload = {"argv": argv, "payload_files": files}
    return {
        "system": system,
        "summary": summary,
        "argv": argv,
        "payload_files": files,
        "payload_sha256": sha256(payload),
    }


def ensure_manifest_path(root: Path, path: Path) -> Path:
    resolved = path.resolve()
    try:
        resolved.relative_to(external_action_dir(root).resolve())
    except ValueError as exc:
        raise ActionError("manifest must live under workspace/tmp/external-actions") from exc
    return resolved


def load_manifest(root: Path, path: Path) -> tuple[Path, dict[str, Any]]:
    resolved = ensure_manifest_path(root, path)
    try:
        data = json.loads(resolved.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ActionError(f"cannot read manifest: {exc}") from exc
    if data.get("version") != MANIFEST_VERSION or not isinstance(data.get("action"), dict):
        raise ActionError("manifest schema is invalid")
    action = data["action"]
    if data.get("action_sha256") != sha256(action):
        raise ActionError("manifest action hash does not match")
    argv = action.get("argv")
    if not isinstance(argv, list) or not all(isinstance(value, str) for value in argv):
        raise ActionError("manifest argv is invalid")
    if mutation_system(argv) != action.get("system"):
        raise ActionError("manifest command is not an allowlisted mutation")
    expected_payload = sha256({"argv": argv, "payload_files": action.get("payload_files", [])})
    if action.get("payload_sha256") != expected_payload:
        raise ActionError("manifest payload hash does not match")
    return resolved, data


def verify_payload_files(root: Path, action: dict[str, Any]) -> None:
    for entry in action.get("payload_files", []):
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
            raise ActionError("manifest payload file entry is invalid")
        path = Path(entry["path"])
        if not path.is_absolute():
            path = resolve_payload_path(root, entry["path"])
        if not path.is_file() or file_sha256(path) != entry.get("sha256"):
            raise ActionError(f"payload file changed after approval: {entry['path']}")


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(f"{path.suffix}.tmp-{uuid.uuid4().hex}")
    temporary.write_bytes(canonical_json(value) + b"\n")
    os.chmod(temporary, 0o600)
    temporary.replace(path)


def command_segments(command: str) -> list[list[str]]:
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()")
        lexer.whitespace_split = True
        lexer.commenters = ""
        tokens = list(lexer)
    except ValueError:
        return []
    segments: list[list[str]] = [[]]
    for token in tokens:
        if token in SHELL_SEPARATORS:
            if segments[-1]:
                segments.append([])
            continue
        segments[-1].append(token)
    return [segment for segment in segments if segment]


def unwrap_shell_segment(segment: list[str]) -> list[str]:
    index = 0
    while index < len(segment) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", segment[index]):
        index += 1
    while index < len(segment):
        executable = Path(segment[index]).name
        if executable == "command":
            index += 1
            continue
        if executable == "env":
            index += 1
            while index < len(segment) and (segment[index].startswith("-") or "=" in segment[index]):
                index += 1
            continue
        if executable in {"sudo", "doas"}:
            index += 1
            while index < len(segment) and segment[index].startswith("-"):
                index += 1
            continue
        break
    return segment[index:]


def shell_command(argv: list[str]) -> str | None:
    if not argv or Path(argv[0]).name.lower() not in SHELL_INTERPRETERS:
        return None
    for index, option in enumerate(argv[1:], 1):
        has_command = option in {"-c", "--command"} or (
            option.startswith("-") and not option.startswith("--") and "c" in option[1:]
        )
        if has_command:
            return argv[index + 1] if index + 1 < len(argv) else ""
    return None


def is_dynamic_shell_command(command: str) -> bool:
    """Detect shell constructs whose executed command cannot be statically bound."""
    return bool(re.search(
        r"`|\$\(|[{}]|(?:^|[;&|]\s*)\s*(?:alias|eval|function|source)\b",
        command,
    ))


def command_argvs(command: str, depth: int = 0):
    if re.search(r"(?:\||<)\s*(?:bash|dash|ksh|sh|zsh)\b", command):
        yield ["__unrecognized_shell_command__"]
        return
    for segment in command_segments(command):
        argv = unwrap_shell_segment(segment)
        if not argv:
            continue
        yield argv
        nested = shell_command(argv)
        if nested is None:
            continue
        if depth >= 8 or not nested or is_dynamic_shell_command(nested):
            yield ["__unrecognized_shell_command__"]
            continue
        yield from command_argvs(nested, depth + 1)


def command_has_mutation(command: str) -> bool:
    return any(mutation_system(argv) for argv in command_argvs(command))


def known_safe_external_command(argv: list[str]) -> bool:
    if not argv:
        return True
    executable = Path(argv[0]).name.lower()
    words = [word.lower() for word in argv[1:]]
    if executable == "gh":
        if not words or words[0] == "auth":
            return True
        if words[0] == "api":
            if graphql_read_query(argv):
                return True
            method = option_value(argv[2:], "--method", "-X")
            return method in (None, "GET", "get") and not any(
                flag in argv[2:] for flag in ("-f", "-F", "--raw-field", "--field", "--input")
            )
        return len(words) >= 2 and words[1] in {
            "checks", "diff", "list", "status", "view", "watch",
        }
    if executable == "az":
        if not words or words[0] in {"account", "cloud", "configure", "extension", "login", "logout", "version"}:
            return True
        if words[0] == "rest":
            method = option_value(argv[2:], "--method")
            return method is not None and method.upper() in {"GET", "HEAD"}
        return any(word in AZURE_READ_VERBS for word in words)
    if executable == "kubectl":
        return bool(words) and words[0] in {
            "api-resources", "cluster-info", "config", "describe", "diff", "get", "logs", "top", "version",
        }
    if executable == "terraform":
        return bool(words) and words[0] in {
            "fmt", "graph", "output", "plan", "providers", "show", "validate", "version",
        }
    return True


def command_has_unrecognized_external_cli(command: str) -> bool:
    for argv in command_argvs(command):
        if argv == ["__unrecognized_shell_command__"]:
            return True
        executable = Path(argv[0]).name.lower() if argv else ""
        if executable in {"gh", "az", "kubectl", "terraform"} and mutation_system(argv) is None:
            if not known_safe_external_command(argv):
                return True
    return False


def cmd_prepare(args: argparse.Namespace) -> int:
    argv = list(args.argv)
    if argv and argv[0] == "--":
        argv.pop(0)
    action = action_payload(args.root, args.system, args.summary, argv)
    action_dir = external_action_dir(args.root)
    action_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(action_dir, 0o700)
    path = action_dir / f"{datetime.now(UTC).strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex}.json"
    manifest = {"version": MANIFEST_VERSION, "created_at": utc_now(), "action": action}
    manifest["action_sha256"] = sha256(action)
    write_json(path, manifest)
    print(json.dumps({"manifest": str(path), "action": action}, sort_keys=True))
    return 0


def cmd_authorize(args: argparse.Namespace) -> int:
    _, manifest = load_manifest(args.root, args.manifest)
    if not 0 < args.ttl_seconds <= TOKEN_TTL_SECONDS:
        raise ActionError(f"token TTL must be between 1 and {TOKEN_TTL_SECONDS} seconds")
    path = token_path(args.root)
    active_claim = next(path.parent.glob(f"{path.name}.executing-*"), None)
    if path.exists() or active_claim is not None:
        raise ActionError("an external-write token is already active; execute or remove it before authorizing another action")
    token = {
        "version": MANIFEST_VERSION,
        "action_sha256": manifest["action_sha256"],
        "created_at": utc_now(),
        "ttl_seconds": args.ttl_seconds,
    }
    write_json(path, token)
    print(json.dumps({"token": str(path), "expires_in_seconds": args.ttl_seconds}, sort_keys=True))
    return 0


def claim_token(root: Path) -> tuple[Path, dict[str, Any]]:
    """Atomically move the one-shot token out of circulation before execution."""
    path = token_path(root)
    claimed = path.with_name(f"{path.name}.executing-{uuid.uuid4().hex}")
    try:
        path.replace(claimed)
    except FileNotFoundError as exc:
        raise ActionError("no external-write token present") from exc
    try:
        token = json.loads(claimed.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        claimed.unlink(missing_ok=True)
        raise ActionError(f"external-write token is invalid: {exc}") from exc
    return claimed, token


def verify_token(token: dict[str, Any], manifest: dict[str, Any]) -> None:
    if token.get("version") != MANIFEST_VERSION:
        raise ActionError("external-write token schema is invalid")
    if token.get("action_sha256") != manifest.get("action_sha256"):
        raise ActionError("external-write token does not match this manifest")
    created_at = parse_timestamp(str(token.get("created_at", "")))
    ttl = token.get("ttl_seconds")
    if not isinstance(ttl, int) or ttl <= 0 or ttl > TOKEN_TTL_SECONDS:
        raise ActionError("external-write token TTL is invalid")
    age = (datetime.now(UTC) - created_at).total_seconds()
    if age < 0 or age > ttl:
        raise ActionError("external-write token is stale or from the future")


def cmd_execute(args: argparse.Namespace) -> int:
    token_file: Path | None = None
    try:
        token_file, token = claim_token(args.root)
        _, manifest = load_manifest(args.root, args.manifest)
        verify_token(token, manifest)
        action = manifest["action"]
        verify_payload_files(args.root, action)
        completed = subprocess.run(action["argv"], cwd=args.root, check=False)
        return completed.returncode
    finally:
        if token_file is not None:
            token_file.unlink(missing_ok=True)


def cmd_guard(args: argparse.Namespace) -> int:
    if args.command and not command_segments(args.command):
        print("BLOCKED: could not safely parse external CLI command.", file=sys.stderr)
        return 10
    if command_has_mutation(args.command):
        print(
            "BLOCKED: raw external mutation. Prepare, show, authorize, and execute the action with "
            ".claude/scripts/external-write-action.py instead.",
            file=sys.stderr,
        )
        return 10
    if command_has_unrecognized_external_cli(args.command):
        print(
            "BLOCKED: unrecognized external CLI command. Use an explicit read-only command or "
            "prepare an allowlisted payload-bound mutation action.",
            file=sys.stderr,
        )
        return 10
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare = subparsers.add_parser("prepare", help="write an action manifest")
    prepare.add_argument("--system", required=True, choices=("github", "azure", "kubernetes", "terraform"))
    prepare.add_argument("--summary", required=True)
    prepare.add_argument("argv", nargs=argparse.REMAINDER)
    prepare.set_defaults(func=cmd_prepare)

    authorize = subparsers.add_parser("authorize", help="write one short-lived approval token")
    authorize.add_argument("--manifest", required=True, type=Path)
    authorize.add_argument("--ttl-seconds", "--ttl", dest="ttl_seconds", type=int, default=TOKEN_TTL_SECONDS)
    authorize.set_defaults(func=cmd_authorize)

    execute = subparsers.add_parser("execute", help="run an authorized action without a shell")
    execute.add_argument("--manifest", required=True, type=Path)
    execute.set_defaults(func=cmd_execute)

    guard = subparsers.add_parser("guard", help="reject raw known mutation commands")
    guard.add_argument("--command", required=True)
    guard.set_defaults(func=cmd_guard)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    args.root = args.root.resolve()
    try:
        return args.func(args)
    except ActionError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
