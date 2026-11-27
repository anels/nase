from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any

from nase_fs import sha256_file

from .base import ActionError
from .classification import (
    expand_gh_api_args,
    expand_gh_api_tokens,
    gh_noun_first,
    program_name,
    terraform_chdir,
    terraform_command,
    terraform_subcommand,
)
from .prose import (
    lint_prose_texts,
    prose_gate_findings,
    prose_inline_texts,
    prose_surface,
)

PAYLOAD_FILE_FLAGS = {"--body-file", "--input", "--file"}


def external_action_dir(root: Path) -> Path:
    return root / "workspace" / "tmp" / "external-actions"


def token_path(root: Path) -> Path:
    return root / "workspace" / ".external-write-token"


def payload_base(root: Path, argv: list[str]) -> Path:
    """Directory the CLI resolves a relative payload path against."""
    if argv and program_name(argv[0]) == "terraform":
        chdir = terraform_chdir(argv)
        if chdir:
            return resolve_payload_path(root, chdir)
    return root


def resolve_payload_path(root: Path, raw_path: str) -> Path:
    path = Path(raw_path)
    if not path.is_absolute():
        path = root / path
    return path.resolve()


def reject_symlinked_path(root: Path, raw_path: str) -> None:
    """Refuse a payload path that reaches its file through a symlink.

    The manifest stores the resolved real path, but the CLI later opens `raw_path`
    itself, so a link retargeted after approval would feed it different bytes than the
    ones hashed. The file may not be a link at all, and no directory above it may be a
    link unless the root user owns it: that is a system alias such as macOS `/var`
    and `/tmp`, which the approving user cannot repoint. `verify_payload_files` closes
    the remaining gap by re-resolving the argument at execute time.
    """
    path = Path(raw_path)
    current = Path(path.anchor) if path.is_absolute() else root
    parts = path.parts[1:] if path.is_absolute() else path.parts
    for position, part in enumerate(parts):
        if part == "..":
            current = current.parent
            continue
        candidate = current / part
        if candidate.is_symlink():
            if position == len(parts) - 1 or candidate.lstat().st_uid != 0:
                raise ActionError(
                    f"payload path must not be or pass through a symlink: {raw_path}"
                )
            candidate = candidate.resolve()
        current = candidate


def positional_arguments(
    argv: list[str],
    start: int,
    value_options: set[str],
) -> list[tuple[int, str]]:
    found: list[tuple[int, str]] = []
    index = start
    options = True
    while index < len(argv):
        value = argv[index]
        if options and value == "--":
            options = False
        elif options and value in value_options:
            index += 1
        elif options and value.startswith("-") and value != "-":
            pass
        else:
            found.append((index, value))
        index += 1
    return found


def payload_scan_tokens(argv: list[str]) -> list[tuple[int, str]]:
    """The words a CLI's flag parser sees after the program name, with their argv index."""
    if argv[:2] and program_name(argv[0]) == "gh" and argv[1:2] == ["api"]:
        tokens, _ = expand_gh_api_tokens(argv[2:])
        return [(index + 2, token) for index, token in tokens]
    return list(enumerate(argv))[1:]


def implicit_file_candidates(value: str) -> list[str]:
    """Strings a token could name a file by: itself, `--flag=PATH`, `key=@PATH`, `-fPATH`."""
    raw = [value]
    _, delimiter, tail = value.partition("=")
    if delimiter and tail:
        raw.extend([tail, tail.rsplit("=", 1)[-1]])
    if re.fullmatch(r"-[A-Za-z].+", value):
        raw.append(value[2:].removeprefix("="))
    found: list[str] = []
    for item in raw:
        candidate = item.removeprefix("@")
        if candidate and candidate != "-" and candidate not in found:
            found.append(candidate)
    return found


def attach_page_index(argv: list[str]) -> int:
    """The page `confluence-publish.py attach` works on; the script defaults to 0.

    argparse accepts a unique prefix such as `--page-in` and keeps the last value
    of a repeated flag, so this reads the flag the same way.
    """
    page = 0
    for position, word in enumerate(argv):
        name, equals, value = word.partition("=")
        if len(name) < len("--page-in") or not "--page-index".startswith(name):
            continue
        if not equals:
            if position + 1 >= len(argv):
                continue
            value = argv[position + 1]
        try:
            page = int(value)
        except ValueError:
            page = 0
    return page


