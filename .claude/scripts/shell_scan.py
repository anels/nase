#!/usr/bin/env python3
"""Shared shell command scanner for the external-write and git guards.

Both guards used to carry their own hand-rolled bash parsers with different wrapper
lists, so every bypass had to be closed twice and each parser had its own blind spots.
This module is the one parser. It turns a command string into the list of programs that
string would run, with quotes resolved, and says plainly when it could not tell.

    from shell_scan import scan
    result = scan("timeout 5 gh pr merge 1")
    result.invocations[0].argv      # ['gh', 'pr', 'merge', '1']
    result.invocations[0].wrappers  # ('timeout',)

What it understands: `; && || | |& &` and newlines, `( )` subshells, `{ }` groups, `!`,
the compound keywords (if/for/while/case/function/[[ ]]/(( ))), `VAR=val` prefixes, the
usual command wrappers with their value-taking options, `bash -c`, `eval`, `$( )`,
backticks, process substitution, heredocs (quoted body is data, unquoted body is scanned
for substitutions), here-strings, and a pipe whose right side is a shell. Simple
`VAR=literal` assignments are tracked so `G=git; $G push` resolves.

What it does not do: run anything, expand globs, follow functions or aliases, or see a
program name built by a substitution. Those come back as `dynamic` so a caller can fail
closed. Unparseable input sets `unparseable` and still returns what was read before the
failure, because a shell runs the commands that precede a syntax error.

Stdlib only, Python 3.10+.
"""

from __future__ import annotations

import fnmatch
import posixpath
import re
import shlex
import signal
import sys
from dataclasses import dataclass, field

SHELLS = frozenset({"bash", "sh", "zsh", "dash", "ksh"})
MAX_DEPTH = 12
# A tracked variable longer than this is treated as dynamic, so `A=$A$A` repeated cannot
# grow memory without bound.
MAX_VAR_LEN = 4096
# A guard that hangs is not a guard: a hook that times out exits with a status Claude Code
# lets through. SIGALRM ends the process, which every caller reads as a failed scan.
SCAN_TIMEOUT_SECONDS = 5
XARGS_INPUT = "<xargs-input>"

# Provenance names that mean "text that is itself run as a shell script". A construct the
# parser cannot bind inside one of these is unbound for real; the same construct at the
# top level can still be bound by the caller's own rules.
SCRIPT_VIAS = frozenset(
    {
        "shell-c",
        "eval",
        "env-S",
        "sudo-shell",
        "watch",
        "flock-c",
        "su-c",
        "trap",
        "pipe-to-shell",
        "here-string",
    }
)

_NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_ASSIGN_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\+?=")
_KEYWORDS = frozenset(
    {"if", "then", "elif", "else", "fi", "while", "until", "do", "done", "{", "}", "!"}
)
_OPEN_KEYWORDS = frozenset({"{", "do", "then"})
# Global git options that take the next word as their value.
_GIT_VALUE_OPTIONS = frozenset(
    {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix",
     "--attr-source", "--config-env"}
)
_CLOSE_KEYWORDS = frozenset({"}", "done", "fi"})
_CASE_STOPS = frozenset({";;", ";&", ";;&", "esac"})
_SPECIAL_PARAMS = "@*#?-$!0123456789"
_DECL_BUILTINS = frozenset({"export", "declare", "typeset", "local", "readonly"})
_READ_BUILTINS = frozenset({"read", "mapfile", "readarray", "getopts"})
_BLANKS = " \t\r"
_OPERATOR_CHARS = " \t\r\n;&|()<>"


@dataclass
class Invocation:
    """One program run: `argv` with quotes resolved and `dyn` flagging unresolved words."""

    argv: list[str]
    dyn: list[bool]
    glob: list[bool] = field(default_factory=list)
    via: tuple[str, ...] = ()
    wrappers: tuple[str, ...] = ()
    env: dict[str, str] = field(default_factory=dict)
    env_dynamic: frozenset[str] = frozenset()
    cwds: tuple[str, ...] = ("",)
    stdin: str = ""
    script_stdin: bool = False
    function_call: bool = False

    @property
    def name(self) -> str:
        return posixpath.basename(self.argv[0]) if self.argv else ""

    @property
    def head_dynamic(self) -> bool:
        return bool(self.dyn and self.dyn[0])

    @property
    def dynamic(self) -> bool:
        return any(self.dyn)

    def is_shell(self) -> bool:
        return self.name.lower() in SHELLS

    def may_be(self, program: str) -> bool:
        """True when the program run could be `program`, including names the shell expands.

        A head like `$X`, `{g,h}it` or `/usr/bin/g?t` is not `git` as written but may be
        once the shell has expanded it. A dynamic head whose basename is plainly something
        else (`$ROOT/bin/deploy`) is not a candidate. A call to a function the same command
        defined is one too, because its body may forward `"$@"` to the program.
        """
        name = self.name
        if name.lower() == program or self.function_call:
            return True
        if self.glob and self.glob[0] and fnmatch.fnmatchcase(program, name):
            return True
        return self.head_dynamic and any(ch in name for ch in "$`{(")

    def as_dict(self) -> dict[str, object]:
        return {
            "argv": self.argv,
            "dyn": self.dyn,
            "glob": self.glob,
            "dynamic": self.dynamic,
            "head_dynamic": self.head_dynamic,
            "via": list(self.via),
            "wrappers": list(self.wrappers),
            "env": self.env,
            "env_dynamic": sorted(self.env_dynamic),
            "cwds": list(self.cwds),
            "stdin": self.stdin,
            "script_stdin": self.script_stdin,
            "function_call": self.function_call,
        }


@dataclass
class ScanResult:
    invocations: list[Invocation] = field(default_factory=list)
    unparseable: bool = False
    events: list[tuple[str, tuple[str, ...]]] = field(default_factory=list)
    visible_text: str = ""

    @property
    def top_opaque(self) -> set[str]:
        """Constructs run outside any nested script that could not be bound statically."""
        return {
            kind
            for kind, via in self.events
            if not SCRIPT_VIAS.intersection(via) and "heredoc-body" not in via
        }

    @property
    def nested_opaque(self) -> set[str]:
        """Constructs inside a string that is itself run as a script."""
        return {kind for kind, via in self.events if SCRIPT_VIAS.intersection(via)}


class _Word:
    __slots__ = ("assign_end", "dyn", "expand", "glob", "quoted", "text")

    def __init__(self, text: str = "", dyn: bool = False, quoted: bool = False) -> None:
        self.text = text
        self.dyn = dyn
        self.quoted = quoted
        self.assign_end = -1
        self.expand: list[str] | None = None
        self.glob = False


