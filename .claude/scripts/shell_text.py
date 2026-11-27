"""Where the shell that runs a command reads it differently from `shell_scan`.

`shell_scan` reads POSIX words. `read()` takes the command text exactly as the tool
received it and returns two things the CLI guard acts on:

- a reason to refuse it, when the guard cannot know the arguments the shell passes;
- a second reading to classify as well.

For PowerShell the reading is one line for each command PowerShell's own parser finds,
holding that command's words (`powershell_argv.ps1`, which parses and never invokes).
`has_no_line` names the commands the reading leaves out.
"""

from __future__ import annotations

import base64
import json
import os
import re
import shlex
import subprocess
import tempfile
from collections.abc import Callable
from pathlib import Path

PARSER_SCRIPT = Path(__file__).with_name("powershell_argv.ps1")
# The hook that runs this guard has 15 seconds, and one that times out does not block.
PARSER_TIMEOUT_SECONDS = 8
PLAIN_SPACE = " \t\r\n"
# A stand-in no shell reading here treats as special or as a space.
PLACEHOLDER = "\ue000"
LONE_CR_RE = re.compile(r"\r(?!\n)")
# Nothing sets this variable. It makes the scanner treat a word as built at run time.
DYNAMIC_WORD = "$NASE_DYNAMIC"
MUTATION_RE = re.compile(r"\bmutation\b", re.IGNORECASE)
FILE_EXTENSION_RE = re.compile(r"\.[A-Za-z0-9]+\Z")


def odd_space(char: str) -> bool:
    return char.isspace() and char not in PLAIN_SPACE


class _RefusedError(Exception):
    pass


def opens_with_using(text: str) -> bool:
    """Whether the first statement is `using`, which can make the parser load files."""
    index = 0
    while index < len(text):
        if text[index].isspace() or text[index] in ";`":
            index += 1
            continue
        if text.startswith("<#", index):
            opener, closer = "<#", "#>"
        elif text[index] == "#":
            opener, closer = "#", "\n"
        else:
            break
        # Search past the opener: the `#>` in `<#>` does not close that comment.
        end = text.find(closer, index + len(opener))
        if end < 0:
            return False
        index = end + len(closer)
    return text[index : index + 5].lower() == "using"


def find_powershell(find_program: Callable[[list[str]], list[str]]) -> list[str]:
    for name in ("pwsh", "powershell"):
        try:
            words = find_program([name])
        except FileNotFoundError:
            continue
        if os.path.isabs(words[0]):
            return words
    raise _RefusedError("no PowerShell was found")


def run_parser(raw: str, program: list[str]) -> bytes:
    script = base64.b64encode(
        PARSER_SCRIPT.read_text(encoding="utf-8").encode("utf-16-le")
    ).decode("ascii")
    argv = [*program, "-NoProfile", "-NonInteractive", "-EncodedCommand", script]
    # Files, not pipes: when the program is a launcher, a pipe keeps the timeout
    # waiting for the launcher's child.
    with tempfile.TemporaryFile() as given, tempfile.TemporaryFile() as answer:
        given.write(json.dumps(raw).encode("ascii"))
        given.seek(0)
        try:
            done = subprocess.run(
                argv,
                stdin=given,
                stdout=answer,
                stderr=subprocess.DEVNULL,
                timeout=PARSER_TIMEOUT_SECONDS,
                check=False,
            )
        except subprocess.TimeoutExpired:
            raise _RefusedError("PowerShell did not answer in time") from None
        except OSError:
            raise _RefusedError("PowerShell could not start") from None
        if done.returncode:
            raise _RefusedError(f"PowerShell exited with code {done.returncode}")
        answer.seek(0)
        return answer.read()


def word_shape(word: object) -> bool:
    if not isinstance(word, dict) or "value" not in word:
        return False
    if not isinstance(word.get("text"), str):
        return False
    if word.get("kind") in ("constant", "expandable"):
        return isinstance(word["value"], str)
    return word.get("kind") == "other"