def confluence_attach_files(
    root: Path, bound: list[dict[str, Any]], page_index: int
) -> list[tuple[int, str, bool]]:
    """Name the body file and PNGs a bound `attach` plan will upload or rewrite.

    The approver reads the plan, but the bytes that reach Confluence are the PNGs
    beside it, so they are part of the payload. Only the page `attach` was asked for
    counts. Its body file must exist, but a PNG that is not on disk is left to
    `attach`, which reports it as `attach-failed:missing-png`. Each item is
    `(arg_index, path, required)`.
    """
    found: list[tuple[int, str, bool]] = []
    for entry in bound:
        path = Path(entry["path"])
        if path.suffix.lower() != ".json":
            continue
        try:
            plan = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        pages = plan.get("pages") if isinstance(plan, dict) else None
        if not isinstance(pages, list):
            continue
        assets = os.path.join(
            os.path.dirname(os.path.abspath(root / entry["arg"])), "assets"
        )
        for page in pages:
            if not isinstance(page, dict):
                raise ActionError(f"attach plan has a malformed page entry: {entry['arg']}")
            if page.get("index") != page_index:
                continue
            if isinstance(page.get("body_file"), str):
                found.append((entry["arg_index"], page["body_file"], True))
            found.extend(
                (entry["arg_index"], os.path.join(assets, visual["png"]), False)
                for visual in page.get("visuals") or []
                if isinstance(visual, dict)
                and isinstance(visual.get("png"), str)
                and visual.get("status") != "attached"
            )
    return found


def payload_files(root: Path, argv: list[str], system: str) -> list[dict[str, Any]]:
    """Bind every file the CLI will read into the approved action.

    Two passes feed one list. The flag tables name the files a command is known to
    read; a named file that is missing is an error, because the CLI would fail on it
    later. The second pass binds any other word that resolves to an existing regular
    file, so a file-valued flag missing from the tables cannot slip past unhashed.
    """
    executable = program_name(argv[0]) if argv else ""
    file_flags = set(PAYLOAD_FILE_FLAGS)
    if executable == "gh":
        file_flags.update({"--env-file", "--notes-file"})
        if gh_noun_first(argv)[1:2] in (["pr"], ["issue"], ["release"]):
            # `-F` is `--body-file` for these, but a field flag for `gh api` and
            # `gh workflow run`, where `key=@file` is handled below.
            file_flags.add("-F")
    elif executable == "az":
        file_flags.update({"--in-file", "--template-file", "--yaml-path"})
    elif executable == "kubectl":
        file_flags.update(
            {
                "-f",
                "-k",
                "--cert",
                "--filename",
                "--from-env-file",
                "--from-file",
                "--key",
                "--kustomize",
                "--patch-file",
            }
        )
    elif executable == "terraform":
        file_flags.add("-var-file")

    tokens = payload_scan_tokens(argv)
    candidates: list[tuple[int, str]] = []
    for position, (index, value) in enumerate(tokens):
        if value.startswith("@") and len(value) > 1:
            candidates.append((index, value[1:]))
        if value in file_flags and position + 1 < len(tokens):
            value_index, candidate = tokens[position + 1]
            if value == "--from-file":
                candidate = candidate.rsplit("=", 1)[-1]
            candidates.append((value_index, candidate))
        option, delimiter, option_value_text = value.partition("=")
        if delimiter and (option in file_flags or option_value_text.startswith("@")):
            candidate = option_value_text.removeprefix("@")
            if option == "--from-file":
                candidate = candidate.rsplit("=", 1)[-1]
            candidates.append((index, candidate))
        elif (
            len(value) > 2
            and value[0] == "-"
            and value[1] != "-"
            and value[:2] in file_flags
        ):
            candidates.append((index, value[2:]))

    if executable == "gh" and argv[1:3] == ["gist", "create"]:
        candidates.extend(
            positional_arguments(
                argv,
                3,
                {"-d", "--desc", "-f", "--filename"},
            )
        )
    elif executable == "gh" and argv[1:3] == ["release", "create"]:
        positionals = positional_arguments(
            argv,
            3,
            {
                "--discussion-category",
                "-n",
                "--notes",
                "-F",
                "--notes-file",
                "--notes-start-tag",
                "--target",
                "-t",
                "--title",
                "-R",
                "--repo",
            },
        )
        candidates.extend(
            (index, value.split("#", 1)[0]) for index, value in positionals[1:]
        )

    if (
        system == "terraform"
        and terraform_subcommand([word.lower() for word in argv[1:]]) == "apply"
    ):
        command = terraform_command(argv[1:]) or []
        subcommand_index = len(argv) - len(command)
        positionals = positional_arguments(
            argv,
            subcommand_index + 1,
            {
                "-backup",
                "-lock-timeout",
                "-parallelism",
                "-replace",
                "-state",
                "-state-out",
                "-target",
                "-var",
                "-var-file",
            },
        )
        candidates.extend(positionals[-1:])

    files: list[dict[str, Any]] = []
    seen: set[tuple[int, str]] = set()
    base = payload_base(root, argv)

    def bind(index: int, value: str, required: bool) -> None:
        if (index, value) in seen:
            return
        seen.add((index, value))
        if value == "-":
            if required:
                raise ActionError("stdin payloads cannot be bound to an approved action")
            return
        try:
            path = resolve_payload_path(base, value)
            is_file = path.is_file()
        except (OSError, ValueError):
            path = None
            is_file = False
        if path is None or not is_file:
            if required:
                raise ActionError(f"payload file does not exist: {value}")
            return
        if required:
            reject_symlinked_path(base, value)
        try:
            digest = sha256_file(path)
        except OSError as exc:
            if required:
                raise ActionError(f"cannot read payload file {value}: {exc}") from exc
            return
        entry: dict[str, Any] = {
            "arg_index": index,
            "arg": value,
            "path": str(path),
            "sha256": digest,
        }
        if not required:
            entry["implicit"] = True
        files.append(entry)

    for index, value in candidates:
        bind(index, value, True)
    for index, value in tokens:
        for candidate in implicit_file_candidates(value):
            bind(index, candidate, False)
    if system == "confluence":
        for index, value, required in confluence_attach_files(
            root, list(files), attach_page_index(argv)
        ):
            bind(index, value, required)
    return files


