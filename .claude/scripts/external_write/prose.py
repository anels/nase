from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

from .classification import gh_noun_first

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
