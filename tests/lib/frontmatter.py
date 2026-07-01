"""Frontmatter helpers for shell-driven regression tests."""

from __future__ import annotations

import json
import re


def unquote(value: str, *, json_double: bool = False) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        if json_double:
            try:
                return json.loads(value)
            except json.JSONDecodeError:
                pass
        return value[1:-1].replace(r"\"", '"').replace(r"\\", "\\")
    if len(value) >= 2 and value[0] == value[-1] == "'":
        return value[1:-1]
    return value


def description_from_frontmatter(text: str) -> str:
    match = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not match:
        return ""

    lines = match.group(1).splitlines()
    desc_lines: list[str] = []
    capture_block = False
    for raw in lines:
        if capture_block:
            if re.match(r"^[A-Za-z0-9_-]+:\s*", raw):
                break
            desc_lines.append(raw.strip())
            continue

        if raw.startswith("description:"):
            value = raw.split(":", 1)[1].strip()
            if value in {"|", ">", "|-", ">-", "|+", ">+"}:
                capture_block = True
                continue
            desc_lines = [unquote(value)]
            break

    return re.sub(r"\s+", " ", " ".join(line for line in desc_lines if line)).strip()