def parse_commands(
    raw: str, find_program: Callable[[list[str]], list[str]]
) -> list[list[dict]]:
    """The words of every command PowerShell's parser finds in `raw`."""
    output = run_parser(raw, find_powershell(find_program))
    unreadable = _RefusedError("PowerShell's answer could not be read")
    try:
        answer = json.loads(base64.b64decode(output.strip(), validate=True))
        errors = answer["errors"]
        commands = [command["words"] for command in answer["commands"]]
    except (ValueError, KeyError, TypeError):
        raise unreadable from None
    if not isinstance(errors, int) or not all(
        isinstance(words, list) and all(map(word_shape, words)) for words in commands
    ):
        raise unreadable
    if errors:
        raise _RefusedError("PowerShell reports a parse error")
    return commands


def reading_word(word: dict) -> str:
    if word["kind"] == "other":
        return DYNAMIC_WORD
    # `shell_scan` reads a backslash as an escape; PowerShell passes it as written.
    value = word["value"].replace("\\", "/")
    if word["kind"] == "constant":
        return shlex.quote(value)
    # The text before the first `$` stays, so a flag or field name stays visible.
    prefix, _, rest = value.partition("$")
    head, field, _ = prefix.partition("query=")
    # A GraphQL query is judged by its words: one that hides `mutation` stays unknown.
    if field and MUTATION_RE.search(rest):
        prefix = head + field
    # A literal file extension stays too: it marks a word as a script path.
    extension = FILE_EXTENSION_RE.search(rest)
    return (
        (shlex.quote(prefix) if prefix else "")
        + f'"{DYNAMIC_WORD}"'
        + (extension.group() if extension else "")
    )


def reading_line(words: list[dict]) -> str:
    line = [reading_word(word) for word in words]
    # `select` is Select-Object here; unquoted, `shell_scan` reads the shell's loop.
    if line[:1] == ["select"]:
        line[0] = "'select'"
    return " ".join(line)


def has_no_line(words: list[dict], mentions: Callable[[str], bool]) -> bool:
    """Whether the reading leaves a command out; commands written inside it keep theirs.

    `& { ... }` runs a block spelled out in the command. A program named by a
    parenthesized expression is judged only when that text names a guarded CLI.
    """
    if not words or words[0]["kind"] != "other":
        return False
    head = words[0]["text"]
    if head.startswith("{"):
        return head.endswith("}")
    return head.startswith("(") and not mentions(head)


def powershell_reading(
    raw: str,
    mentions: Callable[[str], bool],
    find_program: Callable[[list[str]], list[str]],
) -> str:
    # Both are refused before parsing: the parser may load what they name.
    if opens_with_using(raw):
        raise _RefusedError("it opens with a `using` statement")
    if "import-dscresource" in raw.lower().replace("`", ""):
        raise _RefusedError("it names Import-DscResource")
    commands = parse_commands(raw, find_program)
    for words in commands:
        # By value too: a quoted '--%' also changes which arguments PowerShell passes.
        if any("--%" in (word["text"], word["value"]) for word in words) and any(
            mentions(word["text"]) for word in words
        ):
            raise _RefusedError("it holds the stop-parsing token --%")
    return "\n".join(
        reading_line(words) for words in commands if not has_no_line(words, mentions)
    )


def read(
    raw: str,
    powershell: bool,
    mentions: Callable[[str], bool],
    find_program: Callable[[list[str]], list[str]],
) -> tuple[str | None, str]:
    """Return (reason to refuse, the shell's reading) for a command naming a guarded CLI.

    `mentions` says whether a piece of text names a guarded CLI. `find_program` turns
    `[name]` into the words that start that program, or raises `FileNotFoundError`.
    """
    if "\0" in raw:
        return "it holds a NUL character", raw
    if LONE_CR_RE.search(raw):
        return "it holds a carriage return without a line feed", raw
    if not powershell:
        return None, "".join(PLACEHOLDER if odd_space(c) else c for c in raw)
    try:
        return None, powershell_reading(raw, mentions, find_program)
    except _RefusedError as refused:
        return str(refused), raw
