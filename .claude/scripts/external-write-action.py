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
    "add", "apply", "assign", "build", "cancel", "create", "delete", "import",
    "invoke-action", "purge", "remove", "restart", "resume", "set", "start", "stop",
    "swap", "unassign", "update",
}
AZURE_READ_VERBS = {
    "check", "describe", "exists", "get", "list", "query", "show", "status", "view", "what-if",
}
AZURE_GLOBAL_FLAGS = {"--debug", "--help", "-h", "--only-show-errors", "--verbose"}
AZURE_GLOBAL_OPTIONS = {"--output", "-o", "--query", "--subscription"}
AZURE_SAFE_READ_GROUPS = {
    "account", "acr", "ad", "aks", "cloud", "deployment", "devops", "extension",
    "functionapp", "graph", "group", "monitor", "network", "pipelines", "repos",
    "resource", "role", "storage", "webapp",
}
AZURE_SENSITIVE_READ_RE = re.compile(
    r"(?i)(?:^|[\s/_.=?&-])(?:"
    r"app[-_]?settings|connection[-_]?strings?|credentials?|get-access-token|keys|listkeys|"
    r"passwords?|publishing[-_]?profiles?|secrets?|tokens?"
    r")(?:$|[\s/_.=?&-])"
)
GITHUB_AUTH_ENV_VARS = {
    "GH_REPO", "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN",
}
PAYLOAD_FILE_FLAGS = {"--body-file", "--input", "--file"}
SHELL_SEPARATORS = {";", "&&", "&", "|", "||", "(", ")", "\n"}
SHELL_INTERPRETERS = {"bash", "dash", "ksh", "sh", "zsh"}


class ActionError(Exception):
    """A caller supplied an unsafe or invalid action."""


def azure_command_path(words: list[str]) -> list[str]:
    """Return Azure command groups and verb without option values."""
    path: list[str] = []
    skip_value = False
    for word in words:
        if skip_value:
            skip_value = False
            continue
        option = word.split("=", 1)[0]
        if option in AZURE_GLOBAL_OPTIONS:
            skip_value = "=" not in word
            continue
        if word in AZURE_GLOBAL_FLAGS:
            continue
        if word.startswith("-"):
            break
        path.append(word)
    return path


def terraform_subcommand(words: list[str]) -> str | None:
    """Return the Terraform subcommand after global options such as -chdir."""
    return next((word for word in words if not word.startswith("-")), None)


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
            methods = option_values(argv[2:], "--method", "-X")
            has_payload = any(
                option_values(argv[2:], name)
                for name in ("-f", "-F", "--raw-field", "--field", "--input")
            )
            if any(method.upper() in MUTATING_HTTP_METHODS for method in methods) or (
                not methods and has_payload
            ):
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
        command_path = azure_command_path(words)
        if command_path and command_path[0] == "rest":
            method = option_value(argv[2:], "--method")
            if method and method.upper() in MUTATING_HTTP_METHODS:
                return "azure"
        if command_path[:2] == ["pipelines", "run"]:
            return "azure"
        if any(word in AZURE_MUTATING_VERBS for word in command_path):
            return "azure"
        return None

    if executable == "kubectl":
        if words and words[0] in {"annotate", "apply", "cordon", "create", "delete", "drain", "edit", "label", "patch", "replace", "scale", "taint", "uncordon"}:
            return "kubernetes"
        if len(words) >= 2 and words[0] == "rollout" and words[1] in {"pause", "restart", "resume", "undo"}:
            return "kubernetes"
        return None

    if executable == "terraform" and terraform_subcommand(words) in {"apply", "destroy", "import"}:
        return "terraform"

    return None


def option_values(argv: list[str], *names: str) -> list[str]:
    values: list[str] = []
    for index, value in enumerate(argv):
        if value in names and index + 1 < len(argv):
            values.append(argv[index + 1])
            continue
        for name in names:
            if value.startswith(f"{name}="):
                values.append(value.split("=", 1)[1])
            elif len(name) == 2 and value.startswith(name) and len(value) > len(name):
                values.append(value[len(name):].removeprefix("="))
    return values


def option_value(argv: list[str], *names: str) -> str | None:
    values = option_values(argv, *names)
    return values[-1] if values else None