def literal_at_file_fields(root: Path, argv: list[str]) -> list[str]:
    """Find `gh api -f key=@path` fields that would post the path as literal text.

    `-f/--raw-field` adds a string parameter verbatim; only `-F/--field` expands
    `@path`. A reply drafted to a file and passed with `-f` therefore publishes the
    local path instead of the prose, and the manifest still looks correct because
    `payload_files` hashes the file it can see.
    """
    if not argv or program_name(argv[0]) != "gh" or argv[1:2] != ["api"]:
        return []
    offenders: list[str] = []
    argv = [*argv[:2], *expand_gh_api_args(argv[2:])[0]]
    index = 2
    while index < len(argv):
        value = argv[index]
        field: str | None = None
        if value in {"-f", "--raw-field"} and index + 1 < len(argv):
            field = argv[index + 1]
            index += 1
        elif value.startswith("--raw-field="):
            field = value.split("=", 1)[1]
        if field:
            key, delimiter, text = field.partition("=")
            if (
                delimiter
                and text.startswith("@")
                and len(text) > 1
                and resolve_payload_path(root, text[1:]).is_file()
            ):
                offenders.append(f"{key}=@{text[1:]}")
        index += 1
    return offenders


def verify_payload_files(root: Path, action: dict[str, Any]) -> None:
    surface = prose_surface(action.get("argv") or [])
    findings: list[str] = []
    if surface:
        findings.extend(
            lint_prose_texts(root, prose_inline_texts(action["argv"]), surface)
        )
    base = payload_base(root, action.get("argv") or [])
    for entry in action.get("payload_files", []):
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
            raise ActionError("manifest payload file entry is invalid")
        path = Path(entry["path"])
        if not path.is_absolute():
            path = resolve_payload_path(root, entry["path"])
        argument = entry.get("arg")
        if not isinstance(argument, str):
            raise ActionError(
                "manifest payload file entry has no argument to re-resolve; prepare it again"
            )
        try:
            current = resolve_payload_path(base, argument)
        except (OSError, ValueError) as exc:
            raise ActionError(f"payload path cannot be resolved: {argument}") from exc
        if current != path:
            raise ActionError(
                f"payload path now resolves elsewhere (symlink retargeted?): {argument}"
            )
        if not path.is_file() or sha256_file(path) != entry.get("sha256"):
            raise ActionError(f"payload file changed after approval: {entry['path']}")
        if surface and not entry.get("implicit"):
            findings.extend(prose_gate_findings(root, path, surface))
    if findings:
        detail = "\n  ".join(findings)
        raise ActionError(
            "payload fails the plain-writing gate; fix and re-authorize:\n  "
            + detail
            + "\n  (gates are mechanical defects only; see .claude/docs/plain-writing-guard.md)"
            + "\n  Set NASE_PROSE_LINT=0 only when the flagged text is a quote from someone else."
        )
