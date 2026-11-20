#!/usr/bin/env python3
"""Frontmatter keys that grant a skill privileges, shared by the wrapper sync, the
wrapper integrity check and the skill audit scanner.

A workspace skill that carries `imported-from:` came from outside the user's own
hands. Its generated wrapper is model-invocable, so the wrapper must not forward keys
that pre-approve tools or change where the skill runs. The audit scanner flags the same
keys in any skill, so one list keeps the three scripts from drifting apart.
"""

from __future__ import annotations

IMPORTED_MARKER_KEY = "imported-from"
PRIVILEGED_KEYS = ("allowed-tools", "context", "agent")