def graphql_read_query(argv: list[str]) -> bool:
    """Recognize direct `gh api graphql` query requests without opening a write path."""
    if len(argv) < 3 or argv[1:3] != ["api", "graphql"]:
        return False
    query_values = [
        value.split("=", 1)[1]
        for value in option_values(
            argv[3:], "-f", "-F", "--raw-field", "--field"
        )
        if value.startswith("query=")
    ]
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


def payload_files(root: Path, argv: list[str], system: str) -> list[dict[str, Any]]:
    executable = Path(argv[0]).name.lower() if argv else ""
    file_flags = set(PAYLOAD_FILE_FLAGS)
    if executable == "gh":
        file_flags.update({"--env-file", "--notes-file"})
    elif executable == "az":
        file_flags.update({"--template-file", "--yaml-path"})
    elif executable == "kubectl":
        file_flags.update({
            "-f", "-k", "--cert", "--filename", "--from-env-file", "--from-file",
            "--key", "--kustomize",
        })
    elif executable == "terraform":
        file_flags.add("-var-file")

    candidates: list[tuple[int, str]] = []
    for index, value in enumerate(argv):
        if value.startswith("@") and len(value) > 1:
            candidates.append((index, value[1:]))
        if value in file_flags and index + 1 < len(argv):
            candidate = argv[index + 1]
            if value == "--from-file":
                candidate = candidate.rsplit("=", 1)[-1]
            candidates.append((index + 1, candidate))
        option, delimiter, option_value_text = value.partition("=")
        if delimiter and (option in file_flags or option_value_text.startswith("@")):
            candidate = option_value_text.removeprefix("@")
            if option == "--from-file":
                candidate = candidate.rsplit("=", 1)[-1]
            candidates.append((index, candidate))

    if executable == "gh" and argv[1:3] == ["gist", "create"]:
        candidates.extend(positional_arguments(
            argv,
            3,
            {"-d", "--desc", "-f", "--filename"},
        ))
    elif executable == "gh" and argv[1:3] == ["release", "create"]:
        positionals = positional_arguments(
            argv,
            3,
            {
                "--discussion-category", "-n", "--notes", "-F", "--notes-file",
                "--notes-start-tag", "--target", "-t", "--title", "-R", "--repo",
            },
        )
        candidates.extend(
            (index, value.split("#", 1)[0])
            for index, value in positionals[1:]
        )

    if system == "terraform" and terraform_subcommand([word.lower() for word in argv[1:]]) == "apply":
        subcommand_index = next(
            index for index, value in enumerate(argv[1:], 1) if not value.startswith("-")
        )
        positionals = positional_arguments(
            argv,
            subcommand_index + 1,
            {"-backup", "-lock-timeout", "-parallelism", "-state", "-state-out", "-var", "-var-file"},
        )
        candidates.extend(positionals[-1:])

    files: list[dict[str, Any]] = []
    seen: set[tuple[int, str]] = set()
    for index, value in candidates:
        key = (index, value)
        if key in seen:
            continue
        seen.add(key)
        if value == "-":
            raise ActionError("stdin payloads cannot be bound to an approved action")
        path = resolve_payload_path(root, value)
        if not path.is_file():
            raise ActionError(f"payload file does not exist: {value}")
        files.append({"arg_index": index, "path": str(path), "sha256": file_sha256(path)})
    return files


def literal_at_file_fields(root: Path, argv: list[str]) -> list[str]:
    """Find `gh api -f key=@path` fields that would post the path as literal text.

    `-f/--raw-field` adds a string parameter verbatim; only `-F/--field` expands
    `@path`. A reply drafted to a file and passed with `-f` therefore publishes the
    local path instead of the prose, and the manifest still looks correct because
    `payload_files` hashes the file it can see.
    """
    if not argv or Path(argv[0]).name.lower() != "gh" or argv[1:2] != ["api"]:
        return []
    offenders: list[str] = []
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
            if delimiter and text.startswith("@") and len(text) > 1:
                if resolve_payload_path(root, text[1:]).is_file():
                    offenders.append(f"{key}=@{text[1:]}")
        index += 1
    return offenders


