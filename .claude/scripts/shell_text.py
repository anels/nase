"""Where the shell that runs a command reads it differently from `shell_scan`.

`shell_scan` reads POSIX words. `read()` takes the command text exactly as the tool
received it and returns two things the CLI guard acts on:

- a reason to refuse it, when the shell splits it where the scanner does not, so the
  guard cannot know the arguments;
- a second reading to classify as well, with the shell's comments, here-strings, line
  continuations, and literal characters rewritten into POSIX that means the same.

The PowerShell rules model its tokenizer only as far as word boundaries go.
"""

from __future__ import annotations

import re
from collections.abc import Callable

# PowerShell opens and closes a string with any quote of the same family.
SINGLE_QUOTES = "'\u2018\u2019\u201a\u201b"
DOUBLE_QUOTES = '"\u201c\u201d\u201e'
SMART_QUOTES = SINGLE_QUOTES[1:] + DOUBLE_QUOTES[1:]
DASHES = "-\u2013\u2014\u2015"
PLAIN_SPACE = " \t\r\n"
# What may follow a value that opened its own argument without starting another one
# that the reader would miss: a `{` block is read, and checked, in its own right.
VALUE_ENDS = PLAIN_SPACE + ";|&){},<>]"
# Keywords written against their block, as in `}else{`.
BLOCK_KEYWORDS = ("begin", "catch", "do", "else", "end", "finally", "process", "try")
# A stand-in no shell reading here treats as special or as a space.
PLACEHOLDER = "\ue000"
MAX_DEPTH = 40
# How far back to look from a point in a long word or statement.
LOOK_BACK = 64
# Where the reader is in the value of a `-name:value` word.
NONE, AWAITED, READING, ENDED = range(4)

LONE_CR_RE = re.compile(r"\r(?!\n)")
MEMBER_RE = re.compile(r"(?:\.|::)[A-Za-z_]\w*")
MEMBER_TAIL_RE = re.compile(r"(?:\.|::)[A-Za-z_]\w*$")
# A variable or splat that opens an argument: `$x`, `${a b}`, `$env:x`, `$$`, `$:x`,
# `@x`.
VARIABLE_RE = re.compile(
    r"\$(?:\{[^}`]*\}|\$|[\^:]:?[\w?]*|(?:\w+:(?!:))?[\w?]+)|@(?:\w+:(?!:))?[\w?]+"
)
# A `${name}`, closed or not: the name may hold quotes, separators, and `` `} ``.
BRACED_RE = re.compile(r"\$\{(?:`.|[^`}])*(\})?", re.DOTALL)
# What an expandable here-string body holds that the second reading must rewrite, and
# the `$(` that starts code in it.
HERE_TOKEN_RE = re.compile(r"\$\$|\$\{[^}]*\}?|\$\(")
# The characters that end a parameter name such as `-f`.
PARAMETER_NAME_RE = re.compile(r"[^\s{}();,|&.\[:'\"]*")
# A value that is itself a `-name:` word.
VALUE_PARAMETER_RE = re.compile(rf"[ \t]*[{DASHES}]{PARAMETER_NAME_RE.pattern}:")
# The rest of a bare `-name:` value, and what in it can start another argument.
VALUE_REST_RE = re.compile(r"[^\s;|&)}]*")
VALUE_CUT_RE = re.compile(r"['\"$({]")
# A value that opens with one of these is read as a string or a group.
VALUE_OPENERS = ("'", '"', "(", "{", "$(", "@(", "@{", "@'", '@"')
HERE_OPEN_RE = re.compile(r"[^\S\n]*\n")
# The text before an `=` that makes the here-string after it a value: a statement
# that assigns a variable, or a hashtable key.
ASSIGNED_RE = re.compile(r"\s*\$(?:\w+:)?\w+\s*[-+*/%]?")
HASH_KEY_RE = re.compile(r"\s*\$?\w+\s*")
# A merging redirect such as `>&1`, which ends on its own: `2>&1-x` passes `-x`.
MERGE_RE = re.compile(r">&[0-9]")
DASH_TARGET_RE = re.compile(rf"[ \t]*[{DASHES}]")
ESCAPE_RE = re.compile(r"`(.)", re.DOTALL)
SEPARATOR_RE = re.compile(r"[;|&\n]")
# The next clause written against the block before it, as in `}else{`.
CLAUSE_RE = re.compile(r"(?:else|elseif|catch|finally)(?=[\s({])", re.IGNORECASE)
COMMA_BREAK_RE = re.compile(r", *[\t\r\n]")
# Characters a backtick leaves as themselves, outside the control escapes.
LITERAL_ESCAPE_RE = re.compile(r"[\w./:=-]")


