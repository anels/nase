#!/usr/bin/env python3
"""Prepare, authorize, and execute one payload-bound external CLI mutation."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, NamedTuple

sys.path.insert(0, str(Path(__file__).resolve().parent))

import shell_scan
from nase_fs import lock_exclusive, sha256_bytes, sha256_file
from nase_json import canonical_bytes
from nase_time import parse_ts, utc_now_iso
from workspace_lock import pid_alive

TOKEN_TTL_SECONDS = 300
# Deliberately generous: one `terraform apply` or `az deployment create` can
# legitimately run for many minutes. The bound exists so a stalled network call
# cannot hang the session forever, not to fail a slow-but-working write early.
EXECUTE_TIMEOUT_SECONDS = 900
# Distinct from every other exit code because the outcome is unknown, not failed:
# the CLI may have applied the mutation before the bound expired.
EXECUTE_TIMEOUT_EXIT = 11
EXECUTE_LAUNCH_EXIT = 12
# The token and actor lookups run before the mutation, so bounding only the mutation
# would leave `execute` able to hang here instead. These are two short `gh` calls;
# a stall in either is a clean preflight failure, because nothing has mutated yet.
GITHUB_PREFLIGHT_TIMEOUT_SECONDS = 30
# Set for every launched CLI: it stops Windows, including the cmd.exe that runs a `.cmd`
# wrapper, from looking up a bare program name in the current directory.
NO_CWD_SEARCH_ENV_VAR = "NODEFAULTCURRENTDIRECTORYINEXEPATH"
MANIFEST_VERSION = 1
MUTATING_HTTP_METHODS = {"POST", "PUT", "PATCH", "DELETE", "PURGE"}
READ_HTTP_METHODS = {"GET", "HEAD"}
AZURE_MUTATING_VERBS = {
    "add",
    "apply",
    "assign",
    "build",
    "cancel",
    "create",
    "delete",
    "import",
    "invoke-action",
    "purge",
    "remove",
    "restart",
    "resume",
    "set",
    "start",
    "stop",
    "swap",
    "unassign",
    "update",
}
# These only change which subscription or cloud the local CLI targets; nothing remote changes.
AZURE_LOCAL_CONFIG_COMMANDS = (["account", "set"], ["cloud", "set"])
AZURE_READ_VERBS = {
    "check",
    "describe",
    "exists",
    "get",
    "list",
    "query",
    "show",
    "status",
    "view",
    "what-if",
}
AZURE_GLOBAL_FLAGS = {"--debug", "--help", "-h", "--only-show-errors", "--verbose"}
AZURE_GLOBAL_OPTIONS = {"--output", "-o", "--query", "--subscription"}
AZURE_SAFE_READ_GROUPS = {
    "account",
    "acr",
    "ad",
    "advisor",
    "aks",
    "apim",
    "appconfig",
    "backup",
    "cloud",
    "cdn",
    "consumption",
    "cosmosdb",
    "costmanagement",
    "deployment",
    "devops",
    "disk",
    "dns",
    "eventhubs",
    "extension",
    "functionapp",
    "graph",
    "group",
    "image",
    "keyvault",
    "lock",
    "monitor",
    "mysql",
    "network",
    "pipelines",
    "policy",
    "postgres",
    "privatedns",
    "provider",
    "redis",
    "repos",
    "resource",
    "role",
    "servicebus",
    "snapshot",
    "sql",
    "storage",
    "tag",
    "vm",
    "vmss",
    "webapp",
}
AZURE_NO_COMMAND_FLAGS = AZURE_GLOBAL_FLAGS | {"--version"}
AZURE_SENSITIVE_READ_RE = re.compile(
    r"(?i)(?:^|[\s/_.=?&-])(?:"
    r"app[-_]?settings|connection[-_]?strings?|credentials?|get-access-token|keys|listkeys|"
    r"passwords?|publishing[-_]?profiles?|secrets?|tokens?"
    r")(?:$|[\s/_.=?&-])"
)
AZURE_GLOBAL_NAMES = AZURE_GLOBAL_OPTIONS | AZURE_GLOBAL_FLAGS
# Per command: (method flags, every flag a read may carry). A flag outside the set, or an
# abbreviation of one, is not provably a read, so the call needs a manifest.
AZURE_HTTP_FLAGS = {
    ("rest",): (
        ("--method", "-m"),
        {"--method", "-m", "--url", "--uri", "--resource", "--uri-parameters"}
        | {"--skip-authorization-header"}
        | AZURE_GLOBAL_NAMES,
    ),
    ("devops", "invoke"): (
        ("--http-method",),
        {
            "--http-method",
            "--accept-media-type",
            "--api-version",
            "--area",
            "--detect",
            "--org",
            "--organization",
            "--query-parameters",
            "--resource",
            "--route-parameters",
        }
        | AZURE_GLOBAL_NAMES,
    ),
}
# `secret list` returns names only, so it is the one secret-path read the guard allows.
AZURE_SECRET_NAME_LISTING = ["keyvault", "secret", "list"]
AZURE_DATAFACTORY_RUN_RESOURCES = {"pipeline-run", "trigger-run"}
GITHUB_AUTH_ENV_VARS = {
    "GH_REPO",
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "GH_ENTERPRISE_TOKEN",
    "GITHUB_ENTERPRISE_TOKEN",
}
# Env vars that redirect a non-GitHub CLI at a specific target. They are kept (they are
# the approved target, not credentials), but each one is announced for the system that
# actually reads it, so an `az` write never claims KUBECONFIG chose its target.
TARGET_SELECTOR_ENV_VARS = {
    "azure": ("AZURE_CONFIG_DIR",),
    "kubernetes": ("KUBECONFIG",),
    "terraform": ("TF_CLI_CONFIG_FILE", "TF_DATA_DIR"),
}
PAYLOAD_FILE_FLAGS = {"--body-file", "--input", "--file"}
KUBECTL_MUTATING_VERBS = {
    "annotate",
    "apply",
    "cordon",
    "cp",
    "create",
    "delete",
    "drain",
    "edit",
    "exec",
    "label",
    "patch",
    "port-forward",
    "replace",
    "run",
    "scale",
    "taint",
    "uncordon",
}
KUBECTL_GLOBAL_VALUE_OPTIONS = (
    shell_scan.KUBECTL_SHARED_VALUE_OPTIONS | shell_scan.KUBECTL_GUARD_ONLY_VALUE_OPTIONS
)
KUBECTL_READ_VERBS = {
    "api-resources",
    "cluster-info",
    "describe",
    "events",
    "explain",
    "get",
    "logs",
    "top",
    "version",
}
KUBECTL_GLOBAL_FLAGS = {
    "--disable-compression",
    "--help",
    "--insecure-skip-tls-verify",
    "--match-server-version",
    "--warnings-as-errors",
    "-h",
}
TERRAFORM_MUTATING_SUBCOMMANDS = {"apply", "destroy", "import", "refresh", "taint"}
TERRAFORM_READ_SUBCOMMANDS = {"graph", "plan", "providers", "validate", "version"}
# `terraform init` only touches the local working directory unless it moves state
# between backends, which writes the remote state.
TERRAFORM_STATE_MOVING_INIT_FLAGS = {"force-copy", "migrate-state"}
TERRAFORM_HELP_FLAGS = {"-help", "-version", "--help", "--version"}
# Global options Terraform accepts before the subcommand. `-chdir` takes a
# value (separate or `=` form); the rest take none.
TERRAFORM_GLOBAL_VALUE_OPTIONS = {"-chdir", "--chdir"}
TERRAFORM_GLOBAL_FLAGS = {"-help", "--help", "-version", "--version"}
PYTHON_VALUE_OPTIONS = {"-W", "-X", "--check-hash-based-pycs"}
CONFLUENCE_PUBLISH_SCRIPT = "confluence-publish.py"
# `attach` uploads or overwrites attachment bytes on any page with the stored Atlassian
# token. The other subcommands only read and write local files or the local ledger.
CONFLUENCE_WRITE_SUBCOMMANDS = {"attach"}
GUARDED_EXECUTABLES = ("gh", "az", "kubectl", "terraform")
# A path prefix still names the same binary, so `/usr/bin/gh` counts; a longer word that
# merely starts with one does not, so `github`, `azure`, and `terraform-docs` do not.
WINDOWS_EXECUTABLE_SUFFIXES = (".exe", ".cmd", ".bat", ".com")
GUARDED_MENTION_RE = re.compile(
    r"(?<![\w-])(?:"
    + "|".join(GUARDED_EXECUTABLES)
    + r")(?:\.(?:exe|cmd|bat|com))?(?![\w.-])",
    re.IGNORECASE,
)


def program_name(word: str) -> str:
    """Lowercase basename of a program word, so a Windows path to `gh.exe` reads as `gh`."""
    name = word.replace("\\", "/").rsplit("/", 1)[-1].lower()
    for suffix in WINDOWS_EXECUTABLE_SUFFIXES:
        if name.endswith(suffix):
            return name[: -len(suffix)]
    return name


# `gh` command table. Every command lands in one of three classes, and anything the table
# does not name is unknown, which the guard fails closed on.
#   read   - fetches or prints, never changes GitHub or the checkout.
#   local  - changes only the local checkout or prints local help, never GitHub.
#   mutate - changes GitHub state. The object set and the verb set are separate
#            contracts: a new `gh` noun and a new mutating verb arrive independently.
GH_READ_VERBS = frozenset({"checks", "diff", "list", "status", "view", "watch"})
GH_LOCAL_COMMANDS = frozenset(
    {
        ("pr", "checkout"),
        ("repo", "clone"),
        ("gist", "clone"),
        ("release", "download"),
        ("run", "download"),
    }
)
GH_LOCAL_FLAGS = frozenset({"--version", "--help", "-h"})
GH_MUTATING_OBJECTS = frozenset(
    {
        "pr",
        "issue",
        "release",
        "repo",
        "gist",
        "label",
        "variable",
        "secret",
        "cache",
    }
)
GH_SEARCH_KINDS = frozenset({"code", "commits", "issues", "prs", "repos"})
# Writes whose noun or verb is not in the two sets above and below.
GH_MUTATING_COMMANDS = frozenset(
    {("workflow", "run"), ("run", "rerun"), ("pr", "update-branch")}
)
GH_MUTATING_VERBS = frozenset(
    {
        "create",
        "edit",
        "close",
        "reopen",
        "ready",
        "review",
        "merge",
        "delete",
        "comment",
        "set",
    }
)


def gh_noun_first(argv: list[str]) -> list[str]:
    """Return `gh -R o/r pr merge` and `gh pr --repo o/r merge` as `gh pr merge -R o/r`.

    gh takes the repository option before the verb, where a check that reads the noun and
    verb by position would miss it. Every other argv comes back unchanged.
    """
    head = argv[1:5]
    if len(head) < 4 or program_name(argv[0]) != "gh":
        return argv
    for at in (0, 1):
        if head[at] in {"-R", "--repo"}:
            noun, verb = head[:at] + head[at + 2 :]
            if (noun.lower(), verb.lower()) == ("pr", "merge"):
                return [argv[0], noun, verb, head[at], head[at + 1], *argv[5:]]
    return argv


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


def azure_http_flags(
    command_path: list[str],
) -> tuple[tuple[str, ...], set[str]] | None:
    """Return (method flags, other read flags) for `az rest` and `az devops invoke`."""
    for prefix, flags in AZURE_HTTP_FLAGS.items():
        if tuple(command_path[: len(prefix)]) == prefix:
            return flags
    return None


def azure_words_without_query_text(words: list[str]) -> list[str]:
    """Drop the value of `--analytics-query` so log text that mentions a token is not a secret read."""
    kept: list[str] = []
    skip_value = False
    for word in words:
        if skip_value:
            skip_value = False
        elif word == "--analytics-query":
            skip_value = True
        elif not word.startswith("--analytics-query="):
            kept.append(word)
    return kept


def azure_secret_listing_options(words: list[str]) -> list[str]:
    """Drop the command path and the vault name, which are not secret-bearing options."""
    options = list(words)
    for word in AZURE_SECRET_NAME_LISTING:
        options.remove(word)
    kept: list[str] = []
    skip_value = False
    for word in options:
        if skip_value:
            skip_value = False
        elif word == "--vault-name":
            skip_value = True
        elif not word.startswith("--vault-name="):
            kept.append(word)
    return kept


def azure_http_read_only(
    argv: list[str], flags: tuple[tuple[str, ...], set[str]]
) -> bool:
    """`az rest` and `az devops invoke` send GET unless a method flag says otherwise."""
    method_flags, allowed = flags
    names = {token.split("=", 1)[0] for token in argv[1:] if token.startswith("-")}
    if not names <= allowed:
        return False
    methods = option_values(argv[1:], *method_flags)
    if names & set(method_flags) and not methods:
        return False
    return all(method.upper() in READ_HTTP_METHODS for method in methods)


def azure_datafactory_read_only(command_path: list[str]) -> bool:
    """Only run history is readable, because definitions can hold credentials."""
    return (
        len(command_path) > 2
        and command_path[1] in AZURE_DATAFACTORY_RUN_RESOURCES
        and any(
            word in AZURE_READ_VERBS or word.startswith("query-by-")
            for word in command_path[2:]
        )
    )


def terraform_command(words: list[str]) -> list[str] | None:
    """Return the words from the Terraform subcommand on, or None when unknown.

    Value-taking global options are skipped with their value, so
    `terraform -chdir plan apply` reads as `apply`, not `plan`. Returns None
    for a global option this guard does not know, because the next word could
    then be that option's value and not the subcommand; callers fail closed
    on None rather than guess.
    """
    index = 0
    while index < len(words):
        word = words[index]
        if word == "--":
            return words[index + 1 :]
        if not word.startswith("-"):
            return words[index:]
        name = word.split("=", 1)[0]
        if name in TERRAFORM_GLOBAL_VALUE_OPTIONS:
            index += 1 if "=" in word else 2
        elif name in TERRAFORM_GLOBAL_FLAGS:
            index += 1
        else:
            return None
    return []


def terraform_chdir(argv: list[str]) -> str | None:
    """Return the `-chdir` directory, which Terraform resolves every other path against."""
    index = 1
    while index < len(argv):
        word = argv[index]
        if not word.startswith("-") or word == "--":
            return None
        name, delimiter, value = word.partition("=")
        if name.lower() in TERRAFORM_GLOBAL_VALUE_OPTIONS:
            if delimiter:
                return value
            return argv[index + 1] if index + 1 < len(argv) else None
        index += 1
    return None


def terraform_subcommand(words: list[str]) -> str | None:
    """Return the Terraform subcommand after global options such as -chdir."""
    command = terraform_command(words)
    return command[0] if command else None


def terraform_flag_names(words: list[str]) -> set[str]:
    """Names of the flags in `words`; Go accepts one or two dashes and `=value`."""
    return {
        word.lstrip("-").split("=", 1)[0] for word in words if word.startswith("-")
    }


def kubectl_command(
    words: list[str], accept_output: bool = False
) -> list[str] | None:
    """Return the words from the kubectl verb on, skipping global options.

    `kubectl -n prod get pods` and `kubectl --context=prod delete pod x` carry the
    verb after the target flags. Returns None for a global option this guard does not
    know, because the next word could then be that option's value and not the verb;
    callers fail closed on None rather than guess. `accept_output` also skips
    `-o`/`--output`, which only the search for a mutating verb may do.
    """
    value_options = KUBECTL_GLOBAL_VALUE_OPTIONS
    attached = r"-[nsv].+"
    if accept_output:
        value_options = value_options | shell_scan.KUBECTL_OUTPUT_OPTIONS
        attached = r"-[nosv].+"
    index = 0
    while index < len(words):
        word = words[index]
        if not word.startswith("-"):
            return words[index:]
        name = word.split("=", 1)[0]
        if name in value_options:
            index += 1 if "=" in word else 2
        elif name in KUBECTL_GLOBAL_FLAGS or re.fullmatch(attached, word):
            index += 1
        else:
            return None
    return []


def confluence_publish_subcommand(argv: list[str]) -> str | None:
    """Return the `confluence-publish.py` subcommand this argv runs, or None."""
    if not argv:
        return None
    executable = program_name(argv[0])
    if executable == CONFLUENCE_PUBLISH_SCRIPT:
        rest = argv[1:]
    elif re.fullmatch(r"python[0-9.]*", executable):
        # The script is the first word that is not an interpreter option, so the
        # helper's own `prepare ... -- python3 confluence-publish.py attach` command,
        # which only names the script as data, is not read as running it.
        script = None
        skip_value = False
        for index, word in enumerate(argv[1:], 1):
            if skip_value:
                skip_value = False
            elif word in PYTHON_VALUE_OPTIONS:
                skip_value = True
            elif not word.startswith("-"):
                script = index
                break
        if script is None or Path(argv[script]).name.lower() != CONFLUENCE_PUBLISH_SCRIPT:
            return None
        rest = argv[script + 1 :]
    else:
        return None
    return next((word.lower() for word in rest if not word.startswith("-")), None)


def sha256(value: Any) -> str:
    return sha256_bytes(canonical_bytes(value, ensure_ascii=True))


def parse_timestamp(value: str) -> datetime:
    parsed = parse_ts(value)
    if parsed is None:
        raise ActionError("token created_at is invalid")
    return parsed


GH_API_BOOL_SHORT_FLAGS = set("ih")
GH_API_VALUE_SHORT_FLAGS = set("FHXfpqt")
GH_API_VALUE_LONG_FLAGS = {
    "--cache",
    "--field",
    "--header",
    "--hostname",
    "--input",
    "--jq",
    "--method",
    "--preview",
    "--raw-field",
    "--template",
}


def expand_short_cluster(arg: str) -> tuple[list[str], bool, bool]:
    """Split one `-abc` cluster into tokens: (tokens, understood, wants_next_value)."""
    tokens: list[str] = []
    for position in range(1, len(arg)):
        flag = arg[position]
        if flag in GH_API_BOOL_SHORT_FLAGS:
            tokens.append(f"-{flag}")
        elif flag in GH_API_VALUE_SHORT_FLAGS:
            tokens.append(f"-{flag}")
            attached = arg[position + 1 :].removeprefix("=")
            if attached:
                tokens.append(attached)
            return tokens, True, not attached
        else:
            tokens.append(arg[position:])
            return tokens, False, False
    return tokens, True, False


def expand_gh_api_tokens(args: list[str]) -> tuple[list[tuple[int, str]], bool]:
    """Split clustered short flags in `gh api` arguments, as gh's flag parser does.

    `-iXDELETE` is `-i -X DELETE` and `-ifbody=x` is `-i -f body=x`. A flag that
    takes a value consumes the rest of its cluster, or the next argument when the
    cluster ends there. Each token comes back with the index of the argument it came
    from. Returns False when a cluster holds a flag this guard cannot interpret, so
    callers can fail closed on it.
    """
    expanded: list[tuple[int, str]] = []
    understood = True
    skip_value = False
    for index, arg in enumerate(args):
        if skip_value:
            expanded.append((index, arg))
            skip_value = False
        elif arg == "--":
            expanded.extend(
                (index + offset, rest) for offset, rest in enumerate(args[index:])
            )
            break
        elif arg in GH_API_VALUE_LONG_FLAGS:
            expanded.append((index, arg))
            skip_value = True
        elif re.fullmatch(r"-[^-=].+", arg):
            tokens, ok, skip_value = expand_short_cluster(arg)
            expanded.extend((index, token) for token in tokens)
            understood = understood and ok
        else:
            expanded.append((index, arg))
    return expanded, understood


def expand_gh_api_args(args: list[str]) -> tuple[list[str], bool]:
    tokens, understood = expand_gh_api_tokens(args)
    return [token for _, token in tokens], understood


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
                values.append(value[len(name) :].removeprefix("="))
    return values


GRAPHQL_FILE_BASE: list[Path] = []
GRAPHQL_FILE_MAX_BYTES = 1_000_000


def read_graphql_query_file(raw_path: str) -> str | None:
    """Return the text of a `query=@file` operation, or None when it cannot be trusted.

    Only a regular file that resolves, symlinks followed, to a place under the guard's
    working directory counts. No base directory, an empty or `-` path, a `..` part, a
    rooted path with no drive on Windows (Git Bash passes `gh` another path), a missing
    or oversized file, and undecodable bytes all return None, which keeps the command a
    write.
    """
    if not GRAPHQL_FILE_BASE or not raw_path or raw_path == "-":
        return None
    base = GRAPHQL_FILE_BASE[0]
    path = Path(raw_path)
    if ".." in path.parts or (path.anchor and not path.is_absolute()):
        return None
    try:
        root = base.resolve(strict=True)
        resolved = (path if path.is_absolute() else root / path).resolve(strict=True)
        resolved.relative_to(root)
        if not resolved.is_file() or resolved.stat().st_size > GRAPHQL_FILE_MAX_BYTES:
            return None
        return resolved.read_text(encoding="utf-8")
    except (OSError, ValueError):
        return None


# Fields of a `query=@file` read that Bash and PowerShell both pass to `gh` unchanged:
# ASCII with nothing to quote, expand, or split. Git Bash rewrites words such as `x=/c/y`,
# `_/c/x`, `+/x`, and `-I/x`, so a variable value is an integer or opens with a letter or
# digit and holds no `:`, `@`, or inner `=`. A path opens with a letter, digit, dot, or
# slash and has no leading `//` or trailing `/`.
GRAPHQL_QUERY_FILE_FIELD_RE = re.compile(
    r"query=@(?=[A-Za-z0-9./])(?!//)"
    r"(?:[A-Za-z]:/|/)?(?:[A-Za-z0-9_.+/-]|(?<=\w)~)+(?<!/)"
)
GRAPHQL_VARIABLE_FIELD_RE = re.compile(
    r"[A-Za-z_]\w*=(?:-?[0-9]+|[A-Za-z0-9][A-Za-z0-9_./+-]*={0,2})", re.ASCII
)


def graphql_file_words(argv: list[str]) -> bool:
    """True for `gh api graphql` followed only by plain `-f` or `-F` fields.

    Any other word could send the file to another host, change the method, or read a
    second file.
    """
    flags, fields = argv[3::2], argv[4::2]
    return (
        argv[:3] == ["gh", "api", "graphql"]
        and len(flags) == len(fields)
        and all(flag in ("-f", "-F") for flag in flags)
        and all(
            GRAPHQL_QUERY_FILE_FIELD_RE.fullmatch(field)
            or GRAPHQL_VARIABLE_FIELD_RE.fullmatch(field)
            for field in fields
        )
    )


def graphql_read_query(argv: list[str]) -> bool:
    """Recognize direct `gh api graphql` query requests without opening a write path."""
    if len(argv) < 3 or argv[1:3] != ["api", "graphql"]:
        return False
    api_args, understood = expand_gh_api_args(argv[3:])
    if not understood:
        return False
    if any(arg == "--input" or arg.startswith("--input=") for arg in api_args):
        return False
    query_values = [
        value.split("=", 1)[1]
        for value in option_values(api_args, "-f", "-F", "--raw-field", "--field")
        if value.startswith("query=")
    ]
    if len(query_values) != 1:
        return False
    query = query_values[0]
    if query.startswith("@"):
        loaded = read_graphql_query_file(query[1:])
        if loaded is None:
            return False
        query = loaded
    query = query.lstrip()
    return not re.search(r"\bmutation\b", query, re.IGNORECASE) and (
        query.startswith(("query", "{", "fragment"))
    )


class Classification(NamedTuple):
    """What one argv would do, as both the guard and `prepare` act on it.

    `read` and `local` may run unguarded. `mutation` needs a payload-bound manifest for
    `system`. `unrecognized` is blocked, and `prepare` refuses it.
    """

    kind: str
    system: str | None
    reason: str


def _read(reason: str) -> Classification:
    return Classification("read", None, reason)


def _local(reason: str) -> Classification:
    return Classification("local", None, reason)


def _mutation(system: str, reason: str) -> Classification:
    return Classification("mutation", system, reason)


def _unrecognized(reason: str) -> Classification:
    return Classification("unrecognized", None, reason)


# A word that bash and PowerShell both pass on as written. It has no quote, variable, glob,
# comma, redirect or space, and no leading `@` (PowerShell splatting), `=` (zsh) or `//`
# (a network share: opening one contacts a host the command names).
PLAIN_WORD_RE = re.compile(r"(?!//)[A-Za-z0-9_./:-][A-Za-z0-9_./:@-]*")


def plain_words(argv: list[str]) -> bool:
    """True for a bare guarded CLI name followed by plain words."""
    return argv[0] in GUARDED_EXECUTABLES and all(
        PLAIN_WORD_RE.fullmatch(word) for word in argv
    )


# These rules allow a command only because of its exact words, so the guard also requires
# the command text to be those words and nothing else (`runs_exactly`).
GH_API_LISTED_READ = _read("gh api OPTIONS, or GET with a request body")
KUBECTL_CONTEXT_SWITCH = _local("switches the local kubeconfig context")
TERRAFORM_WORKSPACE_SWITCH = _local("switches the local workspace")
EXACT_WORD_RULES = frozenset(
    {GH_API_LISTED_READ, KUBECTL_CONTEXT_SWITCH, TERRAFORM_WORKSPACE_SWITCH}
)


def gh_api_listed_read(argv: list[str]) -> bool:
    """Exactly `gh api E -X OPTIONS` or `gh api E -X GET --input FILE`, never GraphQL.

    `E` is a path: a full URL could send FILE to any host. Any other word, order or
    spelling falls through to the general `gh api` rules.
    """
    if len(argv) < 5 or argv[1] != "api" or argv[3] != "-X" or not plain_words(argv):
        return False
    endpoint = argv[2].lower()
    if endpoint.startswith("-") or "graphql" in endpoint or "://" in endpoint:
        return False
    if argv[4:] == ["OPTIONS"]:
        return True
    return (
        len(argv) == 7
        and argv[4:6] == ["GET", "--input"]
        and not argv[6].startswith("-")
    )


def classify_gh_api(argv: list[str]) -> Classification:
    if graphql_read_query(argv):
        return _read("GraphQL query")
    api_args, understood = expand_gh_api_args(argv[2:])
    if not understood:
        return _mutation("github", "gh api flags this guard cannot read")
    methods = [method.upper() for method in option_values(api_args, "--method", "-X")]
    has_input = bool(option_values(api_args, "--input"))
    has_fields = any(
        option_values(api_args, name)
        for name in ("-f", "-F", "--raw-field", "--field")
    )
    if any(method in MUTATING_HTTP_METHODS for method in methods) or (
        not methods and (has_input or has_fields)
    ):
        return _mutation("github", "gh api request that writes")
    if gh_api_listed_read(argv):
        return GH_API_LISTED_READ
    # With an explicit GET or HEAD, gh sends fields as query parameters.
    if not has_input and all(method in READ_HTTP_METHODS for method in methods):
        return _read("gh api GET or HEAD")
    return _unrecognized("gh api request that is not a known read")


def classify_gh(argv: list[str], words: list[str]) -> Classification:
    """Classify `gh`; anything the tables do not name is unrecognized.

    The mutating objects, mutating verbs and single commands are separate contracts: a
    new `gh` noun and a new mutating verb arrive independently.
    """
    if not words:
        return _local("bare gh prints help")
    if words[0] == "api":
        return classify_gh_api(argv)
    if (
        gh_noun_first(argv) != argv
        or tuple(words[:2]) in GH_MUTATING_COMMANDS
        or (
            len(words) >= 2
            and words[0] in GH_MUTATING_OBJECTS
            and words[1] in GH_MUTATING_VERBS
        )
    ):
        return _mutation("github", "gh command that changes GitHub")
    if words[0] == "auth":
        if words[1:2] == ["switch"]:
            return _local("changes the active local account")
        shows_token = any(
            word == "--show-token"
            or word.startswith("--show-token=")
            or (word.startswith("-") and not word.startswith("--") and "t" in word[1:])
            for word in words[2:]
        )
        if words[1:2] == ["status"] and not shows_token:
            return _read("auth status without the token")
        return _unrecognized("gh auth command that can print or change credentials")
    if words[0] == "search":
        if len(words) >= 2 and words[1] in GH_SEARCH_KINDS:
            return _read("gh search")
        return _unrecognized("unknown gh search kind")
    if words[0] == "help" or (len(words) == 1 and words[0] in GH_LOCAL_FLAGS):
        return _local("gh help or version")
    if words[0] == "status":
        return _read("gh status")
    if tuple(words[:2]) in GH_LOCAL_COMMANDS:
        return _local("changes only the local checkout")
    if len(words) >= 2 and words[1] in GH_READ_VERBS:
        return _read("gh read verb")
    return _unrecognized("gh command the tables do not name")


def classify_az(argv: list[str], words: list[str]) -> Classification:
    if not words:
        return _local("bare az prints help")
    command_path = azure_command_path(words)
    http_flags = azure_http_flags(command_path)
    if (http_flags and not azure_http_read_only(argv, http_flags)) or (
        command_path[:2] == ["pipelines", "run"]
    ):
        return _mutation("azure", "az request or pipeline run that writes")
    if command_path not in AZURE_LOCAL_CONFIG_COMMANDS:
        # The last verb decides: `pipelines build list` is a read although `build` alone
        # queues one, and `config set key=value` still ends on `set`.
        verbs = [
            word
            for word in command_path
            if word in AZURE_MUTATING_VERBS or word in AZURE_READ_VERBS
        ]
        if verbs and verbs[-1] in AZURE_MUTATING_VERBS:
            return _mutation("azure", "az mutating verb")
    if not command_path:
        if all(word in AZURE_NO_COMMAND_FLAGS for word in words):
            return _local("az help or version flags")
        return _unrecognized("az flags with no command")
    if command_path[0] == "datafactory" and not azure_datafactory_read_only(
        command_path
    ):
        return _unrecognized("Data Factory definitions can hold credentials")
    if command_path == AZURE_SECRET_NAME_LISTING:
        options = azure_secret_listing_options(words)
        if AZURE_SENSITIVE_READ_RE.search(" ".join(options)):
            return _unrecognized("secret listing with a secret-bearing option")
        return _read("secret names only")
    if AZURE_SENSITIVE_READ_RE.search(" ".join(azure_words_without_query_text(words))):
        return _unrecognized("az command that can print a secret")
    if command_path[0] == "version":
        return _read("az version")
    if command_path in AZURE_LOCAL_CONFIG_COMMANDS:
        return _local("retargets the local CLI")
    if http_flags:
        # A writing request returned above.
        return _read("az GET or HEAD request")
    if command_path[0] == "datafactory":
        return _read("Data Factory run history")
    if command_path[0] in AZURE_SAFE_READ_GROUPS and any(
        word in AZURE_READ_VERBS for word in command_path[1:]
    ):
        return _read("az read verb")
    return _unrecognized("az command that is not a known read")


def classify_kubectl(argv: list[str], words: list[str]) -> Classification:
    # `-o`/`--output` before the verb is accepted only to find a mutation.
    command = kubectl_command(words, accept_output=True) or []
    if command and (
        command[0] in KUBECTL_MUTATING_VERBS
        or command[:2] == ["set", "image"]
        or (
            command[0] == "rollout"
            and command[1:2] in (["pause"], ["restart"], ["resume"], ["undo"])
        )
    ):
        return _mutation("kubernetes", "kubectl command that acts on the cluster")
    command = kubectl_command(words)
    if command is None or not words:
        return _unrecognized("kubectl without a verb this guard can find")
    if not command:
        return _local("kubectl global flags only")
    if (
        any(
            re.fullmatch(r"secrets?(?:\.[^./,]+)*\.?(?:/.*)?", resource)
            for word in words
            for resource in word.split(",")
        )
        or any(word == "--raw" or word.startswith("--raw=") for word in words)
        or (
            command[0] == "get"
            and any(
                word in {"-f", "-k", "--filename", "--kustomize"}
                or word.startswith(("--filename=", "--kustomize="))
                for word in words
            )
        )
    ):
        return _unrecognized("kubectl output that can hold a secret")
    if command[0] == "config":
        if command[1:2] in (["current-context"], ["get-contexts"]):
            return _read("kubeconfig context lookup")
        # No global option: `--kubeconfig` or `--profile-output` picks a file to write.
        if (
            argv[1:3] == ["config", "use-context"]
            and len(argv) <= 4
            and not any(word.startswith("-") for word in argv[3:])
            and plain_words(argv)
        ):
            return KUBECTL_CONTEXT_SWITCH
        return _unrecognized("kubectl config command that is not a known read")
    if (
        (command[0] == "rollout" and command[1:2] in (["status"], ["history"]))
        or (command[0] == "auth" and command[1:2] == ["can-i"])
        or command[0] in KUBECTL_READ_VERBS
    ):
        return _read("kubectl read verb")
    return _unrecognized("kubectl command that is not a known read")


def classify_terraform(argv: list[str], words: list[str]) -> Classification:
    command = terraform_command(words)
    if not command:
        # None is an unknown global option; an empty list is global options only.
        if words and all(word in TERRAFORM_HELP_FLAGS for word in words):
            return _local("terraform help or version")
        return _unrecognized("terraform without a subcommand this guard can find")
    subcommand, options = command[0], command[1:]
    flags = terraform_flag_names(options)
    if (
        subcommand in TERRAFORM_MUTATING_SUBCOMMANDS
        or command[:2] == ["state", "rm"]
        or (subcommand == "init" and flags & TERRAFORM_STATE_MOVING_INIT_FLAGS)
    ):
        return _mutation("terraform", "terraform command that writes state")
    if subcommand in {"fmt", "init"}:
        return _local("changes only the working directory")
    if (
        subcommand in TERRAFORM_READ_SUBCOMMANDS
        # `-json`, `-raw` and asking for one output by name print a sensitive value in
        # clear text; a bare `terraform output` redacts it.
        or (
            subcommand == "output"
            and not flags & {"json", "raw"}
            and all(word.startswith("-") for word in options)
        )
        # `show -json` prints sensitive values in clear text too.
        or (subcommand == "show" and "json" not in flags)
        or (subcommand in {"state", "workspace"} and options[:1] in (["list"], ["show"]))
    ):
        return _read("terraform read")
    if (
        argv[1:3] == ["workspace", "select"]
        and len(argv) <= 4
        # Any flag stays blocked: `-or-create` writes a new workspace to the backend, and
        # `-chdir` picks another backend configuration.
        and not any(word.startswith("-") for word in argv[3:])
        and plain_words(argv)
    ):
        return TERRAFORM_WORKSPACE_SWITCH
    return _unrecognized("terraform command that is not a known read")


CLI_CLASSIFIERS = {
    "gh": classify_gh,
    "az": classify_az,
    "kubectl": classify_kubectl,
    "terraform": classify_terraform,
}


def classify(argv: list[str]) -> Classification:
    """Say what running `argv` would do. The guard and `prepare` share this one answer."""
    if argv == [UNRECOGNIZED_SHELL_COMMAND]:
        return _unrecognized("a command the shell scan cannot bind")
    executable = program_name(argv[0]) if argv else ""
    if executable in CLI_CLASSIFIERS:
        return CLI_CLASSIFIERS[executable](argv, [word.lower() for word in argv[1:]])
    if confluence_publish_subcommand(argv) in CONFLUENCE_WRITE_SUBCOMMANDS:
        return _mutation("confluence", "uploads page attachments")
    return _local("not a guarded CLI")


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
    config = root / "workspace" / "config.md"
    try:
        text = config.read_text(encoding="utf-8")
    except OSError as exc:
        raise ActionError(
            "workspace/config.md GitHub account mapping is required"
        ) from exc

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


def action_payload(
    root: Path,
    system: str,
    summary: str,
    argv: list[str],
    github_owner: str | None = None,
) -> dict[str, Any]:
    classification = classify(argv)
    if classification.kind != "mutation":
        if (
            argv
            and program_name(argv[0]) == "kubectl"
            and kubectl_command([word.lower() for word in argv[1:]]) is None
        ):
            raise ActionError(
                "kubectl has a global option this guard does not recognize; "
                "drop it or pass it as an environment setting, then prepare again"
            )
        raise ActionError("command is not an allowlisted external mutation")
    if system != classification.system:
        raise ActionError(f"system must be {classification.system} for this command")
    if github_owner and system != "github":
        raise ActionError("--github-owner is valid only for GitHub actions")
    offenders = literal_at_file_fields(root, argv)
    if offenders:
        raise ActionError(
            "gh api -f/--raw-field does not read files, so "
            f"{', '.join(offenders)} would post the path as the body text; "
            "build the payload with `jq -n --rawfile body \"$FILE\" '{body:$body}'` "
            'and pass `--input "$PAYLOAD_FILE"` instead '
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
        owner = github_target_owner(argv, github_owner)
        action["github_owner"] = owner
        action["github_owner_override"] = github_owner is not None
        action["github_account"] = configured_github_account(root, owner)
    return action


def ensure_manifest_path(root: Path, path: Path) -> Path:
    resolved = path.resolve()
    try:
        resolved.relative_to(external_action_dir(root).resolve())
    except ValueError as exc:
        raise ActionError(
            "manifest must live under workspace/tmp/external-actions"
        ) from exc
    return resolved


def load_manifest(root: Path, path: Path) -> tuple[Path, dict[str, Any]]:
    resolved = ensure_manifest_path(root, path)
    try:
        data = json.loads(resolved.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ActionError(f"cannot read manifest: {exc}") from exc
    if (
        not isinstance(data, dict)
        or data.get("version") != MANIFEST_VERSION
        or not isinstance(data.get("action"), dict)
    ):
        raise ActionError("manifest schema is invalid")
    action = data["action"]
    if data.get("action_sha256") != sha256(action):
        raise ActionError("manifest action hash does not match")
    argv = action.get("argv")
    if not isinstance(argv, list) or not all(isinstance(value, str) for value in argv):
        raise ActionError("manifest argv is invalid")
    classification = classify(argv)
    if classification.kind != "mutation" or classification.system != action.get("system"):
        raise ActionError("manifest command is not an allowlisted mutation")
    if action.get("system") == "github" and (
        not isinstance(action.get("github_account"), str)
        or not isinstance(action.get("github_owner"), str)
        or not isinstance(action.get("github_owner_override"), bool)
        or action.get("github_host") != "github.com"
    ):
        raise ActionError("GitHub manifest target or account is invalid")
    expected_payload = sha256(
        {"argv": argv, "payload_files": action.get("payload_files", [])}
    )
    if action.get("payload_sha256") != expected_payload:
        raise ActionError("manifest payload hash does not match")
    return resolved, data


PROSE_SURFACES: tuple[tuple[tuple[str, ...], str], ...] = (
    (("pr", "create"), "github-pr-body"),
    (("pr", "edit"), "github-pr-body"),
    (("pr", "comment"), "github-review-reply"),
    (("pr", "review"), "github-review-reply"),
    (("issue", "comment"), "github-review-reply"),
    (("issue", "create"), "github-pr-body"),
    (("issue", "edit"), "github-pr-body"),
    (("release", "create"), "github-pr-body"),
    (("release", "edit"), "github-pr-body"),
    (("pr", "merge"), "github-pr-body"),
)
PROSE_INLINE_FLAGS = {"--body", "-b", "--title", "-t", "--notes", "-n", "--subject"}
PROSE_INLINE_FIELDS = {"body", "title", "name"}
PROSE_TEXT_SUFFIXES = {"", ".md", ".txt", ".markdown"}
PROSE_BODY_KEYS = {"body", "body_text"}
# `gh api .../pulls/{n}/reviews` is how a review is actually submitted, so the
# endpoint form has to be recognized too, not just the `gh pr` porcelain.
PROSE_API_ENDPOINTS = re.compile(
    r"(?:^|/)(?:pulls|issues|releases)(?:[/?]|$)", re.IGNORECASE
)


def prose_surface(argv: list[str]) -> str | None:
    if not argv or Path(argv[0]).name != "gh":
        return None
    words = [token for token in gh_noun_first(argv)[1:] if not token.startswith("-")]
    if not words:
        return None
    if words[0] == "api":
        return (
            "github-review-reply"
            if any(PROSE_API_ENDPOINTS.search(w) for w in words[1:])
            else None
        )
    for prefix, surface in PROSE_SURFACES:
        if tuple(words[: len(prefix)]) == prefix:
            return surface
    return None


def prose_inline_texts(argv: list[str]) -> list[tuple[str, str]]:
    """Return (label, text) pairs for prose passed inline in argv, not through a file.

    `--body "..."`, `--title=...`, `-b...`, and `gh api -f body=...`. A value that starts
    with `@` is a file reference, which the payload-file pass already reads.
    """
    found: list[tuple[str, str]] = []
    is_api = argv[1:2] == ["api"]
    for index, word in enumerate(argv[1:], 1):
        if not word.startswith("-") or len(word) < 2:
            continue
        if word.startswith("--"):
            flag, has_value, value = word.partition("=")
        else:
            flag, value = word[:2], word[2:].removeprefix("=")
            has_value = bool(value)
        if not has_value:
            value = argv[index + 1] if index + 1 < len(argv) else ""
        if is_api and flag in {"-f", "-F", "--raw-field", "--field"}:
            key, delimiter, text = value.partition("=")
            if delimiter and key in PROSE_INLINE_FIELDS and not text.startswith("@"):
                found.append((f"argv[{index}] {key}", text))
        elif not is_api and flag in PROSE_INLINE_FLAGS and value.strip():
            found.append((f"argv[{index}] {flag}", value))
    return found


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
    return lint_prose_texts(root, prose_bodies(path), surface)


def lint_prose_texts(
    root: Path, texts: list[tuple[str, str]], surface: str
) -> list[str]:
    """Return gate-level prose findings. Never raises: the linter is a quality
    check, not a security control, so a broken linter must not block a write. It must
    not be silent either, so a skipped or failed lint says so on stderr."""
    if not texts:
        return []
    if os.environ.get("NASE_PROSE_LINT") == "0":
        print("NOTE: NASE_PROSE_LINT=0; payload prose was not linted.", file=sys.stderr)
        return []
    lint = root / ".claude" / "scripts" / "prose-lint.py"
    if not lint.is_file():
        print(
            "WARNING: prose-lint.py is missing; payload prose was not linted.",
            file=sys.stderr,
        )
        return []
    findings: list[str] = []
    for label, text in texts:
        try:
            completed = subprocess.run(
                [
                    sys.executable,
                    str(lint),
                    "--surface",
                    surface,
                    "--file",
                    "-",
                    "--format",
                    "json",
                ],
                input=text,
                capture_output=True,
                encoding="utf-8",
                env={**os.environ, "PYTHONIOENCODING": "utf-8"},
                timeout=20,
                check=False,
            )
            report = json.loads(completed.stdout)
        except (OSError, ValueError, subprocess.SubprocessError):
            print(
                f"WARNING: prose-lint failed on {label}; it was not linted.",
                file=sys.stderr,
            )
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


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(f"{path.suffix}.tmp-{uuid.uuid4().hex}")
    temporary.write_bytes(canonical_bytes(value, ensure_ascii=True, trailing_newline=True))
    os.chmod(temporary, 0o600)
    temporary.replace(path)


def mentions_guarded_executable(command: str) -> bool:
    """Report whether a guarded CLI name appears anywhere in the command text.

    Used only when static parsing has already failed, so it deliberately reads the raw
    text rather than the lexed segments: `eval 'gh pr create'` hides the name inside a
    single-quoted span that the lexer collapses into one harmless argument, and a
    function body assembled around it never reaches an executable position at all.

    It cannot see a name built by substitution (`$(printf 'g''h') pr create`). That is
    accepted: this guard bounds the commands this agent writes by mistake, and the cost of
    treating every unparseable command as guarded is that read-only work stops working.
    """
    return bool(GUARDED_MENTION_RE.search(command))


UNRECOGNIZED_SHELL_COMMAND = "__unrecognized_shell_command__"
UNBINDABLE_HEADS = {"alias", "eval", "function", "source", "."}
SHELL_WORD_RE = re.compile(r"(?<![\w-])(?:bash|dash|ksh|sh|zsh)(?![\w.-])")


def runs_exactly(command: str, argvs: list[list[str]]) -> bool:
    """True when the command text is one program's words, single spaced, and nothing else.

    The exact-word rules need this. An assignment, an earlier command, a wrapper or a
    redirect can change where the program sends data, and a variable or a quote can give
    it other words: PowerShell reads `'f'-X` as two arguments.
    """
    return [command.strip(" \r\n").split(" ")] == argvs


def command_argvs(result: shell_scan.ScanResult):
    """Yield the argv of every program the scanned command would run.

    Parsing is `shell_scan`'s job. What stays here is the policy: an invocation whose
    program cannot be bound, a shell fed from a pipe or here-string, and a construct
    inside a nested script that cannot be bound all yield one `UNRECOGNIZED` marker,
    which `classify` fails closed on.

    A `< script.sh` redirect is deliberately not a shell-fed case: it reads a file named
    on the command line, which this guard cannot read either way, exactly like
    `bash script.sh`.
    """
    for invocation in result.invocations:
        # `eval` already yields the marker, and a function call's arguments are re-read as a
        # command only for the git guard: here a function that forwards `"$@"` is caught by
        # the dynamic program in its own body, and re-reading every argument as a program
        # blocked `rec source ...` style helper calls for nothing.
        if "eval" in invocation.via or "function-call" in invocation.via:
            continue
        if (
            invocation.head_dynamic
            or (invocation.glob and invocation.glob[0])
            or invocation.name in UNBINDABLE_HEADS
        ):
            yield [UNRECOGNIZED_SHELL_COMMAND]
            continue
        yield invocation.argv
        if (
            invocation.is_shell()
            and invocation.script_stdin
            and invocation.stdin in {"pipe", "herestring"}
        ):
            yield [UNRECOGNIZED_SHELL_COMMAND]
    if result.nested_opaque:
        yield [UNRECOGNIZED_SHELL_COMMAND]


# Programs whose arguments are data to them, so a guarded CLI name among those arguments
# is text, not a command: `which gh`, `grep gh file`, `git log -- az`.
INERT_PROGRAMS = frozenset({
    "echo", "printf", "grep", "egrep", "fgrep", "rg", "ag", "which", "type", "whereis", "man",
    "cat", "head", "tail", "wc", "ls", "git", "jq", "sed", "diff", "cmp", "sort", "uniq", "cut",
    "tr", "tee", "test", "[", "[[", "true", "false", "basename", "dirname", "realpath", "cd",
    "mkdir", "touch", "cp", "mv", "rm", "chmod", "stat", "file", "open", "pbcopy", "less", "more",
    "date", "sleep", "read", "export", "unset", "set", "local", "declare", "alias", "unalias",
    "ack", "zgrep", "mdfind", "vim",
})
# Common words that are also program names. As the head of a command they are inert, but
# they turn up as plain arguments (`docker run --name test img ...`), so they must not end
# the scan of a carrier's arguments.
AMBIGUOUS_ARGUMENT_WORDS = frozenset({
    "test", "[", "[[", "file", "type", "set", "read", "local", "date", "open", "more", "man",
    "stat", "export", "unset", "declare", "alias", "unalias", "sleep", "true", "false", "cd",
})
# Programs that hand their arguments to another host, container, or terminal as a command.
EXEC_WRAPPERS = frozenset({
    "ssh", "docker", "podman", "sudo", "doas", "su", "script", "tmux", "screen", "watch",
    "nsenter",
})
# `npm install -g terraform` names a package, not a command. Only these subcommands are data.
PACKAGE_MANAGERS = frozenset({
    "npm", "pnpm", "yarn", "pip", "pip3", "brew", "apt", "apt-get", "cargo", "uv", "gem",
})
PACKAGE_DATA_SUBCOMMANDS = frozenset({
    "install", "i", "add", "remove", "uninstall", "update", "upgrade", "info", "view",
    "search", "list", "ls", "show", "test", "outdated",
})
# A heredoc can run to thousands of lines; no command in it is longer than this window.
INLINE_TOKEN_WINDOW = 32
# Interpreters whose inline code or stdin script cannot be parsed here.
INTERPRETERS_RE = re.compile(r"^(?:python[\d.]*|pypy3?|node|nodejs|deno|bun|perl|ruby|php|lua|osascript|awk|gawk|mawk|pwsh|powershell|tclsh|expect|groovy|jshell)$")
INLINE_CODE_FLAGS = frozenset({"-c", "-e", "-E", "-r", "-p", "--eval", "--command", "-command", "-Command", "--print"})
INTERPRETER_EXEC_RE = re.compile(
    r"subprocess|os\.(?:system|popen|exec\w*|spawn\w*)|popen|child_process|exec(?:Sync|File)\b|\bspawn(?:Sync)?\(|system\s*\(|"
    r"Open3|shell_exec|passthru|do shell script|IO\.popen|Runtime\.getRuntime|ProcessBuilder",
)
SCRIPT_FILE_RE = re.compile(r"\.(?:py|js|mjs|cjs|ts|rb|pl|php|lua|sh)$")


def _carried_words(argv: list[str]) -> list[str]:
    """The arguments a carrier hands on, up to the first program that only reads them.

    `ssh host grep 'gh pr merge' log` ends at `grep`: what follows is its pattern.
    """
    words = argv[1:]
    for index, word in enumerate(words):
        name = program_name(word)
        if name in INERT_PROGRAMS and name not in AMBIGUOUS_ARGUMENT_WORDS:
            return words[:index]
    return words


def _package_data_call(name: str, argv: list[str]) -> bool:
    if name not in PACKAGE_MANAGERS:
        return False
    subcommand = next((word for word in argv[1:] if not word.startswith("-")), "")
    return subcommand in PACKAGE_DATA_SUBCOMMANDS


def _nested_scripts(words: list[str]):
    for word in words:
        if re.search(r"\s", word) and GUARDED_MENTION_RE.search(word):
            yield word


def _interpreter_code(inv: shell_scan.Invocation, command: str) -> str | None:
    """Return the code text an interpreter runs when it is inline or fed on stdin."""
    argv = inv.argv
    name = program_name(argv[0])
    if re.match(r"^(?:awk|gawk|mawk)$", name):
        return next((w for w in argv[1:] if not w.startswith("-")), None)
    skip_value = False
    for i, word in enumerate(argv[1:], 1):
        if skip_value:
            skip_value = False
            continue
        if word in PYTHON_VALUE_OPTIONS:
            skip_value = True
            continue
        short = word.startswith("-") and not word.startswith("--") and len(word) > 1
        if word in INLINE_CODE_FLAGS or (short and word[-1] in "ceE"):
            return " ".join(argv[i + 1 :])
        if not word.startswith("-"):
            return None  # a script file: the rest are its arguments, which are data
    if inv.script_stdin or inv.stdin in {"heredoc", "herestring"}:
        body = re.search(r"<<-?\s*[\"']?\w+", command)
        return command[body.start() :] if body else command
    return None


def carrier_argvs(result: shell_scan.ScanResult, command: str):
    """Yield argv tails of guarded CLIs that a non-guarded, non-inert program would run.

    Default-deny instead of a longer wrapper list: a guarded name that starts a
    mutation-shaped tail inside the argv of a program that is not guarded and not known to
    treat its arguments as data is judged as if it ran directly. `ssh host gh pr view 1`
    stays allowed (read), `ssh host gh pr merge 1` is blocked. Quoted arguments are
    re-scanned as scripts. Inline interpreter code and stdin scripts cannot be parsed, so
    they are read only when they contain an exec primitive, and then as loose tokens.
    Arguments after `interpreter script.py` belong to that script and are data.
    """
    for inv in result.invocations:
        argv = inv.argv
        if not argv or inv.function_call or inv.head_dynamic or "eval" in inv.via:
            continue
        name = program_name(argv[0])
        if name in UNBINDABLE_HEADS:
            continue
        if name in GUARDED_EXECUTABLES or name in INERT_PROGRAMS or inv.is_shell():
            continue
        if _package_data_call(name, argv):
            continue
        if INTERPRETERS_RE.match(name):
            code = _interpreter_code(inv, command)
            if code is not None:
                if INTERPRETER_EXEC_RE.search(code):
                    tokens = re.findall(r"[\w./:=@-]+|--?[\w-]+", code)
                    for i, token in enumerate(tokens):
                        window = tokens[i : i + INLINE_TOKEN_WINDOW]
                        if (
                            program_name(token) in GUARDED_EXECUTABLES
                            and classify(window).kind == "mutation"
                        ):
                            yield window
                continue
        words = _carried_words(argv)
        guarded_at = next(
            (i for i, w in enumerate(words) if program_name(w) in GUARDED_EXECUTABLES),
            len(words),
        )
        if INTERPRETERS_RE.match(name) and any(
            SCRIPT_FILE_RE.search(w) for w in words[:guarded_at]
        ):
            continue
        for i, word in enumerate(words):
            if (
                program_name(word) in GUARDED_EXECUTABLES
                and classify(words[i:]).kind == "mutation"
            ):
                yield words[i:]
        if name in EXEC_WRAPPERS:
            for text in _nested_scripts(words):
                yield from command_argvs(shell_scan.scan(text))


def dynamic_args_are_reads(result: shell_scan.ScanResult) -> bool:
    """True when the only dynamic parts are arguments of a `gh` read with a fixed verb.

    `gh pr view $(git branch --show-current)` cannot become a mutation through its
    argument, because the noun and verb are literal and `view` has no write flag. A
    substitution in the executable or verb position, anywhere inside a nested script,
    or around any other guarded CLI keeps failing closed: `gh api` and `kubectl get`
    arguments can carry flags or resource names the static checks exist to read.
    """
    if result.unparseable or result.top_opaque - {"substitution"}:
        return False
    for invocation in result.invocations:
        argv = invocation.argv
        if not argv or program_name(argv[0]) not in GUARDED_EXECUTABLES:
            continue
        if "subst" in invocation.via or invocation.env_dynamic:
            return False
        if invocation.dynamic and not (
            program_name(argv[0]) == "gh"
            and len(argv) >= 3
            and not any(invocation.dyn[:3])
            and argv[1].lower() not in {"api", "auth"}
            and classify(argv).kind in {"read", "local"}
        ):
            return False
    return True


def cmd_prepare(args: argparse.Namespace) -> int:
    argv = list(args.argv)
    if argv and argv[0] == "--":
        argv.pop(0)
    action = action_payload(
        args.root, args.system, args.summary, argv, args.github_owner
    )
    action_dir = external_action_dir(args.root)
    action_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(action_dir, 0o700)
    path = (
        action_dir
        / f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex}.json"
    )
    manifest = {"version": MANIFEST_VERSION, "created_at": utc_now_iso(microseconds=False), "action": action}
    manifest["action_sha256"] = sha256(action)
    write_json(path, manifest)
    print(json.dumps({"manifest": str(path), "action": action}, sort_keys=True))
    return 0


CLAIM_GRACE_SECONDS = 60
CLAIM_NAME_RE = re.compile(r"\.executing-(?:(\d+)-(\d+)-)?[0-9a-f]{32}$")


def claim_is_stale(claim: Path, now: float | None = None) -> bool:
    """A claim is abandoned when its executor is gone or past its own kill deadline.

    The owner pid and the deadline ride in the file name, so they land atomically with the
    rename that claims the token. The deadline also covers pid reuse: no live executor can
    outlast its own `--timeout-seconds` by more than the grace period.
    """
    now = time.time() if now is None else now
    match = CLAIM_NAME_RE.search(claim.name)
    if match and match.group(1):
        if now > int(match.group(2)) + CLAIM_GRACE_SECONDS:
            return True
        return not pid_alive(int(match.group(1)))
    try:  # pre-upgrade claim with no owner info: fall back to the longest legal run
        age = now - claim.stat().st_mtime
    except OSError:
        return False
    return age > EXECUTE_TIMEOUT_SECONDS + TOKEN_TTL_SECONDS + CLAIM_GRACE_SECONDS


def token_is_expired(path: Path, now: float | None = None) -> bool:
    """An unreadable or past-TTL token can never pass verify_token, so it is not 'active'."""
    try:
        token = json.loads(path.read_text(encoding="utf-8"))
        created = parse_timestamp(str(token.get("created_at", "")))
        ttl = token.get("ttl_seconds")
        if not isinstance(ttl, int) or isinstance(ttl, bool):
            return True
    except (OSError, ValueError, AttributeError, ActionError):
        return True
    current = (
        datetime.now(timezone.utc)
        if now is None
        else datetime.fromtimestamp(now, timezone.utc)
    )
    return (current - created).total_seconds() > ttl


def discard_dead_file(path: Path, reason: str) -> None:
    """Rename first so two concurrent authorizers cannot both delete and then both re-create."""
    graveyard = path.with_name(f"{path.name}.discarded-{uuid.uuid4().hex}")
    try:
        path.replace(graveyard)
    except FileNotFoundError:
        return
    graveyard.unlink(missing_ok=True)
    print(f"NOTE: removed {reason}: {path.name}", file=sys.stderr)


def cmd_authorize(args: argparse.Namespace) -> int:
    _, manifest = load_manifest(args.root, args.manifest)
    if not 0 < args.ttl_seconds <= TOKEN_TTL_SECONDS:
        raise ActionError(
            f"token TTL must be between 1 and {TOKEN_TTL_SECONDS} seconds"
        )
    path = token_path(args.root)
    token = {
        "version": MANIFEST_VERSION,
        "action_sha256": manifest["action_sha256"],
        "created_at": utc_now_iso(microseconds=False),
        "ttl_seconds": args.ttl_seconds,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path.with_name(f"{path.name}.lock"), "a") as lock:
        # Two authorizers must not both pass the "already active" check below.
        lock_exclusive(lock)
        for claim in path.parent.glob(f"{path.name}.executing-*"):
            if claim_is_stale(claim):
                discard_dead_file(claim, "abandoned external-write claim")
        if path.exists() and token_is_expired(path):
            discard_dead_file(path, "expired external-write token")
        active_claim = next(path.parent.glob(f"{path.name}.executing-*"), None)
        if path.exists() or active_claim is not None:
            raise ActionError(
                "an external-write token is already active; execute or remove it before authorizing another action"
            )
        write_json(path, token)
    print(
        json.dumps(
            {"token": str(path), "expires_in_seconds": args.ttl_seconds}, sort_keys=True
        )
    )
    return 0


def claim_token(root: Path, timeout_seconds: float) -> tuple[Path, dict[str, Any]]:
    """Atomically move the one-shot token out of circulation before execution."""
    path = token_path(root)
    # The claim also covers the preflight lookups that run before the bounded mutation.
    deadline = int(time.time() + timeout_seconds + 2 * GITHUB_PREFLIGHT_TIMEOUT_SECONDS)
    claimed = path.with_name(
        f"{path.name}.executing-{os.getpid()}-{deadline}-{uuid.uuid4().hex}"
    )
    try:
        with open(path.with_name(f"{path.name}.lock"), "a") as lock:
            # The rename must hold the same lock `cmd_authorize` uses for its
            # "already active" check: otherwise a claim can land in the middle
            # of that check-then-write, and authorize's view of the token state
            # is stale when it writes a second token.
            lock_exclusive(lock)
            path.replace(claimed)
    except FileNotFoundError as exc:
        # Covers a missing token and a missing `workspace/` directory alike:
        # the lock file cannot be opened when its directory is absent.
        raise ActionError("no external-write token present") from exc
    try:
        token = json.loads(claimed.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        claimed.unlink(missing_ok=True)
        raise ActionError(f"external-write token is invalid: {exc}") from exc
    if not isinstance(token, dict):
        claimed.unlink(missing_ok=True)
        raise ActionError("external-write token is invalid: not a JSON object")
    return claimed, token


def ledger_path(root: Path) -> Path:
    return root / "workspace" / "logs" / ".external-writes.jsonl"


def record_outcome(
    root: Path,
    manifest_path: Path,
    action: dict[str, Any],
    exit_code: int | None,
    outcome: str,
) -> None:
    """Append one outcome row; the mutation already ran, so a failure only warns."""
    row = {
        "ts": utc_now_iso(),
        "manifest": manifest_path.name,
        "action_sha256": sha256(action),
        "system": action.get("system"),
        "summary": action.get("summary"),
        "exit": exit_code,
        "outcome": outcome,
    }
    path = ledger_path(root)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path.with_name(f"{path.name}.lock"), "a") as lock:
            lock_exclusive(lock)
            fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            with os.fdopen(fd, "a", encoding="utf-8") as ledger:
                ledger.write(json.dumps(row, sort_keys=True) + "\n")
    except OSError as exc:
        print(f"WARNING: could not record outcome ledger row: {exc}", file=sys.stderr)


def verify_token(token: dict[str, Any], manifest: dict[str, Any]) -> None:
    if not isinstance(token, dict) or token.get("version") != MANIFEST_VERSION:
        raise ActionError("external-write token schema is invalid")
    if token.get("action_sha256") != manifest.get("action_sha256"):
        raise ActionError("external-write token does not match this manifest")
    created_at = parse_timestamp(str(token.get("created_at", "")))
    ttl = token.get("ttl_seconds")
    if not isinstance(ttl, int) or ttl <= 0 or ttl > TOKEN_TTL_SECONDS:
        raise ActionError("external-write token TTL is invalid")
    age = (datetime.now(timezone.utc) - created_at).total_seconds()
    if age < 0 or age > ttl:
        raise ActionError("external-write token is stale or from the future")


def cmd_execute(args: argparse.Namespace) -> int:
    if args.timeout_seconds <= 0:
        raise ActionError("execute timeout must be a positive number of seconds")
    token_file: Path | None = None
    try:
        token_file, token = claim_token(args.root, args.timeout_seconds)
        manifest_path, manifest = load_manifest(args.root, args.manifest)
        verify_token(token, manifest)
        action = manifest["action"]
        verify_payload_files(args.root, action)
        try:
            if action["system"] == "github":
                completed = run_github_action(args.root, action, args.timeout_seconds)
            else:
                # Do not let ambient GitHub auth env vars leak into a non-GitHub
                # CLI: an approved `az`/`kubectl`/`terraform` call must not
                # silently inherit a stray GH_TOKEN. Target selectors are
                # deliberately kept, because they are the approved target, not
                # credentials.
                environment = os.environ.copy()
                for key in GITHUB_AUTH_ENV_VARS:
                    environment.pop(key, None)
                environment[NO_CWD_SEARCH_ENV_VAR] = "1"
                for redirect_var in TARGET_SELECTOR_ENV_VARS.get(
                    action["system"], ()
                ):
                    if redirect_var in environment:
                        print(
                            f"NOTE: {redirect_var} is set and selects the target for "
                            f"this {action['system']} write.",
                            file=sys.stderr,
                        )
                completed = subprocess.run(
                    launch_argv(action["argv"]),
                    cwd=args.root,
                    env=environment,
                    check=False,
                    timeout=args.timeout_seconds,
                )
        except subprocess.TimeoutExpired:
            # Not a failure: the CLI may have applied the mutation before the bound
            # expired, and nothing here can tell which. Say so, and let the consumed
            # token force a fresh approval rather than inviting a blind retry.
            print(
                f"TIMEOUT: {action['system']} write exceeded {args.timeout_seconds}s; the CLI "
                "process was killed.\n"
                "  The mutation MAY already have been applied. Read the target state before "
                "deciding anything.\n"
                "  Only the CLI itself was signalled, so any helper process it spawned (a "
                "Terraform provider, for one) can still be running.\n"
                "  The one-shot token is spent, so a retry needs a new preview and approval.",
                file=sys.stderr,
            )
            record_outcome(args.root, manifest_path, action, None, "unknown")
            return EXECUTE_TIMEOUT_EXIT
        except OSError as exc:
            print(
                f"ERROR: could not launch {action['argv'][0]}: {exc}\n"
                "  Nothing was mutated. The one-shot token is spent, so a retry needs a "
                "new approval.",
                file=sys.stderr,
            )
            record_outcome(args.root, manifest_path, action, None, "not-launched")
            return EXECUTE_LAUNCH_EXIT
        record_outcome(
            args.root,
            manifest_path,
            action,
            completed.returncode,
            "ok" if completed.returncode == 0 else "failed",
        )
        return completed.returncode
    finally:
        if token_file is not None:
            token_file.unlink(missing_ok=True)


def cmd_audit(args: argparse.Namespace) -> int:
    manifests = {path.name for path in external_action_dir(args.root).glob("*.json")}
    ledger_names: set[str] = set()
    outcomes: list[str] = []
    malformed = 0
    try:
        lines = ledger_path(args.root).read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        lines = []
    for line in lines:
        try:
            row = json.loads(line)
            name, outcome = row["manifest"], row["outcome"]
            if not isinstance(name, str) or not isinstance(outcome, str):
                raise TypeError("ledger row fields must be strings")
        except (json.JSONDecodeError, KeyError, TypeError):
            malformed += 1
            continue
        ledger_names.add(name)
        outcomes.append(outcome)
    print(
        json.dumps(
            {
                "prepared": len(manifests),
                "executed": sum(1 for o in outcomes if o in ("ok", "failed")),
                "unknown_outcome": outcomes.count("unknown"),
                "not_launched": outcomes.count("not-launched"),
                "prepared_not_executed": len(manifests - ledger_names),
                "ledger_without_manifest": len(ledger_names - manifests),
                "malformed_ledger_lines": malformed,
            },
            sort_keys=True,
        )
    )
    return 0


def lone_direct_gh_call(command: str, result: shell_scan.ScanResult) -> bool:
    """True when the command text is `gh` and its arguments, single-spaced, and no more.

    Only then does a file the guard reads match the file `gh` will open: another command
    could rewrite it or change directory first, and a wrapper could run `gh` elsewhere.
    The scanner reports no invocation for some of those, such as an assignment or a bare
    `xargs`, and PowerShell splits at quotes and some whitespace that the scanner keeps
    inside a word, so the text itself must be the one invocation's argv joined by spaces.
    """
    if result.unparseable or len(result.invocations) != 1:
        return False
    invocation = result.invocations[0]
    return (
        command.rstrip("\r\n").split(" ") == invocation.argv
        and invocation.name == "gh"
        and not invocation.via
        and not invocation.wrappers
        and not invocation.dynamic
        and not any(invocation.glob)
        and invocation.cwds == ("",)
    )


def cmd_guard(args: argparse.Namespace) -> int:
    command = args.command
    if command is None:
        command = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    result = shell_scan.scan(command)
    GRAPHQL_FILE_BASE.clear()
    if (
        args.cwd
        and lone_direct_gh_call(command, result)
        and graphql_file_words(result.invocations[0].argv)
    ):
        GRAPHQL_FILE_BASE.append(Path(args.cwd))
    unbindable_target = bool(command) and (result.unparseable or bool(result.top_opaque))
    # Failing closed here is only justified when a guarded CLI could actually be
    # reached. Blocking every command this parser cannot bind blocks the read-only
    # majority - a `$(...)` inside an `echo`, a backtick quoted in prose - and each
    # one costs a rewrite and a re-run without protecting anything. A command that
    # cannot be lexed at all also hides a `| bash`, so a shell name counts as reach too.
    reaches_guarded = mentions_guarded_executable(result.visible_text) or (
        result.unparseable and bool(SHELL_WORD_RE.search(result.visible_text))
    )
    if unbindable_target and reaches_guarded and not dynamic_args_are_reads(result):
        print(
            "BLOCKED: could not safely parse this command, and it names a guarded CLI "
            f"({', '.join(GUARDED_EXECUTABLES)}) or a shell.\n"
            "  Rewrite it without the dynamic construct, or prepare a payload-bound "
            "action with .claude/scripts/external-write-action.py.",
            file=sys.stderr,
        )
        return 10
    argvs = list(command_argvs(result)) + list(carrier_argvs(result, command))
    classes = {classify(argv) for argv in argvs}
    kinds = {found.kind for found in classes}
    if "mutation" in kinds:
        print(
            "BLOCKED: raw external mutation. Prepare, show, authorize, and execute the action with "
            ".claude/scripts/external-write-action.py instead.",
            file=sys.stderr,
        )
        return 10
    # `getattr`: a caller that builds its own namespace passes the text as run.
    inexact = getattr(args, "inexact_text", False)
    if "unrecognized" in kinds or (
        classes & EXACT_WORD_RULES and (inexact or not runs_exactly(command, argvs))
    ):
        print(
            "BLOCKED: unrecognized external CLI command. Use an explicit read-only command or "
            "prepare an allowlisted payload-bound mutation action.",
            file=sys.stderr,
        )
        return 10
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=Path, default=Path(__file__).resolve().parents[2]
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


if __name__ == "__main__":
    raise SystemExit(main())