def github_repo_selector(value: str) -> tuple[str | None, str]:
    match = re.match(r"(?:https?|ssh)://(?:git@)?([^/]+)/([^/]+)/[^/]+", value)
    if match:
        return match.group(1), match.group(2)
    match = re.match(r"git@([^:]+):([^/]+)/[^/]+", value)
    if match:
        return match.group(1), match.group(2)
    parts = value.strip("/").split("/")
    if len(parts) == 2:
        return None, parts[0]
    if len(parts) >= 3:
        return parts[-3], parts[-2]
    raise ActionError("GitHub repository selector must include owner/repository")


def github_target_host(argv: list[str]) -> str:
    hosts = [os.environ["GH_HOST"]] if os.environ.get("GH_HOST") else []
    for index, value in enumerate(argv):
        if value == "--hostname" and index + 1 < len(argv):
            hosts.append(argv[index + 1])
        elif value.startswith("--hostname="):
            hosts.append(value.split("=", 1)[1])
        elif value in {"-R", "--repo"} and index + 1 < len(argv):
            host, _ = github_repo_selector(argv[index + 1])
            if host:
                hosts.append(host)
        elif value.startswith("--repo=") or (value.startswith("-R") and len(value) > 2):
            raw = value.split("=", 1)[1] if "=" in value else value[2:]
            host, _ = github_repo_selector(raw)
            if host:
                hosts.append(host)
    if any(host.casefold() != "github.com" for host in hosts):
        raise ActionError("GitHub mutations are restricted to github.com")
    return "github.com"


def github_target_owner(
    root: Path,
    argv: list[str],
    explicit_owner: str | None = None,
) -> str:
    if explicit_owner and not re.fullmatch(r"[A-Za-z0-9_.-]+", explicit_owner):
        raise ActionError("explicit GitHub owner is invalid")

    selectors: list[str] = []
    for index, value in enumerate(argv):
        if value in {"-R", "--repo"} and index + 1 < len(argv):
            _, owner = github_repo_selector(argv[index + 1])
            selectors.append(owner)
        elif value.startswith("--repo=") or (value.startswith("-R") and len(value) > 2):
            raw = value.split("=", 1)[1] if "=" in value else value[2:]
            _, owner = github_repo_selector(raw)
            selectors.append(owner)
        if value in {"--org", "--owner"} and index + 1 < len(argv):
            selectors.append(argv[index + 1])
        elif value.startswith(("--org=", "--owner=")):
            selectors.append(value.split("=", 1)[1])

    if len(selectors) > 1:
        raise ActionError("GitHub mutation must use exactly one target selector")
    derived = selectors[0] if selectors else None

    if derived is None and len(argv) >= 3 and argv[1:3] == ["api", "graphql"]:
        if not explicit_owner:
            raise ActionError("opaque GitHub GraphQL mutation requires --github-owner")
        return explicit_owner

    if derived is None and len(argv) >= 3 and argv[1] == "api":
        endpoint = argv[2]
        match = re.match(r"^/?(?:repos|orgs|users)/([^/\s]+)(?:/|$)", endpoint)
        if match:
            derived = match.group(1)
        elif not explicit_owner:
            raise ActionError("opaque GitHub API mutation requires --github-owner")
        else:
            return explicit_owner

    if derived is None and len(argv) >= 3 and argv[1] == "repo":
        if not explicit_owner:
            raise ActionError("positional GitHub repo mutation requires --github-owner")
        tail = argv[3:]
        first = tail[0] if tail and not tail[0].startswith("-") else None
        if first and "/" in first:
            host, derived = github_repo_selector(first)
            if host and host.casefold() != "github.com":
                raise ActionError("GitHub mutations are restricted to github.com")
        elif first:
            derived = explicit_owner
        elif any("/" in value and not value.startswith("-") for value in tail):
            raise ActionError("owned GitHub repository target must be the first argument")
        elif argv[2] == "create":
            derived = explicit_owner

    if derived is None and len(argv) >= 3 and argv[1] == "gist":
        if not explicit_owner:
            raise ActionError("positional GitHub gist mutation requires --github-owner")
        derived = explicit_owner

    if len(argv) >= 3 and argv[1] in {"pr", "issue"}:
        resource_targets = [
            (match.group(1), match.group(2))
            for value in argv[3:]
            if (
                match := re.fullmatch(
                    r"https://([^/\s]+)/([^/\s]+)/[^/\s]+/(?:pull|issues)/\d+",
                    value,
                )
            )
        ]
        if any(host.casefold() != "github.com" for host, _ in resource_targets):
            raise ActionError("GitHub mutations are restricted to github.com")
        resource_owners = {owner.casefold(): owner for _, owner in resource_targets}
        if len(resource_owners) > 1:
            raise ActionError("GitHub mutation URLs must use one target owner")
        if resource_owners:
            resource_owner = next(iter(resource_owners.values()))
            if derived and derived.casefold() != resource_owner.casefold():
                raise ActionError("GitHub repository selector does not match the PR/issue URL")
            derived = resource_owner
            if not selectors and not explicit_owner:
                raise ActionError("GitHub PR/issue URL mutation requires --github-owner")

    if (
        derived is None
        and len(argv) >= 3
        and argv[1] in {"secret", "variable"}
        and "--user" in argv[3:]
    ):
        if not explicit_owner:
            raise ActionError("user-scoped GitHub mutation requires --github-owner")
        return explicit_owner

    if derived is not None:
        if explicit_owner and derived.casefold() != explicit_owner.casefold():
            raise ActionError("explicit GitHub owner does not match the command target")
        return derived

    remote = subprocess.run(
        ["git", "-C", str(root), "remote", "get-url", "origin"],
        check=False,
        capture_output=True,
        text=True,
    )
    if remote.returncode == 0:
        try:
            host, owner = github_repo_selector(remote.stdout.strip())
        except ActionError:
            pass
        else:
            if host == "github.com":
                if explicit_owner and owner.casefold() != explicit_owner.casefold():
                    raise ActionError("explicit GitHub owner does not match the current origin")
                return owner
    raise ActionError("cannot map the GitHub target owner to an approved account")


