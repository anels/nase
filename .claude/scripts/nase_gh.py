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


def _tokens(*alternatives: str) -> re.Pattern[str]:
    return re.compile("|".join(alternatives))


# Ordered most-actionable first. `transient-network` deliberately outranks
# `not-found`: the only caller that acts on the difference is one that retries, and
# there a wrong `not-found` turns a recoverable blip into a permanent failure, while a
# wrong `transient-network` costs one wasted retry.
_RATE_LIMIT_RE = _tokens("rate limit", "secondary rate")
# `auth` carries a carve-out because as a bare substring it also matched the `author`
# that gh prints routinely, turning a not-found into the `auth-failed` that
# `citation-validator.py` reads as UNKNOWN. It excludes `author`/`authored`/`authorship`
# and keeps `oauth`, `reauthenticate`, `authoriz*`, `authoris*`. The other tokens stay
# plain substrings because gh inflects them freely ("rate limits", "resolve hostname").
_AUTH_RE = _tokens(
    r"auth(?!or(?!i[sz]))",
    "forbidden",
    "login",
    "log in",
    "bad credentials",
    "permission denied",
)
_NETWORK_RE = _tokens(
    "network",
    "connection",
    "resolve host",
    "server error",
    "timed out",
    "timeout",
)
_NOT_FOUND_RE = _tokens("not found", "could not resolve to")

_HTTP_STATUS_RE = re.compile(r"\bhttp[\s:]+(\d{3})\b")
# Nine digits, not four: GitHub's secondary-limit backoff regularly runs to five, and
# truncating it retries an order of magnitude early and deepens the limit.
_RETRY_AFTER_RE = re.compile(r"(?:retry[- ]after|wait)\D{0,10}([0-9]{1,9})")


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

    if 429 in statuses or _RATE_LIMIT_RE.search(lowered):
        return "rate-limited", wait
    if statuses & {401, 403} or _AUTH_RE.search(lowered):
        return "auth-failed", None
    if any(code >= 500 for code in statuses) or _NETWORK_RE.search(lowered):
        return "transient-network", None
    if statuses & {404, 410} or _NOT_FOUND_RE.search(lowered):
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
