from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path
from typing import Any

import nase_config

from .base import ActionError
from .classification import WINDOWS_EXECUTABLE_SUFFIXES, gh_noun_first

# The token and actor lookups run before the mutation, so bounding only the mutation
# would leave `execute` able to hang here instead. These are two short `gh` calls;
# a stall in either is a clean preflight failure, because nothing has mutated yet.
GITHUB_PREFLIGHT_TIMEOUT_SECONDS = 30
# Set for every launched CLI: it stops Windows, including the cmd.exe that runs a `.cmd`
# wrapper, from looking up a bare program name in the current directory.
NO_CWD_SEARCH_ENV_VAR = "NODEFAULTCURRENTDIRECTORYINEXEPATH"
GITHUB_AUTH_ENV_VARS = {
    "GH_REPO",
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "GH_ENTERPRISE_TOKEN",
    "GITHUB_ENTERPRISE_TOKEN",
}


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


GITHUB_ITEM_URL_RE = re.compile(
    r"https://([^/\s]+)/([^/\s]+)/[^/\s]+/(?:pull|issues)/\d+"
)


def github_target_owner(
    argv: list[str],
    explicit_owner: str | None = None,
) -> str:
    if explicit_owner and not re.fullmatch(r"[A-Za-z0-9_.-]+", explicit_owner):
        raise ActionError("explicit GitHub owner is invalid")
    noun_first = gh_noun_first(argv)
    # gh also acts on a PR URL spelled with `http`, a trailing path or a query, which the
    # owner check below does not read. The leading repository forms refuse those.
    if noun_first != argv and any(
        value.lower().startswith(("http:", "https:"))
        and not GITHUB_ITEM_URL_RE.fullmatch(value)
        for value in noun_first[5:]
    ):
        raise ActionError(
            "with -R before the verb, write a PR URL as "
            "https://github.com/OWNER/REPO/pull/NUMBER"
        )
    argv = noun_first

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
            raise ActionError(
                "owned GitHub repository target must be the first argument"
            )
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
            if (match := GITHUB_ITEM_URL_RE.fullmatch(value))
        ]
        if any(host.casefold() != "github.com" for host, _ in resource_targets):
            raise ActionError("GitHub mutations are restricted to github.com")
        resource_owners = {owner.casefold(): owner for _, owner in resource_targets}
        if len(resource_owners) > 1:
            raise ActionError("GitHub mutation URLs must use one target owner")
        if resource_owners:
            resource_owner = next(iter(resource_owners.values()))
            if derived and derived.casefold() != resource_owner.casefold():
                raise ActionError(
                    "GitHub repository selector does not match the PR/issue URL"
                )
            derived = resource_owner
            if not selectors and not explicit_owner:
                raise ActionError(
                    "GitHub PR/issue URL mutation requires --github-owner"
                )

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

    # No fallback to this checkout's origin: `root` is the nase workspace, so a write
    # that names no repository would land on the workspace repo, not the product repo.
    raise ActionError(
        "GitHub write names no repository; add -R owner/repo so it cannot land on "
        "the nase workspace checkout"
    )


def configured_github_account(root: Path, owner: str) -> str:
    config = nase_config.load(root)

    def value(key: str) -> str:
        result = config.get(key)
        if result.status == nase_config.FOUND:
            return result.value
        if result.status == nase_config.UNAVAILABLE:
            raise ActionError("workspace/config.md GitHub account mapping is required")
        if result.reason == "misplaced":
            raise ActionError(
                f"workspace/config.md key {key} must be a top-level key before the first "
                "`## ` heading"
            )
        if result.status == nase_config.AMBIGUOUS:
            raise ActionError(
                f"workspace/config.md key {key} is ambiguous ({result.reason}); "
                "fix the file before a GitHub write"
            )
        return ""

    personal = value("personal_gh_account")
    if personal and owner.casefold() == personal.casefold():
        return personal
    organization = value("github_org")
    work = value("work_gh_account") or value("gh_account")
    if organization and work and owner.casefold() == organization.casefold():
        return work
    raise ActionError("GitHub target owner has no approved account mapping")


def github_subprocess_environment(
    host: str, token: str | None = None
) -> dict[str, str]:
    environment = os.environ.copy()
    for key in GITHUB_AUTH_ENV_VARS:
        environment.pop(key, None)
    environment["GH_HOST"] = host
    environment["GH_PROMPT_DISABLED"] = "1"
    environment[NO_CWD_SEARCH_ENV_VAR] = "1"
    if token is not None:
        environment["GH_TOKEN"] = token
    return environment


