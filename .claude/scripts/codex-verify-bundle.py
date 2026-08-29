#!/usr/bin/env python3
"""Build a tree-bound markdown bundle for the FSD verification gates."""

from __future__ import annotations

import argparse
import codecs
import hashlib
import json
import os
import posixpath
import re
import subprocess
import tempfile
import unicodedata
from pathlib import Path
from typing import Any


ITEM_LIMIT = 64 * 1024
CONTEXT_LIMIT = 256 * 1024
BUNDLE_LIMIT = 512 * 1024
JSON_INPUT_LIMIT = 512 * 1024
FULL_DIFF_BYTE_LIMIT = 128 * 1024
SCAN_CHUNK = 64 * 1024
MAX_ASSIGNMENT_VALUE = 4 * 1024
SCAN_OVERLAP = MAX_ASSIGNMENT_VALUE + 1024
CREDENTIAL_ASSIGNMENT_RE = re.compile(
    rb"(?<![A-Za-z0-9_-])[\"']?(?P<key>[A-Za-z_][A-Za-z0-9_-]*)"
    rb"[\"']?[ \t]*(?::=|:(?!=)|=(?!=))[ \t]*"
)
SECRET_PATTERNS = (
    ("private-key", re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----")),
    ("bearer-token", re.compile(rb"(?i)\bauthorization\s*:\s*bearer\s+[a-z0-9._~+/=-]{8,}")),
    (
        "known-token",
        re.compile(
            rb"\b(?:AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9_-]{20,})\b"
        ),
    ),
)
CANONICAL_PLACEHOLDER_VALUE = re.compile(
    rb"(?i)^(?:null|none|false|your[_-][a-z0-9_-]+|(?:example|dummy|placeholder|redacted|changeme)(?:[_-](?:value|secret|token|password|key|credential)(?:[_-]\d+)?)?|"
    rb"<[^<>\r\n\"']{1,64}>)$"
)
# AWS's own published example key. This constant exists to recognise it AS a placeholder,
# so the literal is the point rather than an accident.
KNOWN_PLACEHOLDER_VALUE = re.compile(rb"(?i)^AKIAIOSFODNN7EXAMPLE\d*$")  # pragma: allowlist secret
IDENTIFIER_ECHO = re.compile(
    rb"^(?P<key>[A-Za-z_][A-Za-z0-9_]*)\s*[:=]\s*(?P<value>[A-Za-z_][A-Za-z0-9_]*)$"
)
REFERENCE_VALUE = re.compile(
    rb"(?ix)^(?:"
    rb"\$\{?[A-Z_][A-Z0-9_]*\}?|"
    rb"\$\([A-Z_][A-Z0-9_]*\)|"
    rb"(?:os\.)?getenv\([^\r\n)]*\)|"
    rb"os\.environ(?:\.get)?(?:\[[^\r\n]*\]|\([^\r\n)]*\))|"
    rb"process\.env\.[A-Z_][A-Z0-9_]*|"
    rb"environment\.getenvironmentvariable\([^\r\n)]*\)|"
    rb"(?:config|settings|credentials|env)\.[A-Z_][A-Z0-9_.]*|"
    rb"(?:str|string|bytes|secretstr|optional\[[A-Z0-9_.]+\])"
    rb")$"
)
SAFE_EXPRESSION_VALUE = re.compile(
    rb"(?is)^(?:await[ \t]+)?(?:"
    rb"secrets\.(?:token_bytes|token_hex|token_urlsafe|randbelow|choice)|"
    rb"getpass\.getpass|input|"
    rb"[A-Z_][A-Z0-9_.]*\.(?:get|read|fetch|retrieve)_secret"
    rb")[ \t]*\([^\r\n]*\)$"
)
# `$(cmd --flag value)` — a shell/ADO command substitution that fetches the credential at
# run time. Arguments are allowed, so this cannot reuse REFERENCE_VALUE's bare `$(NAME)`
# alternative. Nested parens are excluded so the span stays anchored to one substitution.
COMMAND_SUBSTITUTION_VALUE = re.compile(rb"^\$\([^()\r\n]*\)$")
# The same substitution embedded in a larger value (`"Sql-$(openssl rand -hex 16)-Aa1!"`,
# `"$(cat token).suffix"`). A value that splices in command output is generated at run time,
# so it cannot be the literal credential no matter what surrounds it. The substitution must
# name something — a leading letter or underscore — so `$()` cannot launder a literal.
EMBEDDED_COMMAND_SUBSTITUTION = re.compile(rb"\$\([A-Za-z_][^()\r\n]*\)")
# PowerShell also groups a command with a bare paren (`$password = (az ... )`). Bare parens
# are far weaker evidence than `$(`, so require a command word *plus* at least one argument —
# that keeps `(az keyvault secret show ...)` while `(azurePassword123XY)` stays a literal.
BARE_COMMAND_SUBSTITUTION = re.compile(rb"^\([A-Za-z_][A-Za-z0-9_.-]*[ \t]+[^()\r\n]*\)$")
# The same substitution when its closing paren is not on this line — PowerShell backtick and
# shell backslash continuations split `$(az keyvault secret show ...)` across lines, so the
# unquoted branch only ever sees the opening fragment. Restricted to a short digit-free
# command word so a truncated literal cannot pass as a CLI name.
OPEN_COMMAND_SUBSTITUTION = re.compile(rb"^\$?\([A-Za-z][A-Za-z_.-]{0,9}$")
# Markdown and code-excerpt punctuation that wraps a value inside prose without changing it
# (`` `$(VAR)` ``, `"{$var}"`). Trimmed only to re-test the reference shapes below: a literal
# secret cannot acquire a reference shape by losing quotes, so this widens nothing else.
DOC_WRAPPER_CHARS = b"`\"'{}"
# `${{ secrets.NAME }}` — the GitHub Actions expression. The value the unquoted branch sees
# is the `${{` fragment, so every workflow excerpt that wires a secret read as a literal.
ACTIONS_EXPRESSION_VALUE = re.compile(rb"^\$\{\{[^}\r\n]*\}\}$")
ACTIONS_EXPRESSION_OPEN = re.compile(rb"^\$\{\{$")
# `<API key secret>` — the same angle placeholder as CANONICAL_PLACEHOLDER_VALUE, but written
# with spaces, which the unquoted branch truncates at the first one.
ANGLE_PLACEHOLDER_SPAN = re.compile(rb"^<[^<>\r\n\"']{1,64}>$")
# `[REDACTED]` / `[JWT_REDACTED]` — the bracketed marker a redactor substitutes FOR a secret.
# Documentation about redaction quotes these constantly (`Password=[REDACTED]`), and a marker
# is the one value proven not to be the credential: it is what remains after removal. Kept
# deliberately narrow — upper-case, bracketed, and REDACTED must appear as a whole word — so
# no literal can acquire the shape. The closing bracket is optional because
# `assigned_value` strips a trailing `]` along with other value punctuation; requiring it
# would make the rule fire on the backticked form only and miss the bare one.
BRACKET_REDACTION_MARKER = re.compile(rb"^\[[A-Z0-9]*_?REDACTED(?:_[A-Z0-9]+)*\]?$")
# `https://x-access-token:${GITHUB_PAT}@github.com/owner/repo.git` — a clone URL whose
# credential position is filled at run time. `x-access-token` reads as a credential name and
# the value the unquoted branch sees is the reference *plus* the URL authority and path, so
# none of the fullmatch reference rules above can absolve it. The reference must start the
# value: everything after the `@` is host and path, which is not the credential. A pasted
# literal in that same position has no leading reference and stays flagged, and a real token
# after the `@` is still caught by SECRET_PATTERNS.
URL_CREDENTIAL_REFERENCE = re.compile(
    rb"(?ix)^(?:\$\{[A-Z_][A-Z0-9_]*\}|\$\([A-Z_][A-Z0-9_]*\)|\$[A-Z_][A-Z0-9_]*)"
    rb"@[A-Z0-9._~:/?\#\[\]!$&'()*+,;=%{}-]*$"
)
# `parsed_assignment` reports an unreadable value with an angle-wrapped sentinel. Those are
# fail-closed signals, not placeholders — the angle rules above must never absolve them.
FAIL_CLOSED_VALUES = frozenset({b"<overlong-quoted-value>", b"<unterminated-quoted-value>"})
# Prose, not an assignment. Markdown running text is full of incidental `key=` shapes whose
# value carries no secret at all, and each of these is provable rather than heuristic:
#   - no alphanumeric character at all (`...`, an elision, a stray backtick run). Every
#     credential format in SECRET_PATTERNS requires alphanumerics, so this cannot hide one.
#   - a bare short decimal, which is how a doc writes a *length* (`secret=32 chars`).
#   - a printf/format conversion specifier, which is a placeholder by definition.
NON_ALPHANUMERIC_VALUE = re.compile(rb"^[^A-Za-z0-9]{1,12}$")
COUNT_VALUE = re.compile(rb"^[0-9]{1,4}$")
FORMAT_SPECIFIER_VALUE = re.compile(rb"^%[-+ #0-9.]*[sdifgxXeEouc](?:\\[nrt])*[\"'`\\,]*$")
# Boolean switches that merely *describe* secrecy. `isSecret=true` is a pipeline flag, not a
# credential, and treating it as one flags every doc that explains how to set it.
CREDENTIAL_FLAG_NAMES = frozenset(
    {b"issecret", b"is_secret", b"hassecret", b"has_secret", b"requiresecret", b"require_secret",
     b"requireclientsecret", b"secretrequired", b"secret_required", b"usesecret", b"use_secret"}
)
SNAKE_CREDENTIAL_NAMES = (
    b"password",
    b"passwd",
    b"pwd",
    b"api_key",
    b"client_secret",
    b"access_token",
    b"refresh_token",
    b"secret",
)
CAMEL_CREDENTIAL_SUFFIXES = (
    b"Password",
    b"Passwd",
    b"Pwd",
    b"ApiKey",
    b"ClientSecret",
    b"AccessToken",
    b"RefreshToken",
    b"Secret",
)
DELIMITED_SPANS = ((b"$((", b"))"), (b"${{", b"}}"), (b"$(", b")"), (b"<", b">"))


def command_substitution_span(candidate: bytes) -> bytes | None:
    """Return a whole delimited span so a value containing spaces survives.

    The unquoted branch of `parsed_assignment` otherwise cuts the value at the first space,
    which turns `$(az keyvault secret show --query value)` into a `$(az` fragment, and
    `${{ secrets.NAME }}` / `<API key secret>` into `${{` / `<API`. None of those fragments
    can match a reference or placeholder shape. Leading doc wrappers are tolerated; the span
    ends at its own closing delimiter, so trailing prose stays out of the value.
    """
    prefix = len(candidate) - len(candidate.lstrip(DOC_WRAPPER_CHARS))
    for opener, closer in DELIMITED_SPANS:
        if candidate[prefix : prefix + len(opener)] != opener:
            continue
        end = candidate.find(closer, prefix + len(opener))
        if end < 0:
            return None
        return candidate[prefix : end + len(closer)]
    return None


def reference_like(value: bytes) -> bool:
    """Return whether the value is a run-time reference rather than a literal credential."""
    if value in FAIL_CLOSED_VALUES:
        return False
    for candidate in (value, value.strip(DOC_WRAPPER_CHARS)):
        if not candidate:
            continue
        if (
            REFERENCE_VALUE.fullmatch(candidate)
            or SAFE_EXPRESSION_VALUE.fullmatch(candidate)
            or COMMAND_SUBSTITUTION_VALUE.fullmatch(candidate)
            or EMBEDDED_COMMAND_SUBSTITUTION.search(candidate)
            or BARE_COMMAND_SUBSTITUTION.fullmatch(candidate)
            or OPEN_COMMAND_SUBSTITUTION.fullmatch(candidate)
            or ACTIONS_EXPRESSION_VALUE.fullmatch(candidate)
            or ACTIONS_EXPRESSION_OPEN.fullmatch(candidate)
            or ANGLE_PLACEHOLDER_SPAN.fullmatch(candidate)
            or NON_ALPHANUMERIC_VALUE.fullmatch(candidate)
            or COUNT_VALUE.fullmatch(candidate)
            or FORMAT_SPECIFIER_VALUE.fullmatch(candidate)
            or URL_CREDENTIAL_REFERENCE.fullmatch(candidate)
        ):
            return True
    return False


def git(
    repo: Path,
    *args: str,
    check: bool = True,
    env: dict[str, str] | None = None,
) -> bytes:
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=merged_env,
    )
    if check and result.returncode != 0:
        message = result.stderr.decode("utf-8", "replace").strip()
        raise SystemExit(message or f"git {' '.join(args)} failed")
    return result.stdout