class _Heredoc:
    __slots__ = ("body", "delim", "feeds_shell", "quoted", "span", "strip")

    def __init__(self, delim: str, quoted: bool, strip: bool) -> None:
        self.delim = delim
        self.quoted = quoted
        self.strip = strip
        self.body: str | None = None
        self.feeds_shell = False
        self.span: tuple[int, int] = (0, 0)


class _Cmd:
    __slots__ = ("assigns", "heredocs", "herestrings", "piped", "procsub_stdin", "stdin", "words")

    def __init__(self, piped: bool = False) -> None:
        self.words: list[_Word] = []
        self.assigns: list[_Word] = []
        self.heredocs: list[_Heredoc] = []
        self.herestrings: list[_Word] = []
        self.stdin = ""
        self.procsub_stdin = False
        self.piped = piped

    @property
    def has_content(self) -> bool:
        return bool(self.words or self.assigns or self.heredocs or self.herestrings)


class _Ctx:
    """Shell state a nested scope inherits and may change without affecting its parent."""

    __slots__ = ("cwds", "env", "vars")

    def __init__(
        self,
        cwds: tuple[str, ...] = ("",),
        variables: dict[str, str | None] | None = None,
        env: dict[str, tuple[str, bool]] | None = None,
    ) -> None:
        self.cwds = cwds
        self.vars = variables if variables is not None else {}
        self.env = env if env is not None else {}

    def fork(self) -> _Ctx:
        return _Ctx(self.cwds, dict(self.vars), dict(self.env))


class _Scan:
    """State shared by every parser one `scan()` call creates."""

    def __init__(self) -> None:
        self.invocations: list[Invocation] = []
        self.unparseable = False
        self.events: list[tuple[str, tuple[str, ...]]] = []
        # Text a later `| bash` could be reading: each earlier word, plus heredoc bodies.
        self.lits: list[str | _Heredoc] = []
        self.cuts: list[tuple[int, int]] = []
        self.functions: set[str] = set()


@dataclass(frozen=True)
class _Spec:
    sv: str = ""
    so: str = ""
    lv: frozenset[str] = frozenset()
    dl: frozenset[str] = frozenset()
    assign: bool = False
    pos: int = 0


_SUDO_LONG = frozenset(
    {
        "--chdir",
        "--chroot",
        "--close-from",
        "--command-timeout",
        "--group",
        "--host",
        "--other-user",
        "--prompt",
        "--role",
        "--type",
        "--user",
    }
)
_XARGS_LONG = frozenset(
    {
        "--arg-file",
        "--delimiter",
        "--eof",
        "--max-args",
        "--max-chars",
        "--max-lines",
        "--max-procs",
        "--process-slot-var",
        "--replace",
    }
)
_WRAPPERS: dict[str, _Spec] = {
    "builtin": _Spec(),
    "exec": _Spec(sv="a"),
    "env": _Spec(
        sv="aCPSu",
        lv=frozenset(
            {
                "--argv0",
                "--block-signal",
                "--chdir",
                "--default-signal",
                "--ignore-signal",
                "--split-string",
                "--unset",
            }
        ),
        assign=True,
    ),
    "sudo": _Spec(sv="CDghpRrTtUu", lv=_SUDO_LONG, assign=True),
    "doas": _Spec(sv="uC", assign=True),
    "nohup": _Spec(),
    "nice": _Spec(sv="n", lv=frozenset({"--adjustment"})),
    "ionice": _Spec(sv="cnpPu", lv=frozenset({"--class", "--classdata", "--pid"})),
    "timeout": _Spec(sv="sk", lv=frozenset({"--kill-after", "--signal"}), pos=1),
    "stdbuf": _Spec(sv="ioe", lv=frozenset({"--error", "--input", "--output"})),
    "setsid": _Spec(),
    "time": _Spec(sv="fo", lv=frozenset({"--format", "--output"})),
    "xargs": _Spec(sv="aEdIJLnPRs", so="eil", lv=_XARGS_LONG),
    "arch": _Spec(),
    "xcrun": _Spec(
        lv=frozenset({"--sdk", "--toolchain", "--log"}),
        dl=frozenset({"-sdk", "-toolchain", "-log"}),
    ),
    "flock": _Spec(sv="wEc", lv=frozenset({"--wait", "--timeout", "--conflict-exit-code"}), pos=1),
    "caffeinate": _Spec(sv="tw"),
    "unbuffer": _Spec(),
    "watch": _Spec(sv="ndwp", lv=frozenset({"--interval", "--differences"})),
}


def _ansi_decode(text: str) -> str:
    simple = {
        "a": "\a",
        "b": "\b",
        "e": "\x1b",
        "E": "\x1b",
        "f": "\f",
        "n": "\n",
        "r": "\r",
        "t": "\t",
        "v": "\v",
        "\\": "\\",
        "'": "'",
        '"': '"',
        "?": "?",
    }
    out: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c != "\\" or i + 1 >= n:
            out.append(c)
            i += 1
            continue
        nxt = text[i + 1]
        if nxt in simple:
            out.append(simple[nxt])
            i += 2
            continue
        if nxt in "xuU":
            width = {"x": 2, "u": 4, "U": 8}[nxt]
            match = re.match(f"[0-9a-fA-F]{{1,{width}}}", text[i + 2 :])
            if match:
                code = int(match.group(0), 16)
                if code:
                    out.append(chr(code) if code < 0x110000 else "")
                i += 2 + len(match.group(0))
                continue
        if nxt in "01234567":
            match = re.match(r"[0-7]{1,3}", text[i + 1 :])
            if match:
                code = int(match.group(0), 8) & 0xFF
                if code:
                    out.append(chr(code))
                i += 1 + len(match.group(0))
                continue
        if nxt == "c" and i + 2 < n:
            out.append(chr(ord(text[i + 2].upper()) ^ 0x40))
            i += 3
            continue
        out.append("\\" + nxt)
        i += 2
    return "".join(out)


def _join_dir(base: str, path: str) -> str:
    if base == "?":
        return "?"
    if path.startswith("/"):
        return posixpath.normpath(path)
    joined = posixpath.normpath(posixpath.join(base or ".", path))
    return "" if joined == "." else joined