def odd_space(char: str) -> bool:
    return char.isspace() and char not in PLAIN_SPACE


def escaped_text(char: str) -> str:
    """The reading of a backtick before `char`: itself, or `_` filler for the rest."""
    return char if LITERAL_ESCAPE_RE.fullmatch(char) and char not in "0abefnrtv" else "__"


def filler_variable(found: re.Match[str]) -> str:
    """`$$` or a `${name}` as words POSIX reads as one; an unclosed one stays."""
    name = found[0]
    if name == "$$":
        return "__"
    if not name.endswith("}"):
        return name
    return "${" + re.sub(r"[^\w:]", "_", name[2:-1]) + "}"


class _RefusedError(Exception):
    pass


def here_text(body: str) -> str:
    """An expandable here-string body with its variables as `filler_variable` words.

    Past a `$(`, a `${` can be literal text in the subexpression, where rewriting it
    could hide a command, so one that needs rewriting there is refused.
    """
    nested = False

    def reading(found: re.Match[str]) -> str:
        nonlocal nested
        if found[0] == "$(":
            nested = True
            return found[0]
        filled = filler_variable(found)
        if nested and filled != found[0]:
            raise _RefusedError("a variable after a subexpression in a here-string")
        return filled

    return HERE_TOKEN_RE.sub(reading, body)