def github_account_token(executable: str, host: str, account: str) -> str:
    try:
        completed = subprocess.run(
            [executable, "auth", "token", "--hostname", host, "--user", account],
            check=False,
            capture_output=True,
            env=github_subprocess_environment(host),
            text=True,
            timeout=GITHUB_PREFLIGHT_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as exc:
        # Whatever `gh auth token` wrote before the kill is a fragment of the token, and
        # `from exc` would carry it along the exception chain. `TimeoutExpired.__str__`
        # omits it and nothing here renders a traceback, so this is not a leak today -
        # it is dropped so that staying non-leaky does not depend on that.
        exc.output = None
        exc.stderr = None
        raise ActionError(
            f"loading the approved GitHub account token timed out after "
            f"{GITHUB_PREFLIGHT_TIMEOUT_SECONDS}s; nothing was mutated"
        ) from exc
    if completed.returncode != 0:
        raise ActionError("cannot load the approved GitHub account token")
    token = completed.stdout.strip()
    if not token or any(character.isspace() for character in token):
        raise ActionError("approved GitHub account returned an invalid token")
    return token


def github_token_actor(executable: str, root: Path, host: str, token: str) -> str:
    try:
        completed = subprocess.run(
            [executable, "api", "user", "--jq", ".login"],
            cwd=root,
            check=False,
            capture_output=True,
            env=github_subprocess_environment(host, token),
            text=True,
            timeout=GITHUB_PREFLIGHT_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as exc:
        raise ActionError(
            f"verifying the approved GitHub token actor timed out after "
            f"{GITHUB_PREFLIGHT_TIMEOUT_SECONDS}s; nothing was mutated"
        ) from exc
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
        action["argv"],
        owner if owner_override else None,
    )
    if resolved_owner != owner:
        raise ActionError("GitHub target owner changed after approval")
    if configured_github_account(root, owner) != approved:
        raise ActionError("GitHub account mapping changed after approval")
    return approved, host


def fully_qualified(path: str) -> bool:
    """A Windows path with both a drive (or share) and a root, so the cwd cannot move it."""
    return bool(os.path.splitdrive(path)[0]) and os.path.isabs(path)


def launch_argv(argv: list[str]) -> list[str]:
    """Resolve the program on PATH; Windows ships `az` as `az.cmd`, which a bare name misses.

    On Windows `shutil.which` and `CreateProcess` both try the current directory, so only a
    fully qualified program path or PATH entry is searched here. Nothing found raises
    `FileNotFoundError`, because handing Windows the bare name would search it again.
    """
    program = argv[0]
    if os.name != "nt":
        return [shutil.which(program) or program, *argv[1:]]
    if os.path.splitdrive(program)[0] or os.path.dirname(program):
        bases = [program] if fully_qualified(program) else []
    else:
        entries = os.environ.get("PATH", "").split(os.pathsep)
        bases = [
            os.path.join(entry, program)
            for entry in (entry.strip('"') for entry in entries)
            if fully_qualified(entry)
        ]
    named = program.lower().endswith(WINDOWS_EXECUTABLE_SUFFIXES)
    # Windows' default PATHEXT order, so an `.exe` beats a `.cmd` in the same directory.
    suffixes = ("",) if named else (".com", ".exe", ".bat", ".cmd")
    for base in bases:
        for suffix in suffixes:
            if os.path.isfile(base + suffix):
                return [base + suffix, *argv[1:]]
    raise FileNotFoundError(
        f"no '{program}' file in a fully qualified PATH entry or program path; "
        "the current directory and relative paths are not searched"
    )


def run_github_action(
    root: Path, action: dict[str, Any], timeout: int
) -> subprocess.CompletedProcess:
    """Run with the approved account token without changing shared gh state."""
    approved, host = validated_github_account(root, action)
    argv = launch_argv(action["argv"])
    executable = argv[0]
    token = github_account_token(executable, host, approved)
    if (
        github_token_actor(executable, root, host, token).casefold()
        != approved.casefold()
    ):
        raise ActionError(
            "approved GitHub token actor does not match its account mapping"
        )
    return subprocess.run(
        argv,
        cwd=root,
        env=github_subprocess_environment(host, token),
        check=False,
        timeout=timeout,
    )