class _Parser:
    def __init__(
        self,
        text: str,
        scan: _Scan,
        ctx: _Ctx,
        depth: int,
        via: tuple[str, ...],
        root: bool,
    ) -> None:
        self.t = text
        self.n = len(text)
        self.i = 0
        self.scan = scan
        self.ctx = ctx
        self.depth = depth
        self.via = via
        self.root = root
        self.pending: list[_Heredoc] = []
        self.cmd = _Cmd()
        self.group_piped = False
        self.in_pipe = False
        self.pipe_saved: tuple[str, ...] = ("",)
        self.pipe_start = len(scan.lits)
        self.kw_depth = 0

    # ----- small helpers -------------------------------------------------------------

    def _fail(self) -> None:
        self.scan.unparseable = True

    def _event(self, kind: str) -> None:
        self.scan.events.append((kind, self.via))

    def _skip_blank(self) -> None:
        t, n = self.t, self.n
        while self.i < n:
            c = t[self.i]
            if c in _BLANKS:
                self.i += 1
            elif c == "\\" and self.i + 1 < n and t[self.i + 1] == "\n":
                self.i += 2
            else:
                break

    def _nested(self, text: str, via_name: str) -> None:
        if self.depth >= MAX_DEPTH:
            self._fail()
            return
        sub = _Parser(
            text, self.scan, self.ctx.fork(), self.depth + 1, (*self.via, via_name), False
        )
        sub.parse_list()

    # ----- substitutions -------------------------------------------------------------

    def _cmd_subst(self, i: int, counts: bool = True, via_name: str = "subst") -> int:
        """Parse `$( ... )` or `<( ... )` whose `(` is at i+1; return the index after `)`."""
        if counts:
            self._event("substitution")
        if self.depth >= MAX_DEPTH:
            self._fail()
            return self.n
        sub = _Parser(
            self.t,
            self.scan,
            self.ctx.fork(),
            self.depth + 1,
            (*self.via, via_name),
            self.root,
        )
        sub.i = i + 2
        if sub.parse_list(frozenset({")"})) != ")":
            self._fail()
        return sub.i

    def _backtick(self, i: int) -> int:
        """Parse a backtick body starting at i; return the index after the closing one."""
        t, n = self.t, self.n
        j = i + 1
        while j < n and t[j] != "`":
            j += 2 if t[j] == "\\" else 1
        if j >= n:
            self._fail()
            return n
        body = re.sub(r"\\([`\\$])", r"\1", t[i + 1 : j])
        self._event("substitution")
        self._nested(body, "subst")
        return j + 1

    def _match_legacy_arith(self, i: int) -> int:
        """Return the index after the `]` closing a legacy `$[` arithmetic whose `[` is at i, or -1."""
        t, n = self.t, self.n
        j = i + 1
        depth = 1
        while j < n:
            c = t[j]
            if c == "\\":
                j += 2
                continue
            if c in "'\"":
                k = t.find(c, j + 1)
                if k < 0:
                    return -1
                j = k + 1
                continue
            if c == "[":
                depth += 1
            elif c == "]":
                depth -= 1
                if depth == 0:
                    return j + 1
            j += 1
        return -1

    def _match_arith(self, i: int) -> int:
        """Return the index after the `))` closing an arithmetic `((` at i, or -1."""
        t, n = self.t, self.n
        j = i + 2
        depth = 2
        while j < n:
            c = t[j]
            if c == "\\":
                j += 2
                continue
            if c in "'\"":
                k = t.find(c, j + 1)
                if k < 0:
                    return -1
                j = k + 1
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 1 and not (j + 1 < n and t[j + 1] == ")"):
                    return -1
                if depth == 0:
                    return j + 1
            j += 1
        return -1

    def _scan_subs(self, text: str, via_name: str) -> None:
        """Find substitutions in text that a shell expands but does not run as a script."""
        if self.depth >= MAX_DEPTH:
            self._fail()
            return
        sub = _Parser(
            text, self.scan, self.ctx.fork(), self.depth + 1, (*self.via, via_name), False
        )
        sub._walk_subs()

    def _walk_subs(self) -> None:
        t, n = self.t, self.n
        while self.i < n:
            c = t[self.i]
            if c == "\\":
                self.i += 2
            elif c == "`":
                self.i = self._backtick(self.i)
            elif c == "$" and t.startswith("$((", self.i):
                end = self._match_arith(self.i + 1)
                if end < 0:
                    self.i = self._cmd_subst(self.i)
                else:
                    self._scan_subs(t[self.i + 3 : end - 2], "arith")
                    self.i = end
            elif c == "$" and t.startswith("$(", self.i):
                self.i = self._cmd_subst(self.i)
            else:
                self.i += 1

    # ----- words ---------------------------------------------------------------------

    def _dollar(self, parts: list[str], w: _Word, in_dq: bool, at_start: bool) -> None:
        t, n = self.t, self.n
        i = self.i
        nxt = t[i + 1] if i + 1 < n else ""
        if nxt == "'" and not in_dq:
            j = i + 2
            while j < n and t[j] != "'":
                j += 2 if t[j] == "\\" else 1
            if j >= n:
                self._fail()
                parts.append(_ansi_decode(t[i + 2 :]))
                self.i = n
            else:
                parts.append(_ansi_decode(t[i + 2 : j]))
                self.i = j + 1
            w.quoted = True
            return
        if nxt == '"' and not in_dq:
            self.i += 1
            return
        if nxt == "(":
            if t.startswith("$((", i):
                end = self._match_arith(i + 1)
                if end >= 0:
                    self._scan_subs(t[i + 3 : end - 2], "arith")
                    parts.append(t[i:end])
                    w.dyn = True
                    self.i = end
                    return
            end = self._cmd_subst(i)
            parts.append(t[i:end])
            w.dyn = True
            self.i = end
            return
        if nxt == "[":
            end = self._match_legacy_arith(i + 1)
            if end < 0:
                self._fail()
                end = n
            else:
                self._scan_subs(t[i + 2 : end - 1], "arith")
            parts.append(t[i:end])
            w.dyn = True
            self.i = end
            return
        if nxt == "{":
            end = self._brace_param(i)
            raw = t[i:end]
            inner = raw[2:-1] if raw.endswith("}") else ""
            self._resolve_var(parts, w, raw, inner, in_dq, at_start, end)
            self.i = end
            return
        match = _NAME_RE.match(t, i + 1)
        if match:
            end = match.end()
            self._resolve_var(parts, w, t[i:end], match.group(0), in_dq, at_start, end)
            self.i = end
            return
        if nxt and nxt in _SPECIAL_PARAMS:
            parts.append(t[i : i + 2])
            w.dyn = True
            self.i = i + 2
            return
        parts.append("$")
        self.i = i + 1

    def _resolve_var(
        self,
        parts: list[str],
        w: _Word,
        raw: str,
        name: str,
        in_dq: bool,
        at_start: bool,
        end: int,
    ) -> None:
        value = self.ctx.vars.get(name) if _NAME_RE.fullmatch(name) else None
        if value is not None and len(value) > MAX_VAR_LEN:
            value = None
        if value is None:
            parts.append(raw)
            w.dyn = True
            return
        parts.append(value)
        whole = at_start and not in_dq and (end >= self.n or self.t[end] in _OPERATOR_CHARS)
        if whole:
            w.expand = value.split()

    def _brace_param(self, i: int) -> int:
        """Return the index after the `}` closing `${` at i, parsing substitutions inside."""
        t, n = self.t, self.n
        j = i + 2
        depth = 1
        while j < n:
            c = t[j]
            if c == "\\":
                j += 2
            elif c == "'":
                k = t.find("'", j + 1)
                if k < 0:
                    break
                j = k + 1
            elif c == "`":
                j = self._backtick(j)
            elif c == "$" and t.startswith("${", j):
                depth += 1
                j += 2
            elif c == "$" and t.startswith("$((", j):
                end = self._match_arith(j + 1)
                j = end if end >= 0 else self._cmd_subst(j)
            elif c == "$" and t.startswith("$(", j):
                j = self._cmd_subst(j)
            elif c == "}":
                depth -= 1
                j += 1
                if depth == 0:
                    return j
            else:
                j += 1
        self._fail()
        return n

    def _read_dquote(self, parts: list[str], w: _Word) -> None:
        t, n = self.t, self.n
        self.i += 1
        w.quoted = True
        buf: list[str] = []
        while self.i < n:
            c = t[self.i]
            if c == '"':
                self.i += 1
                parts.append("".join(buf))
                return
            if c == "\\" and self.i + 1 < n:
                nxt = t[self.i + 1]
                if nxt == "\n":
                    self.i += 2
                elif nxt in '$`"\\':
                    buf.append(nxt)
                    self.i += 2
                else:
                    buf.append("\\")
                    self.i += 1
                continue
            if c == "$":
                tmp: list[str] = []
                self._dollar(tmp, w, True, False)
                buf.append("".join(tmp))
                continue
            if c == "`":
                end = self._backtick(self.i)
                buf.append(t[self.i : end])
                w.dyn = True
                self.i = end
                continue
            buf.append(c)
            self.i += 1
        self._fail()
        parts.append("".join(buf))

    def _brace_expansion_at(self, i: int) -> bool:
        t, n = self.t, self.n
        depth = 0
        comma = False
        j = i
        while j < n:
            c = t[j]
            if c in " \t\r\n;&|()<>":
                return False
            if c == "\\":
                j += 2
                continue
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    return comma or ".." in t[i:j]
            elif c == "," and depth == 1:
                comma = True
            j += 1
        return False

    def _read_word(self) -> _Word:
        t, n = self.t, self.n
        parts: list[str] = []
        w = _Word()
        start = self.i
        first_special = -1
        while self.i < n:
            c = t[self.i]
            if c in _OPERATOR_CHARS:
                if c in "<>" and t.startswith("(", self.i + 1):
                    end = self._cmd_subst(self.i + 0, counts=False, via_name="proc-subst")
                    parts.append(t[self.i : end])
                    w.dyn = True
                    self.i = end
                    continue
                if c == "(" and re.fullmatch(r"[A-Za-z_]\w*\+?=", "".join(parts)):
                    end = self._skip_array(self.i)
                    parts.append(t[self.i : end])
                    w.dyn = True
                    self.i = end
                    continue
                break
            if c == "\\":
                if self.i + 1 < n:
                    if t[self.i + 1] == "\n":
                        self.i += 2
                        continue
                    if first_special < 0:
                        first_special = len("".join(parts))
                    parts.append(t[self.i + 1])
                    w.quoted = True
                    self.i += 2
                else:
                    parts.append("\\")
                    self.i += 1
                continue
            if c == "'":
                if first_special < 0:
                    first_special = len("".join(parts))
                end = t.find("'", self.i + 1)
                w.quoted = True
                if end < 0:
                    self._fail()
                    parts.append(t[self.i + 1 :])
                    self.i = n
                    break
                parts.append(t[self.i + 1 : end])
                self.i = end + 1
                continue
            if c == '"':
                if first_special < 0:
                    first_special = len("".join(parts))
                self._read_dquote(parts, w)
                continue
            if c == "$":
                if first_special < 0:
                    first_special = len("".join(parts))
                before = self.i
                self._dollar(parts, w, False, self.i == start)
                if self.i == before:
                    self.i += 1
                continue
            if c == "`":
                if first_special < 0:
                    first_special = len("".join(parts))
                end = self._backtick(self.i)
                parts.append(t[self.i : end])
                w.dyn = True
                self.i = end
                continue
            if c == "{" and self._brace_expansion_at(self.i):
                w.dyn = True
            elif c in "*?" or (c == "[" and "]" in t[self.i + 1 : self.i + 80].split(" ")[0]):
                w.glob = True
            parts.append(c)
            self.i += 1
        w.text = "".join(parts)
        match = _ASSIGN_RE.match(w.text)
        if match and (first_special < 0 or match.end() <= first_special):
            w.assign_end = match.end()
        if w.expand is not None and (len(w.expand) != 1 or w.quoted):
            w.expand = w.expand if not w.quoted else None
        return w

    def _skip_array(self, i: int) -> int:
        t, n = self.t, self.n
        j = i + 1
        depth = 1
        while j < n:
            c = t[j]
            if c == "\\":
                j += 2
                continue
            if c in "'\"":
                k = t.find(c, j + 1)
                if k < 0:
                    break
                j = k + 1
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    self._scan_subs(t[i + 1 : j], "array")
                    return j + 1
            j += 1
        self._fail()
        return n

    # ----- redirects -----------------------------------------------------------------

    def _read_redirect(self) -> None:
        t = self.t
        cmd = self.cmd
        if t.startswith("<<<", self.i):
            self.i += 3
            self._skip_blank()
            cmd.herestrings.append(self._read_word())
            cmd.stdin = "herestring"
            return
        if t.startswith("<<", self.i):
            strip = t.startswith("<<-", self.i)
            self.i += 3 if strip else 2
            self._skip_blank()
            delim = self._read_word()
            heredoc = _Heredoc(delim.text, delim.quoted, strip)
            cmd.heredocs.append(heredoc)
            cmd.stdin = "heredoc"
            self.pending.append(heredoc)
            return
        simple_input = False
        if t.startswith("&>>", self.i):
            self.i += 3
        elif t.startswith("&>", self.i) or t.startswith(">>", self.i) or t.startswith(">|", self.i):
            self.i += 2
        elif t.startswith(("<&", "<>", ">&"), self.i):
            self.i += 2
            if t[self.i - 2 : self.i] == "<>":
                cmd.stdin = cmd.stdin or "file"
        else:
            simple_input = t[self.i] == "<"
            if simple_input:
                cmd.stdin = cmd.stdin or "file"
            self.i += 1
        self._skip_blank()
        if self.i < self.n and (
            t[self.i] not in ";&|()<>\n" or t.startswith(("<(", ">("), self.i)
        ):
            target = self._read_word()
            if simple_input and target.text.startswith("<("):
                cmd.procsub_stdin = True

    def _read_heredoc_bodies(self) -> None:
        t, n = self.t, self.n
        for heredoc in self.pending:
            start = self.i
            lines: list[str] = []
            while self.i < n:
                eol = t.find("\n", self.i)
                end = n if eol < 0 else eol
                line = t[self.i : end]
                self.i = n if eol < 0 else eol + 1
                if line.strip() == heredoc.delim:
                    break
                lines.append(line)
            heredoc.span = (start, self.i)
            heredoc.body = "\n".join(lines)
            if heredoc.strip:
                heredoc.body = "\n".join(line.lstrip("\t") for line in lines)

    def _process_heredocs(self) -> None:
        for heredoc in self.pending:
            body = heredoc.body or ""
            if heredoc.feeds_shell:
                self._nested(body, "heredoc")
                continue
            if self.root and heredoc.span[1] > heredoc.span[0]:
                self.scan.cuts.append(heredoc.span)
            if not heredoc.quoted:
                self._scan_subs(body, "heredoc-body")
        self.pending = []

    # ----- command lists -------------------------------------------------------------

    def parse_list(self, stop: frozenset[str] = frozenset()) -> str:
        """Parse commands until EOF or a `stop` token; return the token that ended it."""
        t = self.t
        self.cmd = _Cmd(piped=self.group_piped)
        while True:
            self._skip_blank()
            if self.i >= self.n:
                self._end("")
                self._finish_heredocs()
                return ""
            c = t[self.i]
            if c == "#":
                eol = t.find("\n", self.i)
                self.i = self.n if eol < 0 else eol
                continue
            if c == "\n":
                self.i += 1
                if self.pending:
                    self._read_heredoc_bodies()
                self._end("\n")
                self._process_heredocs()
                continue
            if c == ";":
                closer = next(
                    (s for s in (";;&", ";;", ";&") if t.startswith(s, self.i)), ";"
                )
                self.i += len(closer)
                if closer in stop:
                    self._end("")
                    self._finish_heredocs()
                    return closer
                self._end(";")
                continue
            if c == "&":
                if t.startswith("&>", self.i):
                    self._read_redirect()
                elif t.startswith("&&", self.i):
                    self.i += 2
                    self._end("&&")
                else:
                    self.i += 1
                    self._end("&")
                continue
            if c == "|":
                if t.startswith("||", self.i):
                    self.i += 2
                    self._end("||")
                elif t.startswith("|&", self.i):
                    self.i += 2
                    self._end("|&")
                else:
                    self.i += 1
                    self._end("|")
                continue
            if c == ")":
                self.i += 1
                if ")" in stop:
                    self._end("")
                    self._finish_heredocs()
                    return ")"
                self._end(";")
                if self.depth == 0 and not stop:
                    self._fail()
                continue
            if c == "(":
                self._open_paren()
                continue
            if c in "<>" and not t.startswith("(", self.i + 1):
                self._read_redirect()
                continue
            word = self._read_word()
            if (
                word.text.isdigit()
                and not word.quoted
                and self.i < self.n
                and t[self.i] in "<>"
                and not t.startswith("(", self.i + 1)
            ):
                continue
            if self._handle_word(word, stop):
                self._end("")
                self._finish_heredocs()
                return "esac"

    def _finish_heredocs(self) -> None:
        if self.pending:
            self._read_heredoc_bodies()
            self._process_heredocs()

    def _open_paren(self) -> None:
        t = self.t
        cmd = self.cmd
        if (
            len(cmd.words) == 1
            and not cmd.assigns
            and _NAME_RE.fullmatch(cmd.words[0].text)
            and re.match(r"\(\s*\)", t[self.i :])
        ):
            self.i += re.match(r"\(\s*\)", t[self.i :]).end()  # type: ignore[union-attr]
            self.scan.functions.add(cmd.words[0].text)
            self.cmd = _Cmd()
            return
        if t.startswith("((", self.i) and not cmd.has_content:
            end = self._match_arith(self.i)
            if end >= 0:
                self._scan_subs(t[self.i + 2 : end - 2], "arith")
                self.i = end
                return
        if cmd.has_content:
            self._fail()
        self.i += 1
        if self.depth >= MAX_DEPTH:
            self._fail()
            self.i = self.n
            return
        sub = _Parser(
            t, self.scan, self.ctx.fork(), self.depth + 1, self.via, self.root
        )
        sub.i = self.i
        sub.group_piped = cmd.piped or self.group_piped
        if sub.group_piped:
            sub.pipe_start = self.pipe_start
        if sub.parse_list(frozenset({")"})) != ")":
            self._fail()
        self.i = sub.i

    def _handle_word(self, word: _Word, stop: frozenset[str]) -> bool:
        """Place a word; return True when it closes a case clause list."""
        cmd = self.cmd
        if word.expand is not None and word.assign_end < 0:
            pieces = [_Word(p) for p in word.expand]
            if not pieces and not cmd.words:
                return False
            for piece in pieces:
                cmd.words.append(piece)
            return False
        if cmd.words:
            cmd.words.append(word)
            return False
        if word.assign_end >= 0:
            cmd.assigns.append(word)
            return False
        keyword = word.text if not word.quoted and not word.dyn else ""
        if keyword == "time":
            self._skip_blank()
            mark = self.i
            option = self._read_word()
            if option.text != "-p":
                self.i = mark
            return False
        if keyword in _KEYWORDS:
            if keyword in _OPEN_KEYWORDS:
                self.kw_depth += 1
            elif keyword in _CLOSE_KEYWORDS:
                self.kw_depth = max(0, self.kw_depth - 1)
            return False
        if keyword == "esac" and "esac" in stop:
            return True
        if keyword == "function":
            self._skip_blank()
            self.scan.functions.add(self._read_word().text)
            self._skip_blank()
            if re.match(r"\(\s*\)", self.t[self.i :]):
                self.i += re.match(r"\(\s*\)", self.t[self.i :]).end()  # type: ignore[union-attr]
            return False
        if keyword == "coproc":
            mark = self.i
            self._skip_blank()
            self._read_word()
            self._skip_blank()
            if not (self.i < self.n and self.t[self.i] in "{("):
                self.i = mark
            return False
        if keyword in ("for", "select"):
            self._read_for()
            return False
        if keyword == "case":
            self._read_case()
            return False
        if keyword == "[[":
            self._read_cond(word)
            return False
        cmd.words.append(word)
        return False

    def _read_for(self) -> None:
        t = self.t
        self._skip_blank()
        if t.startswith("((", self.i):
            end = self._match_arith(self.i)
            if end >= 0:
                self._scan_subs(t[self.i + 2 : end - 2], "arith")
                self.i = end
            else:
                self._fail()
            return
        name = self._read_word()
        if name.text:
            self.ctx.vars[name.text] = None
        self._skip_blank()
        mark = self.i
        word = self._read_word()
        if word.text == "in" and not word.quoted:
            while True:
                self._skip_blank()
                if self.i >= self.n or t[self.i] in ";\n":
                    break
                if t[self.i] in "&|()<>":
                    break
                self._read_word()
        else:
            self.i = mark

    def _read_case(self) -> None:
        t = self.t
        self._skip_blank()
        self._read_word()
        self._skip_blank()
        word = self._read_word()
        if word.text != "in":
            self._fail()
            return
        while True:
            while self.i < self.n and t[self.i] in " \t\r\n":
                self.i += 1
            if self.i >= self.n:
                self._fail()
                return
            if t[self.i] == "#":
                eol = t.find("\n", self.i)
                self.i = self.n if eol < 0 else eol
                continue
            mark = self.i
            if t.startswith("esac", self.i) and (
                self.i + 4 >= self.n or t[self.i + 4] in _OPERATOR_CHARS
            ):
                self.i += 4
                return
            self.i = mark
            if t[self.i] == "(":
                self.i += 1
            while True:
                self._skip_blank()
                self._read_word()
                self._skip_blank()
                if self.i < self.n and t[self.i] == "|":
                    self.i += 1
                    continue
                break
            if self.i < self.n and t[self.i] == ")":
                self.i += 1
            else:
                self._fail()
                return
            saved = self.cmd
            closer = self.parse_list(_CASE_STOPS)
            self.cmd = saved
            if closer == "esac":
                return
            if closer == "":
                self._fail()
                return

    def _read_cond(self, head: _Word) -> None:
        t = self.t
        self.cmd.words.append(head)
        while True:
            self._skip_blank()
            if self.i >= self.n:
                self._fail()
                return
            c = t[self.i]
            if c == "\n":
                self.i += 1
            elif c in "&|()<>":
                self.cmd.words.append(_Word(c))
                self.i += 1
            elif c == ";":
                self._fail()
                return
            else:
                word = self._read_word()
                if word.text == "]]" and not word.quoted:
                    self.cmd.words.append(word)
                    return
                self.cmd.words.append(word)

    # ----- finishing a command -------------------------------------------------------

    def _end(self, sep: str) -> None:
        cmd = self.cmd
        pipe = sep in ("|", "|&")
        self.cmd = _Cmd(piped=pipe or self.group_piped)
        if pipe and not self.in_pipe:
            self.in_pipe = True
            self.pipe_saved = self.ctx.cwds
        if cmd.has_content:
            self._emit(cmd, sep)
        if not pipe:
            if self.in_pipe:
                self.ctx.cwds = self.pipe_saved
                self.in_pipe = False
            if self.kw_depth == 0 and not self.group_piped:
                self.pipe_start = len(self.scan.lits)

    def _emit(self, cmd: _Cmd, sep: str) -> None:
        if not cmd.words:
            self._assign_only(cmd)
            return
        env: dict[str, str] = {k: v for k, (v, _) in self.ctx.env.items()}
        env_dyn = {k for k, (_, d) in self.ctx.env.items() if d}
        for word in cmd.assigns:
            name = word.text[: word.assign_end].rstrip("+=")
            env[name] = word.text[word.assign_end :]
            if word.dyn:
                env_dyn.add(name)
        self._emit_words(cmd, cmd.words, env, env_dyn, self.ctx.cwds, sep)

    def _assign_only(self, cmd: _Cmd) -> None:
        for word in cmd.assigns:
            name = word.text[: word.assign_end].rstrip("+=")
            value = word.text[word.assign_end :]
            self.ctx.vars[name] = None if word.dyn else value
            self.ctx.env[name] = (value, word.dyn)

    def _unwrap(
        self,
        words: list[_Word],
        env: dict[str, str],
        env_dyn: set[str],
        cwds: tuple[str, ...],
    ) -> tuple[int, list[str], list[tuple[str, str]], bool, tuple[str, ...]]:
        index = 0
        wrappers: list[str] = []
        scripts: list[tuple[str, str]] = []
        tail_dynamic = False
        while index < len(words):
            word = words[index]
            if word.dyn:
                break
            name = posixpath.basename(word.text)
            if name == "command":
                j = index + 1
                lookup = False
                while j < len(words) and words[j].text.startswith("-") and not words[j].dyn:
                    if words[j].text == "--":
                        j += 1
                        break
                    if set(words[j].text[1:]) & set("vV"):
                        lookup = True
                    j += 1
                if lookup:
                    break
                wrappers.append("command")
                index = j
                continue
            spec = _WRAPPERS.get(name)
            if spec is None:
                break
            j, opts, assigns = self._parse_opts(words, index + 1, spec)
            wrappers.append(name)
            for assign in assigns:
                key = assign.text[: assign.assign_end].rstrip("+=")
                env[key] = assign.text[assign.assign_end :]
                if assign.dyn:
                    env_dyn.add(key)
            for flag, value in opts:
                text = value.text if isinstance(value, _Word) else (value or "")
                dynamic = isinstance(value, _Word) and value.dyn
                if name == "env" and flag in ("-S", "--split-string"):
                    scripts.append((text, "env-S"))
                elif name in ("env", "sudo") and flag in ("-C", "-D", "--chdir"):
                    cwds = (
                        ("?",)
                        if dynamic or not text
                        else tuple(_join_dir(c, text) for c in cwds)
                    )
                elif name == "flock" and flag == "-c":
                    scripts.append((text, "flock-c"))
            if name in ("sudo", "doas"):
                flags = {f for f, _ in opts}
                if flags & {"-s", "-i"} and j < len(words):
                    scripts.append((" ".join(w.text for w in words[j:]), "sudo-shell"))
                    index = len(words)
                    break
            if name == "watch":
                if j < len(words):
                    scripts.append((" ".join(w.text for w in words[j:]), "watch"))
                index = len(words)
                break
            for _ in range(spec.pos):
                if j < len(words):
                    j += 1
            if name == "xargs":
                tail_dynamic = True
            index = j
        return index, wrappers, scripts, tail_dynamic, cwds

    @staticmethod
    def _parse_opts(
        words: list[_Word], index: int, spec: _Spec
    ) -> tuple[int, list[tuple[str, _Word | str | None]], list[_Word]]:
        opts: list[tuple[str, _Word | str | None]] = []
        assigns: list[_Word] = []
        n = len(words)
        while index < n:
            word = words[index]
            text = word.text
            if text == "--" and not word.quoted:
                index += 1
                break
            if text in spec.dl and not word.dyn:
                opts.append((text, words[index + 1] if index + 1 < n else None))
                index += 2
                continue
            if text.startswith("--") and not word.dyn:
                name, eq, value = text.partition("=")
                if name in spec.lv and not eq:
                    opts.append((name, words[index + 1] if index + 1 < n else None))
                    index += 2
                else:
                    opts.append((name, value if eq else None))
                    index += 1
                continue
            if text.startswith("-") and len(text) > 1 and not word.dyn:
                consumed = 1
                for pos in range(1, len(text)):
                    ch = text[pos]
                    if ch in spec.sv:
                        if pos + 1 < len(text):
                            opts.append((f"-{ch}", text[pos + 1 :]))
                        else:
                            opts.append((f"-{ch}", words[index + 1] if index + 1 < n else None))
                            consumed = 2
                        break
                    if ch in spec.so:
                        opts.append((f"-{ch}", text[pos + 1 :] or None))
                        break
                    opts.append((f"-{ch}", None))
                index += consumed
                continue
            if spec.assign and word.assign_end >= 0:
                assigns.append(word)
                index += 1
                continue
            break
        return index, opts, assigns

    def _emit_words(
        self,
        cmd: _Cmd,
        words: list[_Word],
        env: dict[str, str],
        env_dyn: set[str],
        cwds: tuple[str, ...],
        sep: str,
        extra_via: str = "",
    ) -> None:
        head, wrappers, scripts, tail_dynamic, cwds = self._unwrap(words, env, env_dyn, cwds)
        via = (*self.via, extra_via) if extra_via else self.via
        for text, via_name in scripts:
            self._nested(text, via_name)
        if head >= len(words):
            return
        rest = words[head:]
        argv = [w.text for w in rest]
        dyn = [w.dyn for w in rest]
        glob = [w.glob for w in rest]
        if tail_dynamic:
            argv.append(XARGS_INPUT)
            dyn.append(True)
            glob.append(False)
        inv = Invocation(
            argv=argv,
            dyn=dyn,
            glob=glob,
            via=via,
            wrappers=tuple(wrappers),
            env=dict(env),
            env_dynamic=frozenset(env_dyn),
            cwds=cwds,
            stdin="pipe" if cmd.piped else cmd.stdin,
        )
        self.scan.invocations.append(inv)
        if inv.name in self.scan.functions and not inv.head_dynamic:
            inv.function_call = True
            if len(rest) > 1:
                self._emit_words(cmd, rest[1:], dict(env), set(env_dyn), cwds, sep, "function-call")
        pipe_literals = list(self.scan.lits[self.pipe_start :])
        self._after_head(cmd, inv, rest, pipe_literals, sep)
        for item in argv[1:]:
            self.scan.lits.append(item)
        if len(argv) > 2:
            self.scan.lits.append(" ".join(argv[1:]))
        for heredoc in cmd.heredocs:
            self.scan.lits.append(heredoc)
        for word in cmd.herestrings:
            self.scan.lits.append(word.text)

    def _after_head(
        self,
        cmd: _Cmd,
        inv: Invocation,
        rest: list[_Word],
        pipe_literals: list[str | _Heredoc],
        sep: str,
    ) -> None:
        if inv.head_dynamic:
            return
        name = inv.name
        args = inv.argv[1:]
        if name.lower() in SHELLS:
            self._after_shell(cmd, inv, pipe_literals)
            return
        if name == "eval":
            self._event("eval")
            if args:
                self._nested(" ".join(args), "eval")
            return
        if name in ("source", "."):
            self._event("source")
            return
        if name == "alias":
            self._event("alias")
            return
        if name == "trap":
            positional = [a for a in args if not a.startswith("-")]
            if positional:
                self._nested(positional[0], "trap")
            return
        if name == "su":
            for index, arg in enumerate(args):
                if arg in ("-c", "--command") and index + 1 < len(args):
                    self._nested(args[index + 1], "su-c")
                elif arg.startswith("--command="):
                    self._nested(arg.partition("=")[2], "su-c")
            return
        if name == "git":
            self._after_git(args)
            return
        if name == "find":
            self._find_exec(cmd, rest)
            return
        if name in ("cd", "pushd", "popd"):
            self._apply_cd(inv, rest, sep)
            return
        if name in _DECL_BUILTINS:
            for word in rest[1:]:
                if word.assign_end >= 0:
                    key = word.text[: word.assign_end].rstrip("+=")
                    value = word.text[word.assign_end :]
                    self.ctx.vars[key] = None if word.dyn else value
                    self.ctx.env[key] = (value, word.dyn)
            return
        if name in _READ_BUILTINS:
            for arg in args:
                if _NAME_RE.fullmatch(arg):
                    self.ctx.vars[arg] = None
            return
        if name == "unset":
            for arg in args:
                self.ctx.vars.pop(arg, None)
                self.ctx.env.pop(arg, None)

    def _git_alias(self, config: str) -> None:
        key, _, value = config.partition("=")
        if key.lower().startswith("alias."):
            self._nested(value[1:] if value.startswith("!") else f"git {value}", "git-alias")

    def _after_git(self, args: list[str]) -> None:
        """Scan the shell text git itself runs: aliases, `rebase --exec`, `submodule
        foreach` and `bisect run`, so every guard sees what they would execute."""
        index = 0
        while index < len(args):
            arg = args[index]
            if arg in _GIT_VALUE_OPTIONS:
                if arg == "-c" and index + 1 < len(args):
                    self._git_alias(args[index + 1])
                index += 2
            elif arg.startswith("-c") and len(arg) > 2 and arg[2] != "-":
                self._git_alias(arg[2:])
                index += 1
            elif arg.startswith("-"):
                index += 1
            else:
                break
        if index >= len(args):
            return
        sub, rest = args[index], args[index + 1 :]
        if sub == "rebase":
            for pos, arg in enumerate(rest):
                if arg in ("--exec", "-x") and pos + 1 < len(rest):
                    self._nested(rest[pos + 1], "git-exec")
                elif arg.startswith("--exec="):
                    self._nested(arg.partition("=")[2], "git-exec")
                elif arg.startswith("-x") and len(arg) > 2 and arg[2] != "-":
                    self._nested(arg[2:], "git-exec")
        elif sub in ("submodule", "bisect") and rest[:1] in (["foreach"], ["run"]):
            words = rest[1:]
            while sub == "submodule" and words and words[0] in ("--", "--recursive", "-q", "--quiet"):
                words = words[1:]
            if words:
                text = " ".join(words) if sub == "submodule" else shlex.join(words)
                self._nested(text, "git-exec")

    def _after_shell(self, cmd: _Cmd, inv: Invocation, pipe_literals: list[str | _Heredoc]) -> None:
        args = inv.argv[1:]
        script_index = -1
        has_c = False
        has_s = False
        index = 0
        positional = False
        script_word = ""
        while index < len(args):
            arg = args[index]
            if arg == "--":
                index += 1
                positional = index < len(args)
                if has_c and positional:
                    script_index = index
                break
            if arg.startswith("--"):
                index += 2 if arg in ("--rcfile", "--init-file") else 1
                continue
            if arg == "-":
                has_s = True
                index += 1
                break
            if arg[:1] in "-+" and len(arg) > 1:
                letters = arg[1:]
                if arg[0] == "-" and "c" in letters:
                    has_c = True
                if arg[0] == "-" and "s" in letters:
                    has_s = True
                if "o" in letters or "O" in letters:
                    index += 2
                else:
                    index += 1
                continue
            positional = True
            script_word = arg
            if has_c and script_index < 0:
                script_index = index
            break
        if has_c:
            if script_index >= 0:
                self._nested(args[script_index], "shell-c")
            return
        reads_stdin = has_s or not positional
        inv.script_stdin = reads_stdin
        for word in cmd.herestrings:
            self._nested(word.text, "here-string")
        for heredoc in cmd.heredocs:
            if reads_stdin:
                heredoc.feeds_shell = True
        from_procsub = cmd.procsub_stdin or (positional and script_word.startswith("<("))
        if (cmd.piped and reads_stdin) or from_procsub:
            for lit in pipe_literals:
                text = lit.body or "" if isinstance(lit, _Heredoc) else lit
                self._nested(text, "pipe-to-shell")

    def _find_exec(self, cmd: _Cmd, words: list[_Word]) -> None:
        index = 0
        while index < len(words):
            if words[index].text in ("-exec", "-execdir", "-ok", "-okdir"):
                j = index + 1
                group: list[_Word] = []
                while j < len(words) and words[j].text not in (";", "+"):
                    group.append(words[j])
                    j += 1
                if group:
                    self._emit_words(
                        cmd,
                        group,
                        {k: v for k, (v, _) in self.ctx.env.items()},
                        set(),
                        self.ctx.cwds,
                        "",
                        "find-exec",
                    )
                index = j
            index += 1

    def _apply_cd(self, inv: Invocation, rest: list[_Word], sep: str) -> None:
        if self.in_pipe or sep in ("|", "|&", "&"):
            return
        index = 1
        while index < len(rest):
            text = rest[index].text
            if text == "--":
                index += 1
                break
            if text.startswith("-") and len(text) > 1 and not text[1:].isdigit():
                index += 1
                continue
            break
        paths = rest[index:]
        if inv.name == "popd" or not paths:
            new: tuple[str, ...] = ("?",)
        else:
            word = paths[0]
            text = word.text
            if word.dyn or text in ("-", "") or text.startswith(("~", "+")):
                new = ("?",)
            else:
                new = tuple(_join_dir(c, text) for c in inv.cwds)
        if sep == "&&":
            self.ctx.cwds = new
        else:
            merged = list(self.ctx.cwds)
            for item in new:
                if item not in merged:
                    merged.append(item)
            self.ctx.cwds = tuple(merged)


