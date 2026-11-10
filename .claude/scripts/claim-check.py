#!/usr/bin/env python3
"""Claim check: does a 'tests pass / build clean' claim have a passing run behind it?

Reads a Claude Code Stop-hook payload on stdin (transcript_path, session_id),
parses the transcript, and emits a single JSON systemMessage when a success
claim is not backed by a passing verification run, or when files changed after
the last passing run. Fail-open on every error: never blocks, never raises.
"""

import contextlib
import json
import os
import re
import sys
from pathlib import Path

CLAIM_PATTERNS = [
    r"\ball tests pass\b",
    r"\btests? (pass|passed|green)\b",
    r"\bbuild (is )?(clean|green|pass(?:ed)?)\b",
    r"\blint (is )?(clean|pass(?:ing|ed)?)\b",
    r"\bverification (pass(?:ed)?)\b",
    r"\bverified\b",
    r"测试(?:全部)?通过",
    r"验证通过",
    r"构建通过",
    r"lint\s*通过",
]

VERIFY_CMD = re.compile(
    r"(pytest|npm (run )?(test|lint|build)|pnpm (test|lint|build)|yarn (test|lint|build)"
    r"|cargo (test|build|clippy)|go (test|build)|mvn (test|compile|verify)"
    r"|gradle (test|build)|dotnet (test|build)|make( (test|lint|check))?"
    r"|tox|ruff (check|format)|eslint|tsc(\s|$)|mypy|pyright|shellcheck"
    r"|npm run (check|typecheck|type-check))",
    re.IGNORECASE,
)

EDIT_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}


def load_transcript(path):
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return out


def blocks(entry):
    msg = entry.get("message")
    if isinstance(msg, dict):
        c = msg.get("content")
        if isinstance(c, list):
            return c
    c = entry.get("content")
    if isinstance(c, list):
        return c
    return []


def main():
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        return

    transcript_path = payload.get("transcript_path") or payload.get("agent_transcript_path")
    session_id = payload.get("session_id") or "unknown"
    if not transcript_path or not os.path.isfile(transcript_path):
        return

    try:
        entries = load_transcript(transcript_path)
    except Exception:
        return

    # First pass: claims and edits.
    turn = 0
    last_claim_idx = -1
    last_edit_idx = -1
    claim_re = re.compile("|".join(CLAIM_PATTERNS), re.IGNORECASE)

    for entry in entries:
        msg = entry.get("message")
        role = (msg.get("role") if isinstance(msg, dict) else None) or entry.get("role")
        bks = blocks(entry)
        if role == "assistant":
            turn += 1
            text_parts = [b.get("text", "") for b in bks if isinstance(b, dict) and b.get("type") == "text"]
            joined = " ".join(text_parts)
            if claim_re.search(joined):
                last_claim_idx = turn
            for b in bks:
                if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") in EDIT_TOOLS:
                    last_edit_idx = turn

    # Second pass: last successful verification run's issuing turn.
    last_success_turn = 0
    verify_turn_of = {}
    turn = 0
    for entry in entries:
        msg = entry.get("message") if isinstance(entry.get("message"), dict) else None
        role = (msg.get("role") if msg else None) or entry.get("role")
        bks = blocks(entry)
        if role == "assistant":
            turn += 1
            for b in bks:
                if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Bash":
                    cmd = (b.get("input") or {}).get("command", "")
                    if VERIFY_CMD.search(cmd or ""):
                        verify_turn_of[b.get("id")] = turn
        elif role == "user":
            for b in bks:
                if isinstance(b, dict) and b.get("type") == "tool_result":
                    tid = b.get("tool_use_id")
                    if tid in verify_turn_of and not b.get("is_error"):
                        last_success_turn = max(last_success_turn, verify_turn_of[tid])

    if last_claim_idx < 0:
        return  # no claim, nothing to check

    # Dedupe marker (best-effort; skip silently if no writable workspace).
    nase_root = os.environ.get("NASE_ROOT", "")
    marker = None
    if nase_root:
        marker_dir = Path(nase_root) / "workspace" / "tmp"
        try:
            marker_dir.mkdir(parents=True, exist_ok=True)
            marker = marker_dir / f"claim-check-{session_id}.state"
        except Exception:
            marker = None

    state = f"{last_claim_idx}:{last_success_turn}:{last_edit_idx}:{transcript_path}"
    if marker is not None:
        with contextlib.suppress(Exception):
            if marker.exists() and marker.read_text().strip() == state:
                return  # already warned for this state

    warn = None
    if last_success_turn == 0:
        warn = "a success claim was made but no passing verification run was found in this session"
    elif last_success_turn < last_claim_idx and last_edit_idx > last_success_turn:
        warn = "files were edited after the last passing verification run, but a success claim followed"
    elif last_success_turn < last_claim_idx and last_edit_idx <= last_success_turn:
        # claim after a passing run with no intervening edits: proven, stay silent
        pass

    if warn is None:
        return

    if marker is not None:
        with contextlib.suppress(Exception):
            marker.write_text(state)

    msg = "[claim-check] " + warn + ". Re-run the verification command and confirm it passes before finishing."
    print(json.dumps({"systemMessage": msg}))


if __name__ == "__main__":
    main()