def git_text(repo: Path, *args: str, **kwargs: Any) -> str:
    return git(repo, *args, **kwargs).decode("utf-8", "strict")


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def safe_display_path(path: str) -> str:
    encoded = path.encode("utf-8", "surrogateescape")
    if secret_kind(encoded):
        return f"<redacted-path:{sha256(encoded)[:12]}>"
    return path


def redact_sensitive_lines(value: str) -> str:
    lines = []
    for line in value.splitlines():
        encoded = line.encode("utf-8", "surrogateescape")
        lines.append(
            f"<redacted-line:{sha256(encoded)[:12]}>" if secret_kind(encoded) else line
        )
    return "\n".join(lines)


def load_json(path: str | None, default: Any) -> Any:
    if not path:
        return default
    try:
        source = Path(path)
        if source.stat().st_size > JSON_INPUT_LIMIT:
            raise SystemExit(f"JSON input exceeds 512 KiB: {path}")
        return json.loads(source.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise SystemExit(f"invalid JSON file {path}: {exc}") from exc


def normalize_path(value: Any) -> str:
    if not isinstance(value, str):
        raise ValueError("path must be a string")
    path = unicodedata.normalize("NFC", value).replace("\\", "/")
    if "\0" in path or path.startswith("/"):
        raise ValueError("path must be a relative UTF-8 repository path")
    while path.startswith("./"):
        path = path[2:]
    if not path or any(part == ".." for part in path.split("/")):
        raise ValueError("path must not be empty or traverse parents")
    path = posixpath.normpath(path)
    if path in ("", ".") or path.startswith("../"):
        raise ValueError("path must name a repository file")
    return path


def candidate_tree(repo: Path) -> tuple[str, str]:
    head_oid = git_text(repo, "rev-parse", "HEAD^{commit}").strip()
    with tempfile.TemporaryDirectory(prefix="fsd-index-") as temp_dir:
        index = str(Path(temp_dir) / "index")
        env = {"GIT_INDEX_FILE": index}
        git(repo, "read-tree", "HEAD", env=env)
        git(repo, "add", "-A", "--", ".", env=env)
        tree_oid = git_text(repo, "write-tree", env=env).strip()
    return head_oid, tree_oid


def changed_lines(repo: Path, base_oid: str, tree_oid: str) -> tuple[int, list[dict[str, Any]]]:
    total = 0
    per_file: list[dict[str, Any]] = []
    fields = git(
        repo, "diff", "--no-ext-diff", "--no-textconv", "--numstat", "-z", base_oid, tree_oid
    ).split(b"\0")
    index = 0
    while index < len(fields) - 1:
        header = fields[index]
        index += 1
        added, deleted, path_bytes = header.split(b"\t", 2)
        if path_bytes:
            source = destination = path_bytes.decode("utf-8", "strict")
        else:
            source = fields[index].decode("utf-8", "strict")
            destination = fields[index + 1].decode("utf-8", "strict")
            index += 2
        entries = (
            tree_entry(repo, base_oid, source),
            tree_entry(repo, tree_oid, destination),
        )
        binary = any(
            entry is not None
            and (
                entry["type"] != "blob"
                or project_blob(repo, entry, 0)["encoding"] != "utf-8"
            )
            for entry in entries
        )
        if binary:
            count = 0
        elif added == b"-" or deleted == b"-":
            # Git attributes can force `- -` numstat for renderable text. Blob byte limits,
            # not this display-only count, decide whether the full diff is safe to embed.
            count = 1
        else:
            count = int(added) + int(deleted)
        total += count
        per_file.append(
            {
                "binary": binary,
                "count": count,
                "display": destination if source == destination else f"{source} -> {destination}",
                "path": destination,
                "source_path": source,
            }
        )
    per_file.sort(key=lambda item: (item["count"], item["path"]), reverse=True)
    return total, per_file


def changed_paths(repo: Path, base_oid: str, tree_oid: str) -> list[str]:
    raw = git(repo, "diff", "--no-ext-diff", "--no-textconv", "--name-only", "-z", base_oid, tree_oid)
    return [item.decode("utf-8", "strict") for item in raw.split(b"\0") if item]


def tree_entry(repo: Path, tree_oid: str, path: str) -> dict[str, str] | None:
    raw = git(repo, "ls-tree", "-z", tree_oid, "--", f":(literal){path}")
    if not raw:
        return None
    header, actual_path = raw.split(b"\t", 1)
    mode, kind, oid = header.decode("ascii").split(" ")
    return {
        "mode": mode,
        "type": kind,
        "oid": oid,
        "path": actual_path.rstrip(b"\0").decode("utf-8", "strict"),
    }


def blob_size(repo: Path, entry: dict[str, str] | None) -> int:
    if not entry or entry["type"] != "blob":
        return 0
    raw = git(repo, "cat-file", "-s", entry["oid"], check=False).strip()
    return int(raw) if raw.isdigit() else 0


def path_metadata(
    repo: Path, base_oid: str, tree_oid: str, source_path: str, destination_path: str
) -> dict[str, Any]:
    result: dict[str, Any] = {"path": safe_display_path(destination_path)}
    for label, oid, path in (
        ("base", base_oid, source_path),
        ("candidate", tree_oid, destination_path),
    ):
        entry = tree_entry(repo, oid, path)
        result[label] = None if entry is None else {
            "mode": entry["mode"],
            "type": entry["type"],
            "oid": entry["oid"],
            "byte_count": blob_size(repo, entry),
        }
    return result


def is_identifier_echo(matched: bytes) -> bool:
    """Return whether a non-password credential field references an identifier, not a literal.

    Covers exact same-name references and the camel-cased variable references that named
    arguments produce constantly. Camel forms are matched case-sensitively, so an unquoted
    literal that merely contains the key word in lower case stays flagged.
    """
    echo = IDENTIFIER_ECHO.match(matched.strip())
    if not echo:
        return False
    key = echo.group("key").lower()
    if key == b"password":
        return False
    value = echo.group("value")
    if key == value.lower():
        return True

    words = [word for word in re.split(rb"[_-]|(?=[A-Z])", echo.group("key")) if word]
    upper_camel = b"".join(word[:1].upper() + word[1:].lower() for word in words)
    lower_camel = upper_camel[:1].lower() + upper_camel[1:]
    if upper_camel in value:
        return True
    return value.startswith(lower_camel) and value[len(lower_camel):][:1].isupper()


def is_credential_name(value: bytes) -> bool:
    normalized = value.replace(b"-", b"_").lower()
    if normalized in CREDENTIAL_FLAG_NAMES:
        return False
    if any(
        normalized == name or normalized.endswith(b"_" + name)
        for name in SNAKE_CREDENTIAL_NAMES
    ):
        return True
    return any(value.endswith(suffix) for suffix in CAMEL_CREDENTIAL_SUFFIXES)


def assigned_value(matched: bytes) -> bytes | None:
    delimiter = re.search(rb"[:=]", matched)
    if delimiter is None:
        return None
    raw = matched[delimiter.end():].strip()
    if raw[:1] not in {b'"', b"'"}:
        return raw.rstrip(b",;)}]")
    if raw[:3] in {b'"""', b"'''"}:
        quote = raw[:3]
        end = raw.find(quote, 3)
        return None if end < 0 else raw[3:end]
    quote = raw[:1]
    escaped = False
    value = bytearray()
    for byte in raw[1:]:
        current = bytes((byte,))
        if escaped:
            value.extend(current)
            escaped = False
        elif current == b"\\":
            escaped = True
        elif current == quote:
            return bytes(value)
        else:
            value.extend(current)
    return None


def parsed_assignment(data: bytes, match: re.Match[bytes]) -> tuple[bytes, bytes] | None:
    """Return the bounded assignment and scalar value for one credential key."""
    start = match.end()
    if start >= len(data):
        return None
    triple_quote = data[start : start + 3]
    if triple_quote in {b'"""', b"'''"}:
        content_start = start + 3
        search_end = min(len(data), content_start + MAX_ASSIGNMENT_VALUE + 3)
        end = data.find(triple_quote, content_start, search_end)
        if end >= 0:
            complete = data[match.start() : end + 3]
            value = assigned_value(complete)
            return (complete, value) if value is not None else None
        reason = (
            b"<overlong-quoted-value>"
            if len(data) - content_start > MAX_ASSIGNMENT_VALUE
            else b"<unterminated-quoted-value>"
        )
        return data[match.start() : search_end], reason
    quote = data[start : start + 1]
    if quote in {b'"', b"'"}:
        escaped = False
        limit = min(len(data), start + MAX_ASSIGNMENT_VALUE + 2)
        for index in range(start + 1, limit):
            current = data[index : index + 1]
            if escaped:
                escaped = False
            elif current == b"\\":
                escaped = True
            elif current == quote:
                complete = data[match.start() : index + 1]
                value = assigned_value(complete)
                return (complete, value) if value is not None else None
            elif current in {b"\r", b"\n"}:
                return data[match.start() : index], b"<unterminated-quoted-value>"
        return data[match.start() : limit], b"<overlong-quoted-value>"

    line_end = min(len(data), start + MAX_ASSIGNMENT_VALUE)
    for separator in (b"\r", b"\n"):
        candidate = data.find(separator, start, line_end)
        if candidate >= 0:
            line_end = min(line_end, candidate)
    raw = data[start:line_end]
    comment = re.search(rb"[ \t]+(?:#|//|/\*|--)", raw)
    if comment:
        raw = raw[: comment.start()]
    # A `;` ends the value in both shapes that reach here unquoted: a connection string's
    # `Password=<value>;Encrypt=false` pair list, and a shell command separator. Without the
    # cut the value swallowed the remaining pairs, so `Password=${VAR};Encrypt=false` never
    # matched the bare-reference shape. This only shortens the span, so no literal is
    # laundered: a literal written before the `;` is still what the matcher sees.
    semicolon = raw.find(b";")
    if semicolon >= 0:
        raw = raw[:semicolon]
    candidate = raw.strip().rstrip(b",;").strip()
    if reference_like(candidate):
        value = candidate
    else:
        value = command_substitution_span(candidate) or (
            candidate.split(None, 1)[0] if candidate.split(None, 1) else b""
        )
    if not value:
        return None
    return data[match.start() : start] + value, value


def is_placeholder_match(matched: bytes) -> bool:
    value = assigned_value(matched)
    candidate = matched.strip() if value is None else value.strip()
    if candidate in FAIL_CLOSED_VALUES:
        return False
    if (
        value == b""
        or CANONICAL_PLACEHOLDER_VALUE.fullmatch(candidate)
        or KNOWN_PLACEHOLDER_VALUE.fullmatch(candidate)
    ):
        return True
    # A bracketed redaction marker survives Markdown wrappers and trailing sentence
    # punctuation the same way a run-time reference survives quotes. The marker regex is a
    # fixed literal shape, so widening the trim set cannot admit anything else, and the
    # fail-closed sentinel guard above still runs first.
    return any(
        BRACKET_REDACTION_MARKER.fullmatch(trimmed)
        for trimmed in (candidate, candidate.strip(DOC_WRAPPER_CHARS + b",;."))
        if trimmed
    )


def is_prompt_label(data: bytes, match: re.Match[bytes]) -> bool:
    if match.group("key").lower() != b"password":
        return False
    line_start = data.rfind(b"\n", 0, match.start()) + 1
    prefix = data[line_start : match.start()].rstrip()
    return bool(
        re.search(
            rb"(?i)(?:input|getpass(?:\.getpass)?)\s*\(\s*\\?$",
            prefix,
        )
    )


def decode_escaped_quotes(data: bytes) -> tuple[bytes, list[int]]:
    decoded = bytearray()
    offsets: list[int] = []
    index = 0
    while index < len(data):
        if data[index : index + 1] == b"\\" and data[index + 1 : index + 2] in {b'"', b"'"}:
            index += 1
        decoded.extend(data[index : index + 1])
        offsets.append(index)
        index += 1
    return bytes(decoded), offsets


def direct_secret_match(data: bytes) -> tuple[str, int] | None:
    for name, pattern in SECRET_PATTERNS:
        for match in pattern.finditer(data):
            matched = match.group(0)
            if is_placeholder_match(matched):
                continue
            return name, match.start()
    for match in CREDENTIAL_ASSIGNMENT_RE.finditer(data):
        if not is_credential_name(match.group("key")):
            continue
        if is_prompt_label(data, match):
            continue
        parsed = parsed_assignment(data, match)
        if parsed is None:
            continue
        matched, value = parsed
        if is_placeholder_match(matched):
            continue
        if reference_like(value):
            continue
        if is_identifier_echo(matched):
            continue
        return "credential-assignment", match.start()
    return None


def secret_match(data: bytes) -> tuple[str, int] | None:
    match = direct_secret_match(data)
    if match or (b'\\"' not in data and b"\\'" not in data):
        return match
    decoded, offsets = decode_escaped_quotes(data)
    match = direct_secret_match(decoded)
    if not match:
        return None
    kind, offset = match
    return kind, offsets[offset]


def secret_kind(data: bytes) -> str | None:
    match = secret_match(data)
    return match[0] if match else None


# Reviewed-exception support, shared by every caller that scans a whole workspace or a
# whole backup archive. Keeping the parser and the resume loop here is deliberate: the
# defect this mechanism was written for was three scan paths disagreeing about scope, and a
# second private copy would reintroduce exactly that.
ALLOWLIST_MAX_SKIPS = 64
ALLOWLIST_BUDGET_EXHAUSTED = object()


def parse_secret_scan_allowlist(text: str) -> tuple[set[tuple[str, str]], str | None]:
    """Parse `<sha256>  <path>  # reason` lines. Returns (entries, error).

    Any malformed line yields an error and NO entries, so a damaged allowlist fails the
    scan closed instead of silently acknowledging a subset.
    """
    entries: set[tuple[str, str]] = set()
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split("#", 1)[0].strip().split()
        if len(fields) != 2:
            return set(), f"line {number} is not '<sha256> <path>'"
        digest, target = fields
        if len(digest) != 64 or any(character not in "0123456789abcdef" for character in digest):
            return set(), f"line {number} has a malformed sha256"
        if target.startswith("/") or ".." in target.split("/") or "*" in target:
            return set(), f"line {number} has an unsafe or wildcard path"
        entries.add((digest, target))
    return entries, None


def _discard(stream: Any, count: int) -> None:
    """Skip `count` bytes without seeking; zip member streams are not seekable."""
    while count > 0:
        chunk = stream.read(min(count, SCAN_CHUNK))
        if not chunk:
            return
        count -= len(chunk)


def scan_source_for_secret(
    open_stream: Any,
    relative_path: str | None,
    allowlist: set[tuple[str, str]],
    used: set[tuple[str, str]] | None = None,
) -> Any:
    """First hit on `relative_path` that the allowlist does not acknowledge.

    `open_stream()` must return a fresh binary stream each call. An acknowledged line
    suppresses only itself: the scan resumes at the following byte, so a real secret
    elsewhere in the same source is still reported.
    """
    start = 0
    for _ in range(ALLOWLIST_MAX_SKIPS + 1):
        with open_stream() as stream:
            if start:
                _discard(stream, start)
            match = scan_stream_for_secret(stream)
        if match is None:
            return None
        kind, offset = match
        absolute = start + offset
        with open_stream() as stream:
            head = stream.read(absolute)
            tail = stream.readline()
        line_start = head.rfind(b"\n") + 1
        line_bytes = head[line_start:] + tail.rstrip(b"\r\n")
        number = head.count(b"\n") + 1
        key = (hashlib.sha256(line_bytes).hexdigest(), relative_path or "")
        if relative_path is not None and key in allowlist:
            if used is not None:
                used.add(key)
            start = line_start + len(line_bytes) + 1
            continue
        return kind, number
    return ALLOWLIST_BUDGET_EXHAUSTED


def scan_stream_for_secret(stream: Any) -> tuple[str, int] | None:
    carry = b""
    processed = 0
    while chunk := stream.read(SCAN_CHUNK):
        data = carry + chunk
        match = secret_match(data)
        if match:
            kind, offset = match
            return kind, max(0, processed - len(carry) + offset)
        processed += len(chunk)
        carry = data[-SCAN_OVERLAP:]
    return None


def scan_blob_for_secret(repo: Path, oid: str) -> tuple[str, int] | None:
    process = subprocess.Popen(
        ["git", "-C", str(repo), "cat-file", "blob", oid],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    assert process.stdout is not None
    try:
        return scan_stream_for_secret(process.stdout)
    finally:
        process.stdout.close()
        if process.poll() is None:
            process.kill()
        process.wait()


def secret_preflight(
    repo: Path,
    tree_oid: str,
    paths: list[str],
    task: str,
    inventory: Any,
    evidence: Any,
) -> None:
    for label, data in (
        ("task", task.encode("utf-8")),
        ("inventory", canonical_bytes(inventory)),
        ("evidence", canonical_bytes(evidence)),
    ):
        kind = secret_kind(data)
        if kind:
            raise SystemExit(f"possible {kind} secret in {label}; bundle was not written")
    for path in paths:
        entry = tree_entry(repo, tree_oid, path)
        if not entry or entry["type"] != "blob":
            continue
        hit = scan_blob_for_secret(repo, entry["oid"])
        if hit:
            kind, byte_offset = hit
            raise SystemExit(
                f"possible {kind} secret in CANDIDATE:{safe_display_path(path)} near byte {byte_offset}; bundle was not written"
            )


def context_secret_preflight(contexts: list[dict[str, Any]]) -> None:
    for item in contexts:
        content = item.get("content")
        if content is None:
            continue
        kind = secret_kind(content.encode("utf-8"))
        if kind:
            raise SystemExit(
                f"possible {kind} secret in {item['tree']}:{item['path']}; bundle was not written"
            )


def validate_evidence(value: Any, tree_oid: str, supplied: bool) -> dict[str, Any]:
    if not supplied:
        return {"candidate_tree_oid": tree_oid, "commands": []}
    if not isinstance(value, dict) or set(value) != {"candidate_tree_oid", "commands"}:
        raise SystemExit("evidence must contain exactly candidate_tree_oid and commands")
    if value["candidate_tree_oid"] != tree_oid:
        raise SystemExit("evidence candidate_tree_oid does not match the bundled candidate tree")
    commands = value["commands"]
    if not isinstance(commands, list) or not commands:
        raise SystemExit("evidence commands must be a non-empty array")
    for index, command in enumerate(commands):
        if not isinstance(command, dict) or set(command) != {"command", "exit_code", "summary"}:
            raise SystemExit(f"evidence commands[{index}] has invalid keys")
        if not isinstance(command["command"], str) or not command["command"].strip():
            raise SystemExit(f"evidence commands[{index}].command must be non-empty")
        if type(command["exit_code"]) is not int:
            raise SystemExit(f"evidence commands[{index}].exit_code must be an integer")
        if command["exit_code"] != 0:
            raise SystemExit(f"evidence commands[{index}].exit_code must be zero")
        if not isinstance(command["summary"], str) or not command["summary"].strip():
            raise SystemExit(f"evidence commands[{index}].summary must be non-empty")
    try:
        canonical_bytes(value)
    except UnicodeEncodeError as exc:
        raise SystemExit("evidence must be valid UTF-8") from exc
    return value


def project_payload(data: bytes, limit: int = ITEM_LIMIT) -> dict[str, Any]:
    result: dict[str, Any] = {"byte_count": len(data), "sha256": sha256(data)}
    try:
        text = data.decode("utf-8", "strict")
    except UnicodeDecodeError:
        result.update({"encoding": "binary", "truncated": True, "content": None})
        return result
    result["encoding"] = "utf-8"
    if limit <= 0:
        result.update({"truncated": bool(data), "content": None})
    elif len(data) <= limit:
        result.update({"truncated": False, "content": text})
    else:
        marker = "\n... truncated ...\n"
        available = max(0, limit - len(marker.encode("utf-8")))
        head_bytes = available // 2
        tail_bytes = available - head_bytes
        head = data[:head_bytes].decode("utf-8", "ignore")
        tail = data[-tail_bytes:].decode("utf-8", "ignore") if tail_bytes else ""
        result.update({"truncated": True, "content": f"{head}{marker}{tail}"})
    return result


def project_blob(
    repo: Path, entry: dict[str, str], limit: int = ITEM_LIMIT
) -> dict[str, Any]:
    """Project a Git blob without buffering untrusted blob contents in memory."""
    byte_count = blob_size(repo, entry)
    marker = b"\n... truncated ...\n"
    available = max(0, limit - len(marker)) if limit >= len(marker) else 0
    head_limit = available // 2
    tail_limit = available - head_limit
    keep_full = limit > 0 and byte_count <= limit
    full = bytearray()
    head = bytearray()
    tail = bytearray()
    digest = hashlib.sha256()
    decoder = codecs.getincrementaldecoder("utf-8")("strict")
    utf8 = True
    actual_count = 0
    process = subprocess.Popen(
        ["git", "-C", str(repo), "cat-file", "blob", entry["oid"]],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert process.stdout is not None
    while chunk := process.stdout.read(SCAN_CHUNK):
        actual_count += len(chunk)
        digest.update(chunk)
        if b"\0" in chunk:
            utf8 = False
        if utf8:
            try:
                decoder.decode(chunk, final=False)
            except UnicodeDecodeError:
                utf8 = False
        if keep_full:
            full.extend(chunk)
        else:
            if len(head) < head_limit:
                head.extend(chunk[: head_limit - len(head)])
            if tail_limit:
                tail.extend(chunk)
                del tail[:-tail_limit]
    process.stdout.close()
    stderr = process.stderr.read() if process.stderr is not None else b""
    returncode = process.wait()
    if returncode or actual_count != byte_count:
        message = stderr.decode("utf-8", "replace").strip()
        raise SystemExit(message or f"failed to read Git blob {entry['oid']}")
    if utf8:
        try:
            decoder.decode(b"", final=True)
        except UnicodeDecodeError:
            utf8 = False
    result: dict[str, Any] = {
        "byte_count": byte_count,
        "sha256": digest.hexdigest(),
        "encoding": "utf-8" if utf8 else "binary",
    }
    if not utf8:
        result.update({"truncated": True, "content": None})
    elif keep_full:
        result.update({"truncated": False, "content": bytes(full).decode("utf-8")})
    elif limit < len(marker):
        result.update({"truncated": bool(byte_count), "content": None})
    else:
        result.update(
            {
                "truncated": byte_count > limit,
                "content": (bytes(head) + marker + bytes(tail)).decode("utf-8", "ignore"),
            }
        )
    return result


def collect_changed_path_gaps(
    repo: Path, tree_oid: str, paths: list[str]
) -> list[dict[str, str]]:
    gaps: list[dict[str, str]] = []
    for path in paths:
        entry = tree_entry(repo, tree_oid, path)
        if secret_kind(path.encode("utf-8", "surrogateescape")):
            gaps.append(
                {
                    "path": safe_display_path(path),
                    "reason": "credential_like_path_redacted",
                    "tree": "CANDIDATE" if entry else "BASE",
                }
            )
        if entry is None:
            continue
        if entry["mode"] == "120000":
            gaps.append({"path": safe_display_path(path), "reason": "symlink", "tree": "CANDIDATE"})
        elif entry["mode"] == "160000":
            status = git_text(repo, "status", "--porcelain", "--ignore-submodules=none", "--", path)
            reason = "dirty_submodule" if status.strip() else "gitlink"
            gaps.append({"path": safe_display_path(path), "reason": reason, "tree": "CANDIDATE"})
        elif git(repo, "cat-file", "-t", entry["oid"], check=False).strip() != b"blob":
            gaps.append({"path": safe_display_path(path), "reason": "missing_blob", "tree": "CANDIDATE"})
    return gaps


def dirty_submodule_gaps(repo: Path, tree_oid: str) -> list[dict[str, str]]:
    gaps: list[dict[str, str]] = []
    for line in git_text(repo, "submodule", "status", "--recursive", check=False).splitlines():
        parts = line.lstrip("-+U ").split()
        if len(parts) < 2:
            continue
        path = parts[1]
        entry = tree_entry(repo, tree_oid, path)
        status = git_text(repo, "status", "--porcelain", "--ignore-submodules=none", "--", path)
        if entry and entry["mode"] == "160000" and status.strip():
            gaps.append(
                {"path": safe_display_path(path), "reason": "dirty_submodule", "tree": "CANDIDATE"}
            )
    return gaps


def unique_gaps(items: list[dict[str, str]]) -> list[dict[str, str]]:
    result: list[dict[str, str]] = []
    seen: set[tuple[str, str, str]] = set()
    for item in items:
        key = (item["tree"], item["path"], item["reason"])
        if key not in seen:
            seen.add(key)
            result.append(item)
    return result


def load_context_requests(
    path: str | None,
) -> tuple[list[dict[str, Any]], str | None, str | None, str | None]:
    if not path:
        return [], None, None, None
    document = load_json(path, {})
    if not isinstance(document, dict):
        raise SystemExit("context request file must be a reducer result object")
    for key in ("candidate_tree_oid", "base_oid", "contract_inventory_sha256", "context_requests"):
        if key not in document:
            raise SystemExit(f"context request file is missing {key}")
    bound_tree = document["candidate_tree_oid"]
    bound_base = document["base_oid"]
    inventory_sha = document["contract_inventory_sha256"]
    value = document["context_requests"]
    if not isinstance(value, list):
        raise SystemExit("context_requests must be a list")
    for name, oid in (("candidate_tree_oid", bound_tree), ("base_oid", bound_base)):
        if (
            not isinstance(oid, str)
            or len(oid) not in (40, 64)
            or any(character not in "0123456789abcdef" for character in oid)
        ):
            raise SystemExit(f"context request {name} is invalid")
    if (
        not isinstance(inventory_sha, str)
        or len(inventory_sha) != 64
        or any(character not in "0123456789abcdef" for character in inventory_sha)
    ):
        raise SystemExit("context request contract_inventory_sha256 is invalid")
    return value, bound_tree, bound_base, inventory_sha


def resolve_contexts(
    repo: Path,
    base_oid: str,
    tree_oid: str,
    requests: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    contexts: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    embedded = 0
    for request in requests:
        try:
            selector = request["tree"]
            path = normalize_path(request["path"])
        except (KeyError, ValueError) as exc:
            raise SystemExit(f"invalid context request: {exc}") from exc
        if selector not in ("BASE", "CANDIDATE"):
            raise SystemExit("context tree must be BASE or CANDIDATE")
        key = (selector, path)
        if key in seen:
            continue
        seen.add(key)
        bound_oid = base_oid if selector == "BASE" else tree_oid
        entry = tree_entry(repo, bound_oid, path)
        item: dict[str, Any] = {"tree": selector, "tree_oid": bound_oid, "path": path}
        if entry is None:
            item["evidence_gap"] = "missing_path"
        elif entry["mode"] == "120000":
            item.update(entry, evidence_gap="symlink")
        elif entry["mode"] == "160000":
            item.update(entry, evidence_gap="gitlink")
        elif entry["type"] != "blob":
            item.update(entry, evidence_gap="special_file")
        else:
            object_type = git(repo, "cat-file", "-t", entry["oid"], check=False).strip()
            if object_type != b"blob":
                item.update(entry, evidence_gap="missing_blob")
            else:
                remaining = max(0, CONTEXT_LIMIT - embedded)
                projection = project_blob(repo, entry, min(ITEM_LIMIT, remaining))
                content = projection.get("content")
                if content is not None:
                    embedded += len(content.encode("utf-8"))
                item.update(entry, **projection)
                if projection["encoding"] == "binary":
                    item["evidence_gap"] = "non_utf8_blob"
                elif remaining == 0 or (content is None and projection["byte_count"]):
                    item["evidence_gap"] = "context_total_limit"
        contexts.append(item)
    return contexts


def limited_diff(
    repo: Path, base_oid: str, tree_oid: str, source_path: str, destination_path: str
) -> tuple[str, bool]:
    pathspecs = [f":(literal){source_path}"]
    if destination_path != source_path:
        pathspecs.append(f":(literal){destination_path}")
    process = subprocess.Popen(
        [
            "git",
            "-C",
            str(repo),
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--text",
            "--find-renames",
            base_oid,
            tree_oid,
            "--",
            *pathspecs,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert process.stdout is not None
    data = process.stdout.read(ITEM_LIMIT + 1)
    truncated = len(data) > ITEM_LIMIT
    if truncated:
        process.kill()
        data = data[:ITEM_LIMIT]
    _, stderr = process.communicate()
    if not truncated and process.returncode:
        raise SystemExit(stderr.decode("utf-8", "replace").strip() or "git diff failed")
    if secret_kind(data):
        return "(diff omitted because it contains credential-like bytes)", True
    try:
        text = data.decode("utf-8", "strict")
    except UnicodeDecodeError:
        return "(non-UTF-8 diff omitted)", False
    return text + ("\n... diff truncated at 64 KiB ...\n" if truncated else ""), False


def fenced(label: str, content: str, language: str = "") -> str:
    return f"### {label}\n\n```{language}\n{content.rstrip()}\n```\n"


def build_artifact(args: argparse.Namespace) -> tuple[dict[str, Any], dict[str, Any]]:
    repo = Path(args.repo).resolve()
    current_base_oid = git_text(repo, "rev-parse", f"{args.base}^{{commit}}").strip()
    head_oid, current_tree_oid = candidate_tree(repo)
    inventory = load_json(args.inventory_file, [])
    raw_evidence = load_json(args.evidence_file, {})
    requests, bound_tree_oid, bound_base_oid, bound_inventory_sha = load_context_requests(
        args.context_request_file
    )
    inventory_sha = sha256(canonical_bytes(inventory))
    if bound_inventory_sha is not None and bound_inventory_sha != inventory_sha:
        raise SystemExit("context request inventory does not match --inventory-file")
    tree_oid = bound_tree_oid or current_tree_oid
    base_oid = bound_base_oid or current_base_oid
    if git(repo, "cat-file", "-t", tree_oid, check=False).strip() != b"tree":
        raise SystemExit("bound candidate tree is not available in the repository")
    if git(repo, "cat-file", "-t", base_oid, check=False).strip() != b"commit":
        raise SystemExit("bound base commit is not available in the repository")
    paths = changed_paths(repo, base_oid, tree_oid)
    evidence = validate_evidence(raw_evidence, tree_oid, args.evidence_file is not None)
    task = args.task or ""
    try:
        task_bytes = task.encode("utf-8", "strict")
    except UnicodeEncodeError as exc:
        raise SystemExit("task must be valid UTF-8") from exc
    if len(task_bytes) > ITEM_LIMIT:
        raise SystemExit("task exceeds the 64 KiB bundle item limit")
    secret_preflight(repo, tree_oid, paths, task, inventory, evidence)
    contexts = resolve_contexts(
        repo,
        base_oid,
        tree_oid,
        requests,
    )
    context_secret_preflight(contexts)
    evidence_projection = project_payload(canonical_bytes(evidence))
    metadata = {
        "schema_version": 1,
        "base_oid": base_oid,
        "current_base_oid": current_base_oid,
        "head_oid": head_oid,
        "candidate_tree_oid": tree_oid,
        "contract_inventory_sha256": inventory_sha,
        "current_candidate_tree_oid": current_tree_oid,
        "changed_path_count": len(paths),
        "changed_paths_sha256": sha256(canonical_bytes(paths)),
        "evidence_candidate_tree_oid": evidence["candidate_tree_oid"],
        "evidence": {key: value for key, value in evidence_projection.items() if key != "content"},
        "context_blob_metadata": [
            {key: value for key, value in item.items() if key != "content"} for item in contexts
        ],
        "evidence_gaps": unique_gaps(
            collect_changed_path_gaps(repo, tree_oid, paths)
            + dirty_submodule_gaps(repo, tree_oid)
        ),
        "binary_path_metadata": [],
    }
    return metadata, {
        "repo": repo,
        "base_oid": base_oid,
        "tree_oid": tree_oid,
        "paths": paths,
        "evidence": evidence_projection,
        "contexts": contexts,
    }


def build_bundle(args: argparse.Namespace, metadata: dict[str, Any], data: dict[str, Any]) -> str:
    repo = data["repo"]
    base_oid = data["base_oid"]
    tree_oid = data["tree_oid"]
    total, per_file = changed_lines(repo, base_oid, tree_oid)
    binary_files = [item for item in per_file if item["binary"]]
    metadata["binary_path_metadata"] = [
        path_metadata(repo, base_oid, tree_oid, item["source_path"], item["path"])
        for item in binary_files
    ]
    stat = redact_sensitive_lines(
        git_text(repo, "diff", "--no-ext-diff", "--no-textconv", "--stat", base_oid, tree_oid)
    )
    name_status = redact_sensitive_lines(
        git_text(
            repo,
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--name-status",
            "--find-renames",
            base_oid,
            tree_oid,
        )
    )
    untracked = redact_sensitive_lines(git_text(repo, "ls-files", "--others", "--exclude-standard"))
    lines = [
        f"<!-- fsd-artifact: {canonical_bytes(metadata).decode('utf-8')} -->",
        "# Codex Verification Bundle",
        "",
        f"Repo: `{repo}`",
        f"Base OID: `{base_oid}`",
        f"Candidate tree OID: `{tree_oid}`",
        f"Contract inventory SHA-256: `{metadata['contract_inventory_sha256']}`",
        f"Changed lines: {total}",
        "",
        "## Task Spec",
        "",
        args.task.strip() or "(no task spec provided)",
        "",
        "## Deterministic Verification Evidence",
        "",
        "```json",
        json.dumps(data["evidence"], ensure_ascii=False, sort_keys=True, indent=2),
        "```",
        "",
        "## Bound Context Blobs",
        "",
        "```json",
        json.dumps(data["contexts"], ensure_ascii=False, sort_keys=True, indent=2),
        "```",
        "",
        "## Evidence Gaps",
        "",
        "```json",
        json.dumps(metadata["evidence_gaps"], ensure_ascii=False, sort_keys=True, indent=2),
        "```",
        "",
        "## Binary Path Metadata",
        "",
        "```json",
        json.dumps(metadata["binary_path_metadata"], ensure_ascii=False, sort_keys=True, indent=2),
        "```",
        "",
        "## Diff Stat",
        "",
        "```",
        stat.rstrip(),
        "```",
        "",
        "## Name Status",
        "",
        "```",
        name_status.rstrip(),
        "```",
        "",
        "## Untracked Files",
        "",
        "```",
        untracked.rstrip() or "(none)",
        "```",
        "",
    ]
    changed_blob_bytes = sum(
        blob_size(repo, tree_entry(repo, tree_oid, path))
        + blob_size(repo, tree_entry(repo, base_oid, path))
        for path in data["paths"]
    )
    if not binary_files and total <= args.max_full_diff_lines and changed_blob_bytes <= FULL_DIFF_BYTE_LIMIT:
        full_diff = git(
            repo, "diff", "--no-ext-diff", "--no-textconv", "--text", base_oid, tree_oid
        )
        if secret_kind(full_diff):
            for path in data["paths"]:
                entry = tree_entry(repo, base_oid, path)
                if entry and entry["type"] == "blob" and scan_blob_for_secret(repo, entry["oid"]):
                    metadata["evidence_gaps"].append(
                        {
                            "path": safe_display_path(path),
                            "reason": "credential_like_diff_omitted",
                            "tree": "BASE",
                        }
                    )
            lines.extend(
                [
                    "## Full Diff Omitted",
                    "",
                    "Candidate diff omitted because it contains credential-like bytes. Candidate blobs were scanned separately.",
                    "",
                ]
            )
        else:
            lines.extend(
                [
                    "## Full Diff",
                    "",
                    "```diff",
                    full_diff.decode("utf-8", "strict").rstrip(),
                    "```",
                    "",
                ]
            )
    else:
        sample_candidates = [
            candidate
            for candidate in per_file
            if not candidate["binary"]
        ]
        if len(sample_candidates) > args.max_files:
            raise SystemExit(
                f"large diff has {len(sample_candidates)} text paths; "
                f"--max-files {args.max_files} would omit review evidence"
            )
        lines.extend(
            [
                "## Large Diff Sample",
                "",
                "Full diff omitted because it exceeds the inline threshold.",
                "",
            ]
        )
        for item in sample_candidates:
            projection, credential_omitted = limited_diff(
                repo, base_oid, tree_oid, item["source_path"], item["path"]
            )
            if credential_omitted:
                metadata["evidence_gaps"].append(
                    {
                        "path": safe_display_path(item["source_path"]),
                        "reason": "credential_like_diff_omitted",
                        "tree": "BASE",
                    }
                )
            lines.append(fenced(safe_display_path(item["display"]), projection, "diff"))
    metadata["evidence_gaps"] = unique_gaps(metadata["evidence_gaps"])
    # The diff sections above can append gaps, so rewrite the already-emitted JSON payload
    # and the leading metadata comment. Offset 3 skips the heading, blank line, and fence.
    evidence_gap_index = lines.index("## Evidence Gaps") + 3
    lines[evidence_gap_index] = json.dumps(
        metadata["evidence_gaps"], ensure_ascii=False, sort_keys=True, indent=2
    )
    lines[0] = f"<!-- fsd-artifact: {canonical_bytes(metadata).decode('utf-8')} -->"
    bundle = "\n".join(lines)
    if len(bundle.encode("utf-8")) > BUNDLE_LIMIT:
        raise SystemExit("bundle exceeds the 512 KiB total limit")
    final_match = secret_match(bundle.encode("utf-8"))
    if final_match:
        raise SystemExit(
            f"possible {final_match[0]} secret in assembled bundle; bundle was not written"
        )
    return bundle


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--task")
    parser.add_argument("--output")
    parser.add_argument("--inventory-file")
    parser.add_argument("--evidence-file")
    parser.add_argument("--context-request-file")
    parser.add_argument("--reviewer-identity-output")
    parser.add_argument("--candidate-tree-only", action="store_true")
    parser.add_argument("--max-full-diff-lines", type=int, default=2000)
    parser.add_argument("--max-files", type=int, default=5)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    metadata, data = build_artifact(args)
    if args.candidate_tree_only:
        print(canonical_bytes(metadata).decode("utf-8"))
        return 0
    if args.task is None or args.output is None:
        raise SystemExit("--task and --output are required unless --candidate-tree-only is used")
    bundle = build_bundle(args, metadata, data)
    bundle_bytes = bundle.encode("utf-8")
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(bundle_bytes)
    if args.reviewer_identity_output:
        identity = {
            "base_oid": metadata["base_oid"],
            "candidate_tree_oid": metadata["candidate_tree_oid"],
            "bundle_sha256": sha256(bundle_bytes),
            "contract_inventory_sha256": metadata["contract_inventory_sha256"],
        }
        identity_output = Path(args.reviewer_identity_output)
        identity_output.parent.mkdir(parents=True, exist_ok=True)
        identity_output.write_bytes(canonical_bytes(identity))
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
