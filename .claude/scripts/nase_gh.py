#!/usr/bin/env python3
"""One bounded `gh` runner and one reading of what `gh` said when it failed.

Every caller shares this classification, so the same stderr cannot come out
`not-found` in one script and `rate-limited` in another, and two scripts cannot
disagree about whether a failed read is worth retrying.

A bare status code is not matched as a substring, because in the one place it matters
it is not a status: `gh pr view 503` that fails with "pull request not found" carries
"503" in its own stderr, and reading that as a server error turns a permanent failure
into one that is retried and then reported as transient. Status codes are matched only
in the `HTTP <code>` shape `gh` actually prints.

`run` never raises. A hang and a crash are different facts, so a timeout comes back as
exit 124 and a missing binary as exit 127 - the shell's own codes - rather than as an
exception each call site would have to remember to catch.
"""

from __future__ import annotations

import re
import subprocess

GH_TIMEOUT_SECONDS = 30
TIMEOUT_RETURNCODE = 124
MISSING_BINARY_RETURNCODE = 127

# Ordered most-actionable first. `transient-network` deliberately outranks
# `not-found`: the only caller that acts on the difference is one that retries, and
# there a wrong `not-found` turns a recoverable blip into a permanent failure, while a
# wrong `transient-network` costs one wasted retry.
_RATE_LIMIT_TOKENS = ("rate limit", "secondary rate")
_AUTH_TOKENS = ("auth", "login", "unauthorized", "forbidden")
_NETWORK_TOKENS = (
    "network",
    "connection",
    "resolve host",
    "server error",
    "timed out",
    "timeout",
)
_NOT_FOUND_TOKENS = ("not found", "could not resolve to")

_HTTP_STATUS_RE = re.compile(r"\bhttp[\s:]+(\d{3})\b")
_RETRY_AFTER_RE = re.compile(r"(?:retry[- ]after|wait)\D{0,10}([0-9]{1,4})")


def failure_category(stderr: str) -> tuple[str, int | None]:
    """Classify a failed `gh` invocation from its stderr.

    Returns the category and, for `rate-limited`, the seconds the authority asked the
    caller to wait when it named one. Categories: `rate-limited`, `auth-failed`,
    `transient-network`, `not-found`, `command-failed`.
    """
    lowered = stderr.lower()
    statuses = {int(code) for code in _HTTP_STATUS_RE.findall(lowered)}
    wait_match = _RETRY_AFTER_RE.search(lowered)
    wait = int(wait_match.group(1)) if wait_match else None

    if 429 in statuses or any(token in lowered for token in _RATE_LIMIT_TOKENS):
        return "rate-limited", wait
    if statuses & {401, 403} or any(token in lowered for token in _AUTH_TOKENS):
        return "auth-failed", None
    if any(code >= 500 for code in statuses) or any(
        token in lowered for token in _NETWORK_TOKENS
    ):
        return "transient-network", None
    if statuses & {404, 410} or any(token in lowered for token in _NOT_FOUND_TOKENS):
        return "not-found", None
    return "command-failed", None


def run(
    args: list[str], *, timeout: float = GH_TIMEOUT_SECONDS
) -> subprocess.CompletedProcess[str]:
    """Run one read with both streams captured and a wall-clock bound, never raising.

    A timeout yields exit 124 with whatever the process had already written; a missing
    or unrunnable binary yields exit 127 with the OS error as stderr.
    """
    try:
        return subprocess.run(
            args, text=True, capture_output=True, timeout=timeout, check=False
        )
    except subprocess.TimeoutExpired as exc:
        return subprocess.CompletedProcess(
            args,
            TIMEOUT_RETURNCODE,
            _as_text(exc.stdout),
            _as_text(exc.stderr) or f"timed out after {timeout}s",
        )
    except OSError as exc:
        return subprocess.CompletedProcess(
            args, MISSING_BINARY_RETURNCODE, "", str(exc)
        )


def _as_text(stream: str | bytes | None) -> str:
    if stream is None:
        return ""
    if isinstance(stream, bytes):
        return stream.decode("utf-8", "replace")
    return stream