def configured_github_account(root: Path, owner: str) -> str:
    config = root / "workspace" / "config.md"
    try:
        text = config.read_text(encoding="utf-8")
    except OSError as exc:
        raise ActionError("workspace/config.md GitHub account mapping is required") from exc

    def value(key: str) -> str:
        match = re.search(rf"(?m)^{re.escape(key)}:\s*(.*?)\s*$", text)
        return match.group(1).strip().strip("\"'") if match else ""

    personal = value("personal_gh_account")
    if personal and owner.casefold() == personal.casefold():
        return personal
    organization = value("github_org")
    work = value("work_gh_account") or value("gh_account")
    if organization and work and owner.casefold() == organization.casefold():
        return work
    raise ActionError("GitHub target owner has no approved account mapping")


def github_subprocess_environment(host: str, token: str | None = None) -> dict[str, str]:
    environment = os.environ.copy()
    for key in GITHUB_AUTH_ENV_VARS:
        environment.pop(key, None)
    environment["GH_HOST"] = host
    environment["GH_PROMPT_DISABLED"] = "1"
    if token is not None:
        environment["GH_TOKEN"] = token
    return environment


def github_account_token(executable: str, host: str, account: str) -> str:
    completed = subprocess.run(
        [executable, "auth", "token", "--hostname", host, "--user", account],
        check=False,
        capture_output=True,
        env=github_subprocess_environment(host),
        text=True,
    )
    if completed.returncode != 0:
        raise ActionError("cannot load the approved GitHub account token")
    token = completed.stdout.strip()
    if not token or any(character.isspace() for character in token):
        raise ActionError("approved GitHub account returned an invalid token")
    return token


def github_token_actor(executable: str, root: Path, host: str, token: str) -> str:
    completed = subprocess.run(
        [executable, "api", "user", "--jq", ".login"],
        cwd=root,
        check=False,
        capture_output=True,
        env=github_subprocess_environment(host, token),
        text=True,
    )
    actor = completed.stdout.strip()
    if completed.returncode != 0 or not re.fullmatch(r"[A-Za-z0-9_.-]+", actor):
        raise ActionError("cannot verify the approved GitHub token actor")
    return actor


def validated_github_account(root: Path, action: dict[str, Any]) -> tuple[str, str]:
    approved = action.get("github_account")
    owner = action.get("github_owner")
    host = action.get("github_host")
    if not isinstance(approved, str) or not approved:
        raise ActionError("GitHub manifest is missing its approved account")
    if not isinstance(owner, str) or not owner:
        raise ActionError("GitHub manifest is missing its target owner")
    if host != "github.com" or github_target_host(action["argv"]) != host:
        raise ActionError("GitHub target host changed after approval")
    owner_override = action.get("github_owner_override")
    if not isinstance(owner_override, bool):
        raise ActionError("GitHub manifest owner source is invalid")
    resolved_owner = github_target_owner(
        root,
        action["argv"],
        owner if owner_override else None,
    )
    if resolved_owner != owner:
        raise ActionError("GitHub target owner changed after approval")
    if configured_github_account(root, owner) != approved:
        raise ActionError("GitHub account mapping changed after approval")
    return approved, host