def scan(command: str) -> ScanResult:
    """Parse a bash command string into the programs it would run."""
    state = _Scan()
    parser = _Parser(command, state, _Ctx(), 0, (), True)
    parser.parse_list()
    cuts = sorted(state.cuts)
    visible: list[str] = []
    cursor = 0
    for start, end in cuts:
        if start >= cursor:
            visible.append(command[cursor:start])
            cursor = end
    visible.append(command[cursor:])
    return ScanResult(
        invocations=state.invocations,
        unparseable=state.unparseable,
        events=state.events,
        visible_text="".join(visible),
    )


def _records(result: ScanResult, argv0: str) -> list[str]:
    """Flatten matching invocations to NUL-friendly fields a bash 3.2 hook can read."""
    out = ["unparseable=" + ("1" if result.unparseable else "0")]
    for inv in result.invocations:
        if argv0 and not inv.may_be(argv0):
            continue
        out.append("INV")
        out.append(">".join(inv.via))
        out.append(inv.stdin)
        out.append("1" if inv.head_dynamic else "0")
        out.append(str(len(inv.cwds)))
        out.extend(inv.cwds)
        out.append(str(len(inv.env)))
        for key, value in inv.env.items():
            out.append("1" if key in inv.env_dynamic else "0")
            out.append(f"{key}={value}")
        out.append(str(len(inv.argv)))
        for word, dynamic, globbed in zip(inv.argv, inv.dyn, inv.glob, strict=True):
            out.append("1" if dynamic else ("2" if globbed else "0"))
            out.append(word)
    out.append("END")
    return out


