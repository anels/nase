from __future__ import annotations

import re
from pathlib import Path
from typing import NamedTuple

import shell_scan

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
WINDOWS_EXECUTABLE_SUFFIXES = (".exe", ".cmd", ".bat", ".com")


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


UNRECOGNIZED_SHELL_COMMAND = "__unrecognized_shell_command__"