def run_github_action(root: Path, action: dict[str, Any]) -> subprocess.CompletedProcess:
    """Run with the approved account token without changing shared gh state."""
    approved, host = validated_github_account(root, action)
    executable = action["argv"][0]
    token = github_account_token(executable, host, approved)
    if github_token_actor(executable, root, host, token).casefold() != approved.casefold():
        raise ActionError("approved GitHub token actor does not match its account mapping")
    return subprocess.run(
        action["argv"],
        cwd=root,
        env=github_subprocess_environment(host, token),
        check=False,
    )


def action_payload(
    root: Path,
    system: str,
    summary: str,
    argv: list[str],
    github_owner: str | None = None,
) -> dict[str, Any]:
    actual_system = mutation_system(argv)
    if actual_system is None:
        raise ActionError("command is not an allowlisted external mutation")
    if system != actual_system:
        raise ActionError(f"system must be {actual_system} for this command")
    if github_owner and system != "github":
        raise ActionError("--github-owner is valid only for GitHub actions")
    offenders = literal_at_file_fields(root, argv)
    if offenders:
        raise ActionError(
            "gh api -f/--raw-field does not read files, so "
            f"{', '.join(offenders)} would post the path as the body text; "
            "build the payload with `jq -n --rawfile body \"$FILE\" '{body:$body}'` "
            "and pass `--input \"$PAYLOAD_FILE\"` instead "
            "(see .claude/docs/github-queries.md -> Reply To A Review Thread)"
        )
    files = payload_files(root, argv, system)
    payload = {"argv": argv, "payload_files": files}
    action = {
        "system": system,
        "summary": summary,
        "argv": argv,
        "payload_files": files,
        "payload_sha256": sha256(payload),
    }
    if system == "github":
        action["github_host"] = github_target_host(argv)
        owner = github_target_owner(root, argv, github_owner)
        action["github_owner"] = owner
        action["github_owner_override"] = github_owner is not None
        action["github_account"] = configured_github_account(root, owner)
    return action


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
    if action.get("system") == "github" and (
        not isinstance(action.get("github_account"), str)
        or not isinstance(action.get("github_owner"), str)
        or not isinstance(action.get("github_owner_override"), bool)
        or action.get("github_host") != "github.com"
    ):
        raise ActionError("GitHub manifest target or account is invalid")
    expected_payload = sha256({"argv": argv, "payload_files": action.get("payload_files", [])})
    if action.get("payload_sha256") != expected_payload:
        raise ActionError("manifest payload hash does not match")
    return resolved, data


PROSE_SURFACES: tuple[tuple[tuple[str, ...], str], ...] = (
    (("pr", "create"), "github-pr-body"),
    (("pr", "edit"), "github-pr-body"),
    (("pr", "comment"), "github-review-reply"),
    (("pr", "review"), "github-review-reply"),
    (("issue", "comment"), "github-review-reply"),
)
PROSE_TEXT_SUFFIXES = {"", ".md", ".txt", ".markdown"}
PROSE_BODY_KEYS = {"body", "body_text"}
# `gh api .../pulls/{n}/reviews` is how a review is actually submitted, so the
# endpoint form has to be recognized too, not just the `gh pr` porcelain.
PROSE_API_ENDPOINTS = re.compile(r"/(pulls|issues)/", re.I)


def prose_surface(argv: list[str]) -> str | None:
    if not argv or Path(argv[0]).name != "gh":
        return None
    words = [token for token in argv[1:] if not token.startswith("-")]
    if not words:
        return None
    if words[0] == "api":
        return "github-review-reply" if any(PROSE_API_ENDPOINTS.search(w) for w in words[1:]) else None
    for prefix, surface in PROSE_SURFACES:
        if tuple(words[: len(prefix)]) == prefix:
            return surface
    return None