class _PowerShell:
    """One pass over PowerShell text that tracks strings, comments, and groups.

    `mentions` says whether a piece of text names a guarded CLI. A split only matters
    in a statement that does: `'a'.Length` in any other statement stays allowed.
    """

    def __init__(self, text: str, mentions: Callable[[str], bool]) -> None:
        self.text = text
        self.mentions = mentions
        self.out: list[str] = []
        self.statement = 0
        # Each of these is keyed by the index where a statement starts.
        self.searched: dict[int, int] = {}  # how far its text has been searched
        self.closed: dict[int, int] = {}  # where its last group ended
        self.named: set[int] = set()  # it names a guarded CLI outside its groups
        self.depth = 0
        self.value_end = 0  # how far a `-name:` value has been checked
        self.hash = False  # the innermost group is a hashtable

    def char(self, index: int) -> str:
        return self.text[index] if index < len(self.text) else ""

    def braced(self, i: int) -> tuple[str, int]:
        """Return the reading of the `${name}` at `i` and the index after it.

        One that never closes stays as it is: PowerShell runs nothing then.
        """
        found = BRACED_RE.match(self.text, i)
        if not found[1]:
            return self.text[i:], len(self.text)
        return filler_variable(found), found.end()

    def assigns(self, i: int) -> bool:
        """Whether the `=` before `i` makes the here-string opened at `i` a value."""
        called = self.statement and self.text[self.statement - 1] == "&"
        if called or self.text[i - 1] != "=":
            return False
        pattern = HASH_KEY_RE if self.hash else ASSIGNED_RE
        return bool(pattern.fullmatch(self.text, self.statement, i - 1))

    def split(self, end: int, what: str) -> None:
        """Refuse a split when the current statement names a guarded CLI before `end`."""
        done = self.searched.get(self.statement, self.statement)
        # Search only new text, from far enough back to rejoin a cut name, so the
        # hook stays inside its time limit on a long command.
        if self.mentions(self.text[max(self.statement, done - LOOK_BACK) : end]):
            raise _RefusedError(what)
        self.searched[self.statement] = max(done, end)

    def colon_value(self, start: int) -> None:
        """Refuse a `-name:` value that PowerShell may cut into several arguments.

        `-t:.'y'-f` passes `-t:.`, `y`, and `-f`, and a dash-led value reads
        `${x}` as a script block, so only a plain value or one leading variable passes.
        """
        if start < self.value_end or self.text.startswith(VALUE_OPENERS, start):
            return
        if self.text.startswith(("#", "<"), start):
            self.split(start + 1, "a comment mark as a `-name:` value")
        variable = VARIABLE_RE.match(self.text, start)
        rest = VALUE_REST_RE.match(self.text, variable.end() if variable else start)
        self.value_end = rest.end()
        if VALUE_CUT_RE.search(rest.group(0)):
            self.split(rest.end(), "a quote, variable, or block inside a `-name:` value")

    def code(self, i: int, closer: str = "") -> int:
        """Read code from `i`; return the index of `closer`, or the end of the text."""
        text, out = self.text, self.out
        word: int | None = None  # where the current word started
        after_comma = False
        # The value of a `-name:value` word: none, awaited, being read, or ended.
        colon = NONE
        while i < len(text):
            c = text[i]
            follows = text[i + 1 : i + 2]
            fresh = word is None and not after_comma
            if c == closer:
                return i
            if c in PLAIN_SPACE:
                # A line break after a comma does not end the command.
                if c == "\n" and not after_comma:
                    self.statement, colon = i + 1, NONE
                elif colon == READING:
                    colon = ENDED
                out.append(c)
                word, i = None, i + 1
                continue
            if odd_space(c):
                raise _RefusedError("a space or control character only PowerShell splits at")
            if c in SMART_QUOTES:
                raise _RefusedError("a typographic quote, which PowerShell reads as a quote")
            if c == "`":
                continued = 2 if follows == "\n" else 3 if text[i + 1 : i + 3] == "\r\n" else 0
                if word is None and continued and not after_comma:
                    out.append(" ")
                    i += continued
                    continue
                self.split(i, "a backtick escape")
                out.append(follows if LITERAL_ESCAPE_RE.fullmatch(follows) else "_")
                word, i, after_comma = i if word is None else word, i + 2, False
                continue
            if after_comma and word is None and (c == "#" or (c + follows) == "<#"):
                # Here it is no comment: it joins the next line into one argument.
                self.split(i + 1, "a comment mark after a comma")
            if c == "#" and fresh:
                end = text.find("\n", i)
                i = len(text) if end < 0 else end
                out.append(" ")
                continue
            if c == "<" and follows == "#" and fresh:
                end = text.find("#>", i + 2)
                i = len(text) if end < 0 else end + 2
                out.append(" ")
                continue
            awaited = colon == AWAITED
            if word is None and c != ",":
                colon = {AWAITED: READING, ENDED: NONE}.get(colon, colon)
                if awaited:
                    self.colon_value(i)
            if c == "@" and follows and follows in "'\"" and HERE_OPEN_RE.match(text, i + 2):
                # `$x=@'` and `@{x=@'` open one; elsewhere inside a word the shell
                # may read a plain quote, as in the argument `x=@'`.
                if word is not None and not self.assigns(i):
                    raise _RefusedError("a here-string opener the guard cannot place")
                i = self.after_value(self.here_string(i, follows))
                word, after_comma = None, False
                continue
            if c in "'\"":
                initial = word is None
                i = self.string(i, c)
                if initial:
                    i = self.after_value(i)
                    word = None
                after_comma = False
                continue
            variable = VARIABLE_RE.match(text, i) if word is None else None
            if variable:
                end = variable.end()
                name = variable.group(0)
                if name == "$$" or name.startswith("${"):
                    out.append(filler_variable(variable))
                else:
                    # `$^=gh ...` assigns and runs `gh`; read it like any other variable.
                    out.append("$_" + name[2:] if name[1:2] in ("^", ":") else name)
                after_comma = False
                if text.startswith((".", "[", "::"), end):
                    # PowerShell ends the argument after `$x.y` or `$x[0]`.
                    i = self.after_value(end)
                else:
                    if text.startswith("=", end):
                        # `gh x >$y=z` passes `=z`; a statement may assign `$y=z`.
                        self.split(i, "text joined to a variable")
                    word, i = i, end
                continue
            if c == "$" and follows and follows in "^:":
                out.append("$_")
                word, i, after_comma = i if word is None else word, i + 2, False
                continue
            if c == "$" and follows == "$":
                # `x$${a}` is the word `x$$` and then a script block.
                out.append("__")
                word, i, after_comma = i if word is None else word, i + 2, False
                continue
            if c == "$" and follows == "{":
                filled, end = self.braced(i)
                if "`" in text[i:end]:
                    self.split(end, "a backtick escape")
                out.append(filled)
                word, i, after_comma = i if word is None else word, end, False
                continue
            if c in "({":
                start = i if word is None else word
                tail = text[max(start, i - LOOK_BACK) : i]
                # `x$(...)` and `$s.Trim()` stay inside their word; `@(`, `$(` and a
                # bare group open a value of their own.
                inside = c == "(" and (
                    (tail.endswith("$") and i - start > 1)
                    or (text[start] in "$[" and bool(MEMBER_TAIL_RE.search(tail)))
                )
                opens = tail.lower() in ("", "$", "@", *BLOCK_KEYWORDS)
                if not inside and (i - start > LOOK_BACK or not opens):
                    self.split(i, "text joined to an opening bracket")
                # `((` and `=(` are arithmetic and an array to a POSIX shell, so a
                # group there that names a CLI is set apart to be read as commands.
                slot = None
                if c == "(" and i and text[i - 1] in "(=":
                    slot = len(out)
                    out.append("")
                end = self.group(i, ")" if c == "(" else "}")
                if slot is not None and self.mentions(text[i:end]):
                    out[slot] = "; " if text[i - 1] == "=" else " "
                if inside:
                    i = end
                else:
                    i, word = self.after_value(end), None
                after_comma = False
                continue
            if c in ";|&":
                if not (c == "&" and i and text[i - 1] == ">"):
                    self.statement = i + 1
                out.append(c)
                word, i, after_comma, colon = None, i + 1, False, NONE
                continue
            if c == ",":
                # PowerShell joins these into the argument: `x=,<tab>-f` is one.
                if text[i - 1 : i] == "\t" or COMMA_BREAK_RE.match(text, i):
                    self.split(i + 1, "a tab or line break next to a comma")
                # `-t:x, -f` passes `-t:-f`: each later list item gets the `-t:`.
                if colon in (AWAITED, ENDED) or (colon == READING and follows == " "):
                    self.split(i + 1, "a spaced list after a `-name:value` word")
                out.append(c)
                word, i, after_comma = None, i + 1, True
                continue
            if c == ">" and (word is None or (i - word == 1 and text[word] in "*123456")):
                # A redirect operator: what follows opens its own argument.
                merge = MERGE_RE.match(text, i)
                target = not merge and DASH_TARGET_RE.match(text, i + 1)
                if target:
                    # `2>-a:-f` redirects to `-a:` and passes `-f`.
                    self.split(target.end(), "a redirect target that starts with a dash")
                # `>& gh ...` runs `gh`; the space makes the POSIX reading refuse it.
                spaced = follows in ("&", "|")
                out.append(f"{merge.group(0)} " if merge else c + " " * spaced)
                word, after_comma = None, not merge
                i = merge.end() if merge else i + 1
                continue
            # `]x`, `.$x`, `.'x'`, `$'x'` and `@$x` pass two arguments.
            if word is None and (
                (c == "]" and follows and follows not in PLAIN_SPACE + ";|&)}")
                or (c == "." and follows and follows in "$'\"")
                or (c == "$" and follows and follows in "'\"")
                or (c == "@" and follows == "$")
            ):
                self.split(i + 1, "text joined to a leading punctuation mark")
            if word is None and c in DASHES and re.match(r"[^\W\d]|\?", follows):
                end = PARAMETER_NAME_RE.match(text, i + 1).end()
                mark = self.char(end)
                value = self.char(end + 1)
                quoted = bool(value) and value in "'\""
                if mark and mark in "({":
                    # `-q${x}-f` passes `-q$`, a script block, and `-f`.
                    self.split(end + 1, "a block written against a one-dash word")
                elif mark == "." and (
                    (value and value in "$({'\"") or text.startswith("@(", end + 1)
                ):
                    # `-q.$x.y-f` passes `-q`, `.`, and `-f`.
                    self.split(end + 2, "a value after a dot in a one-dash word")
                elif mark == ":":
                    if after_comma:
                        # `a,-t:-f` passes `a,-t:` and `-f`.
                        self.split(end + 1, "a `-name:value` word after a comma")
                    nested = VALUE_PARAMETER_RE.match(text, end + 1)
                    if awaited or nested:
                        # `-t:-u:-f` passes `-t:-u:` and `-f`; `-t:-t:y` passes `y`.
                        last = nested.end() if nested else end + 1
                        self.split(last, "a `-name:` word as the value of another")
                    colon = AWAITED if value and value in PLAIN_SPACE else READING
                    if colon == READING:
                        self.colon_value(end + 1)
                    if quoted or (value and value in "$@"):
                        # What follows the colon opens an argument of its own.
                        out.append(re.sub("[#<>]", "_", text[i : end + 1]))
                        i = end + 1
                        if quoted:
                            i = self.after_value(self.string(i, value))
                        word, after_comma = None, False
                        continue
            if c == "-" and fresh and text.startswith("--%", i):
                self.split(i + 3, "the stop-parsing token")
            # PowerShell keeps `#`, `<`, `>`, and the `$` before a quote here as text; to
            # POSIX they hide words or change how a quote reads.
            literal = c in "#<>" or (c == "$" and follows and follows in "'\"")
            out.append("_" if literal else c)
            word, i, after_comma = i if word is None else word, i + 1, False
        return i

    def group(self, i: int, closer: str) -> int:
        """Read a `(`, `{`, or `[` group opened at `i`; return the index after it."""
        self.depth += 1
        if self.depth > MAX_DEPTH:
            raise _RefusedError("groups nested too deeply to read")
        outer, in_hash = self.statement, self.hash
        # Whether the statement names a guarded CLI outside its earlier groups.
        if self.mentions(self.text[max(outer, self.closed.get(outer, 0)) : i]):
            self.named.add(outer)
        self.out.append(self.text[i])
        self.statement = i + 1
        self.hash = self.text[max(i - 1, 0) : i + 1] == "@{"
        end = self.code(i + 1, closer)
        self.statement, self.hash = outer, in_hash
        self.closed[outer] = end + 1
        self.depth -= 1
        # `gh x {;} -f` passes `-f` to gh; POSIX ends the command at the `;`.
        if (
            outer in self.named
            and self.text[i - 1] != "$"
            and SEPARATOR_RE.search(self.text, i + 1, end)
        ):
            raise _RefusedError("a separator inside a block in a guarded command")
        if end >= len(self.text):
            return end
        self.out.append(closer)
        return end + 1

    def string(self, i: int, quote: str) -> int:
        """Read the quoted string opened at `i`; return the index after it."""
        text, out = self.text, self.out
        family = SINGLE_QUOTES if quote == "'" else DOUBLE_QUOTES
        out.append(quote)
        i += 1
        while i < len(text):
            c = text[i]
            if c == quote:
                out.append(quote)
                if self.char(i + 1) == quote:
                    out.append(quote)
                    i += 2
                    continue
                return i + 1
            if c in family:
                raise _RefusedError("a typographic quote that ends a PowerShell string")
            if quote == '"' and c == "`":
                if text[i + 1 : i + 3] == "u{":
                    self.split(i + 3, "a Unicode escape")
                out.append(escaped_text(self.char(i + 1)))
                i += 2
                continue
            if quote == '"' and c == "$" and self.char(i + 1) == "$":
                out.append("__")
                i += 2
                continue
            if quote == '"' and c == "$" and self.char(i + 1) == "{":
                filled, i = self.braced(i)
                out.append(filled)
                continue
            if quote == '"' and c == "$" and self.char(i + 1) == "(":
                out.append("$")
                if self.char(i + 2) == "(":
                    out.append("(")
                    slot = len(out)
                    out.append("")
                    end = self.group(i + 2, ")")
                    if self.mentions(self.text[i + 2 : end]):
                        out[slot] = " "
                    self.out.append(")")
                    i = end + (self.char(end) == ")")
                else:
                    i = self.group(i + 1, ")")
                continue
            out.append(c)
            i += 1
        return i

    def here_string(self, i: int, quote: str) -> int:
        """Read the here-string opened at `i`; its body is data, not quoting."""
        family = SINGLE_QUOTES if quote == "'" else DOUBLE_QUOTES
        close = re.compile(rf"\n[{family}]@").search(self.text, i + 2)
        if close is None:
            self.out.append(self.text[i:])
            return len(self.text)
        _, _, body = self.text[i + 2 : close.start()].partition("\n")
        body = body.removesuffix("\r")
        # A here-string can be an argument, so the reading keeps its value.
        if quote == "'":
            joined = body.replace("'", "'\"'\"'")
            self.out.append(f"'{joined}'")
        else:
            if "`u{" in body:
                self.split(close.end(), "a Unicode escape")
            # `$(...)` in the body still runs, so it stays inside double quotes.
            text = ESCAPE_RE.sub(lambda m: escaped_text(m[1]), body.replace('"', "_"))
            self.out.append(f'"{here_text(text)}"')
        return close.end()

    def after_value(self, i: int) -> int:
        """After a value that opened its own argument, refuse text joined onto it."""
        chained = False
        while i < len(self.text):
            member = MEMBER_RE.match(self.text, i)
            if member:
                self.out.append(member.group(0))
                i, chained = member.end(), True
            elif self.text[i] == "[" or (chained and self.text[i] == "("):
                i = self.group(i, "]" if self.text[i] == "[" else ")")
            else:
                clause = self.text[i - 1] == "}" and CLAUSE_RE.match(self.text, i)
                if self.text[i] not in VALUE_ENDS and not clause:
                    self.split(i, "text joined to a closing quote or bracket")
                if self.text[i] in "{]":
                    # `'a']` and `'a'{}` pass two arguments.
                    self.out.append(" ")
                break
        return i


def read(
    raw: str, powershell: bool, mentions: Callable[[str], bool]
) -> tuple[str | None, str]:
    """Return (reason to refuse, the shell's reading) for a command naming a guarded CLI."""
    if "\0" in raw:
        return "a NUL character", raw
    if LONE_CR_RE.search(raw):
        return "a carriage return without a line feed", raw
    if not powershell:
        return None, "".join(PLACEHOLDER if odd_space(c) else c for c in raw)
    reader = _PowerShell(raw, mentions)
    try:
        reader.code(0)
    except _RefusedError as refused:
        return str(refused), raw
    return None, "".join(reader.out)
