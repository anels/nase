#!/usr/bin/env python3
"""Shared reader for `workspace/kb/.domain-map.md`.

Every script that asks "which KB files does the map route to?" must agree on two
things: what counts as a comment, and what counts as a row. When each reader
carries its own answer, a path inside a comment or an indented row is mapped for
one script and missing for another, and nothing reports the disagreement.
"""

from __future__ import annotations

import re

# A comment on its own lines takes its newline with it; an inline one leaves the row break alone.
COMMENT_RE = re.compile(r"^[ \t]*<!--.*?-->[ \t]*\n?|[ \t]*<!--.*?-->", re.S | re.M)
# Same row shape `kb-domain-resolve.sh` accepts: optional indent, `- key → target`.
ROW_RE = re.compile(r"^\s*-\s+(.+?)\s*→\s+([^ \t\[]+)")


def strip_comments(text: str) -> str:
    return COMMENT_RE.sub("", text)