def prose_bodies(path: Path) -> list[tuple[str, str]]:
    """Return (label, text) pairs to lint from one payload file.

    A JSON payload is a review envelope, so the prose lives at `body` keys rather
    than in the file as a whole; linting the serialized JSON would flag its own
    punctuation. Returns an empty list for anything unparseable.
    """
    if path.suffix.lower() in PROSE_TEXT_SUFFIXES:
        try:
            return [(path.name, path.read_text(encoding="utf-8"))]
        except OSError:
            return []
    if path.suffix.lower() != ".json":
        return []
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []

    found: list[tuple[str, str]] = []

    def walk(node: Any, trail: str) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                if key in PROSE_BODY_KEYS and isinstance(value, str) and value.strip():
                    found.append((f"{path.name}{trail}.{key}", value))
                else:
                    walk(value, f"{trail}.{key}")
        elif isinstance(node, list):
            for index, value in enumerate(node):
                walk(value, f"{trail}[{index}]")

    walk(payload, "")
    return found


def prose_gate_findings(root: Path, path: Path, surface: str) -> list[str]:
    """Return gate-level prose findings. Never raises: the linter is a quality
    check, not a security control, so a broken linter must not block a write."""
    if os.environ.get("NASE_PROSE_LINT") == "0":
        return []
    lint = root / ".claude" / "scripts" / "prose-lint.py"
    if not lint.is_file():
        return []
    findings: list[str] = []
    for label, text in prose_bodies(path):
        try:
            completed = subprocess.run(
                [sys.executable, str(lint), "--surface", surface, "--file", "-", "--format", "json"],
                input=text,
                capture_output=True,
                text=True,
                timeout=20,
                check=False,
            )
            report = json.loads(completed.stdout)
        except (OSError, ValueError, subprocess.SubprocessError):
            continue
        findings.extend(
            f"{label}:{item['line']} {item['rule']} {item['message']} -> fix: {item['fix']}"
            for item in report.get("findings", [])
            if item.get("kind") == "gate"
        )
    return findings


def verify_payload_files(root: Path, action: dict[str, Any]) -> None:
    surface = prose_surface(action.get("argv") or [])
    findings: list[str] = []
    for entry in action.get("payload_files", []):
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
            raise ActionError("manifest payload file entry is invalid")
        path = Path(entry["path"])
        if not path.is_absolute():
            path = resolve_payload_path(root, entry["path"])
        if not path.is_file() or file_sha256(path) != entry.get("sha256"):
            raise ActionError(f"payload file changed after approval: {entry['path']}")
        if surface:
            findings.extend(prose_gate_findings(root, path, surface))
    if findings:
        detail = "\n  ".join(findings)
        raise ActionError(
            "payload fails the plain-writing gate; fix and re-authorize:\n  "
            + detail
            + "\n  (gates are mechanical defects only; see .claude/docs/plain-writing-guard.md)"
            + "\n  Set NASE_PROSE_LINT=0 only when the flagged text is a quote from someone else."
        )


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(f"{path.suffix}.tmp-{uuid.uuid4().hex}")
    temporary.write_bytes(canonical_json(value) + b"\n")
    os.chmod(temporary, 0o600)
    temporary.replace(path)


def command_segments(command: str) -> list[list[str]]:
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()\n")
        lexer.whitespace = " \t\r"
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


def blank_single_quoted_spans(command: str) -> str:
    """Blank single-quoted spans, which the shell expands and executes as nothing.

    `command_segments` lexes with `shlex` in POSIX mode, so a single-quoted span is already
    collapsed into one argument and can never become an executable. The dynamic-construct scan
    has to agree with that lexer, or a literal backtick in prose - `printf 'see `Foo` rows'` -
    reads as a command substitution and blocks a command that touches nothing external.

    Double-quoted spans are copied verbatim because `$(...)` and backticks still expand inside
    them. An unterminated single quote leaves the remainder untouched, so a malformed command
    keeps failing closed.
    """
    result: list[str] = []
    index = 0
    length = len(command)
    while index < length:
        char = command[index]
        if char == "\\" and index + 1 < length:
            result.append(command[index : index + 2])
            index += 2
            continue
        if char == '"':
            result.append(char)
            index += 1
            while index < length:
                if command[index] == "\\" and index + 1 < length:
                    result.append(command[index : index + 2])
                    index += 2
                    continue
                result.append(command[index])
                index += 1
                if command[index - 1] == '"':
                    break
            continue
        if char == "'":
            end = command.find("'", index + 1)
            if end == -1:
                result.append(command[index:])
                break
            result.append(" " * (end - index + 1))
            index = end + 1
            continue
        result.append(char)
        index += 1
    return "".join(result)


