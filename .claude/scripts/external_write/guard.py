from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import shell_scan
import shell_text

from .account import launch_argv
from .classification import (
    GH_API_LISTED_READ,
    GRAPHQL_FILE_BASE,
    GUARDED_EXECUTABLES,
    KUBECTL_CONTEXT_SWITCH,
    PYTHON_VALUE_OPTIONS,
    TERRAFORM_WORKSPACE_SWITCH,
    UNRECOGNIZED_SHELL_COMMAND,
    classify,
    graphql_file_words,
    program_name,
)

# A path prefix still names the same binary, so `/usr/bin/gh` counts; a longer word that
# merely starts with one does not, so `github`, `azure`, and `terraform-docs` do not.
GUARDED_MENTION_RE = re.compile(
    r"(?<![\w-])(?:"
    + "|".join(GUARDED_EXECUTABLES)
    + r")(?:\.(?:exe|cmd|bat|com))?(?![\w.-])",
    re.IGNORECASE,
)
EXACT_WORD_RULES = frozenset(
    {GH_API_LISTED_READ, KUBECTL_CONTEXT_SWITCH, TERRAFORM_WORKSPACE_SWITCH}
)


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


def guard_scan(command: str, cwd: str | None, inexact: bool) -> int:
    """Judge one reading of a command: 0 to allow it, 10 to block it."""
    result = shell_scan.scan(command)
    GRAPHQL_FILE_BASE.clear()
    if (
        cwd
        and lone_direct_gh_call(command, result)
        and graphql_file_words(result.invocations[0].argv)
    ):
        GRAPHQL_FILE_BASE.append(Path(cwd))
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


def mentions_guarded_in_any_shell(text: str) -> bool:
    """Like `mentions_guarded_executable`, through quotes, NULs, and Windows paths.

    A quote or NUL can sit inside a name or end it, so both readings count.
    """
    marks = "[\0'\"`\u2018-\u201e]"
    return any(
        mentions_guarded_executable(variant)
        or mentions_guarded_executable(variant.replace("\\", "/"))
        for variant in (text, re.sub(marks, "", text), re.sub(marks, " ", text))
    )


def guard_shell_text(raw: str, scanned: str, powershell: bool) -> int:
    """Judge the exact command text as the shell that runs it reads it.

    This can only add a block: `scanned`, the text the hook passes on, already passed.
    It drops NUL bytes, and a Windows `jq` ends each of its lines with CRLF.
    """
    if not mentions_guarded_in_any_shell(raw):
        return 0
    reason, reading = shell_text.read(
        raw, powershell, mentions_guarded_in_any_shell, launch_argv
    )
    if reason:
        shell = "PowerShell" if powershell else "the shell"
        print(
            f"BLOCKED: the guard cannot confirm how {shell} reads this command: "
            f"{reason}. Rewrite it with plain quotes, spaces, and line breaks.",
            file=sys.stderr,
        )
        return 10
    # Outer spaces and line ends add no word, and `runs_exactly` ignores them too.
    if reading.strip(" \r\n") == scanned.strip(" \r\n"):
        return 0
    return guard_scan(reading, None, True)


def cmd_guard(args: argparse.Namespace) -> int:
    command = args.command
    if command is None:
        command = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    raw = None
    # `getattr`: a caller that builds its own namespace passes only the text as run.
    if getattr(args, "raw_line", False):
        head, _, command = command.partition("\n")
        raw = json.loads(head)
    verdict = guard_scan(command, args.cwd, getattr(args, "inexact_text", False))
    if verdict or raw is None:
        return verdict
    return guard_shell_text(raw, command, args.powershell)
