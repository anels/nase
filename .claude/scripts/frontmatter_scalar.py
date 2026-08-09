"""Small YAML-frontmatter scalar helpers used by workspace lifecycle scripts."""

from __future__ import annotations

import re


def extract_frontmatter_scalar(text: str, key: str) -> tuple[str | None, bool]:
    """Return the first value for ``key`` plus whether the frontmatter contract holds.

    The flag is True when the key is absent (callers supply their own default) or
    appears exactly once with a non-empty value. A duplicate or empty key returns
    False so callers can fail closed instead of guessing which value wins.
    """
    frontmatter = re.match(r"^---\s*\n(.*?)\n---\s*(?:\n|$)", text, re.DOTALL)
    if not frontmatter:
        return None, True
    pattern = re.compile(rf"^{re.escape(key)}\s*:(.*)$", re.IGNORECASE)
    values = [
        found.group(1).strip()
        for line in frontmatter.group(1).splitlines()
        if (found := pattern.match(line))
    ]
    if not values:
        return None, True
    return values[0], len(values) == 1 and bool(values[0])


def normalize_scalar(raw: str) -> str:
    """Normalize one simple scalar without treating a quoted ``#`` as a comment."""
    value = raw.strip()
    if not value or value[0] not in {"'", '"'}:
        return value.split(" #", 1)[0].strip().lower()

    quote = value[0]
    parsed: list[str] = []
    index = 1
    while index < len(value):
        char = value[index]
        if quote == '"' and char == "\\" and index + 1 < len(value):
            parsed.extend((char, value[index + 1]))
            index += 2
            continue
        if quote == "'" and char == quote and index + 1 < len(value) and value[index + 1] == quote:
            parsed.append(quote)
            index += 2
            continue
        if char == quote:
            trailer = value[index + 1 :].strip()
            if trailer and not trailer.startswith("#"):
                return value.lower()
            return "".join(parsed).strip().lower()
        parsed.append(char)
        index += 1
    return value.lower()


def canonical_bool(raw: str | None) -> tuple[bool, bool]:
    """Parse the lifecycle's deliberately narrow unquoted YAML boolean contract."""
    if raw is None:
        return False, True
    value = raw.strip()
    if value[:1] in {"'", '"'}:
        return False, False
    value = value.split(" #", 1)[0].strip().lower()
    if value == "true":
        return True, True
    if value == "false":
        return False, True
    return False, False