def is_dynamic_shell_command(command: str) -> bool:
    """Detect shell constructs whose executed command cannot be statically bound."""
    return bool(re.search(
        r"`|\$\(|(?:^|[;&|]\s*)\s*(?:alias|eval|source)\b|"
        r"(?:^|[;&|]\s*)\s*(?:"
        r"function\s+[A-Za-z_][A-Za-z0-9_]*(?:\s*\(\s*\))?|"
        r"[A-Za-z_][A-Za-z0-9_]*\s*\(\s*\)"
        r")\s*\{",
        blank_single_quoted_spans(command),
    ))


def command_argvs(command: str, depth: int = 0):
    if re.search(r"(?:\||<)\s*(?:bash|dash|ksh|sh|zsh)\b", command):
        yield ["__unrecognized_shell_command__"]
        return
    for segment in command_segments(command):
        argv = unwrap_shell_segment(segment)
        if not argv:
            continue
        executable = Path(argv[0]).name
        if re.search(r"[$`]", executable) or executable in {"alias", "eval", "function", "source", "."}:
            yield ["__unrecognized_shell_command__"]
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
        if not words:
            return True
        if words[0] == "auth":
            shows_token = any(
                word == "--show-token"
                or word.startswith("--show-token=")
                or (word.startswith("-") and not word.startswith("--") and "t" in word[1:])
                for word in words[2:]
            )
            return len(words) >= 2 and words[1] == "status" and not shows_token
        if words[0] == "api":
            if graphql_read_query(argv):
                return True
            methods = option_values(argv[2:], "--method", "-X")
            has_payload = any(
                option_values(argv[2:], name)
                for name in ("-f", "-F", "--raw-field", "--field", "--input")
            )
            return not has_payload and all(
                method.upper() in {"GET", "HEAD"} for method in methods
            )
        return len(words) >= 2 and words[1] in {
            "checks", "diff", "list", "status", "view", "watch",
        }
    if executable == "az":
        command_path = azure_command_path(words)
        if not words:
            return True
        if not command_path:
            return all(word in AZURE_GLOBAL_FLAGS for word in words)
        if AZURE_SENSITIVE_READ_RE.search(" ".join(words)):
            return False
        if command_path[0] == "version":
            return True
        if command_path[0] == "rest":
            method = option_value(argv[2:], "--method")
            return method is not None and method.upper() in {"GET", "HEAD"}
        return command_path[0] in AZURE_SAFE_READ_GROUPS and any(
            word in AZURE_READ_VERBS for word in command_path[1:]
        )
    if executable == "kubectl":
        if not words or any(
            re.fullmatch(r"secrets?(?:\.[^./,]+)*\.?(?:/.*)?", resource)
            for word in words[1:]
            for resource in word.split(",")
        ) or any(
            word == "--raw" or word.startswith("--raw=") for word in words[1:]
        ) or (
            words[0] == "get"
            and any(
                word in {"-f", "-k", "--filename", "--kustomize"}
                or word.startswith(("--filename=", "--kustomize="))
                for word in words[1:]
            )
        ):
            return False
        if words[0] == "config":
            return len(words) >= 2 and words[1] in {"current-context", "get-contexts"}
        return words[0] in {
            "api-resources", "cluster-info", "describe", "get", "logs", "top", "version",
        }
    if executable == "terraform":
        return terraform_subcommand(words) in {
            "fmt", "graph", "plan", "providers", "validate", "version",
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
    action = action_payload(args.root, args.system, args.summary, argv, args.github_owner)
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
        if action["system"] == "github":
            completed = run_github_action(args.root, action)
        else:
            completed = subprocess.run(action["argv"], cwd=args.root, check=False)
        return completed.returncode
    finally:
        if token_file is not None:
            token_file.unlink(missing_ok=True)


def cmd_guard(args: argparse.Namespace) -> int:
    if args.command and (
        not command_segments(args.command) or is_dynamic_shell_command(args.command)
    ):
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
    prepare.add_argument("--github-owner")
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