_USAGE = """usage: shell_scan.py [--argv0 PROGRAM] [--json] [--command TEXT]

Print the programs a bash command string would run. Reads the command from stdin unless
--command is given. Default output is NUL-delimited fields for a bash 3.2 hook (see
`_records`); --json prints the full scan result instead; --argv0 keeps only invocations
that may be PROGRAM.
"""


def _parse_args(argv: list[str]) -> tuple[str, bool, str | None]:
    # Hand-rolled because the git guard runs this on every Bash call and `argparse` alone
    # costs several milliseconds of import time.
    program, as_json, command = "", False, None
    items = iter(argv)
    for arg in items:
        if arg in ("-h", "--help"):
            sys.stdout.write(_USAGE)
            sys.exit(0)
        elif arg == "--json":
            as_json = True
        elif arg == "--argv0":
            program = next(items, "")
        elif arg.startswith("--argv0="):
            program = arg.partition("=")[2]
        elif arg == "--command":
            command = next(items, "")
        elif arg.startswith("--command="):
            command = arg.partition("=")[2]
        else:
            sys.stderr.write(f"shell_scan.py: unknown argument {arg!r}\n{_USAGE}")
            sys.exit(2)
    return program, as_json, command


def main(argv: list[str] | None = None) -> int:
    if hasattr(signal, "alarm"):
        signal.alarm(SCAN_TIMEOUT_SECONDS)
    program, as_json, command = _parse_args(sys.argv[1:] if argv is None else argv)
    if command is None:
        command = sys.stdin.read()
    result = scan(command)
    if as_json:
        import json

        invocations = [
            inv.as_dict() for inv in result.invocations if not program or inv.may_be(program)
        ]
        payload = {
            "unparseable": result.unparseable,
            "top_opaque": sorted(result.top_opaque),
            "nested_opaque": sorted(result.nested_opaque),
            "invocations": invocations,
        }
        print(json.dumps(payload, sort_keys=True))
        return 0
    sys.stdout.write("\0".join(_records(result, program)) + "\0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
