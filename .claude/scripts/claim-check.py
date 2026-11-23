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
import shlex
import sys
from pathlib import Path

CLAIM_PATTERNS = [
    r"\ball tests pass\b",
    r"\btests? (pass|passed|green)\b",
    r"\bbuild (is )?(clean|green|pass(?:ed)?)\b",
    r"\blint (is )?(clean|pass(?:ing|ed)?)\b",
    r"\bverification (pass(?:ed)?)\b",
    r"\bverified (?:that )?(?:all )?(?:the )?(?:tests?|build|lint|typecheck)\b",
    r"测试(?:全部)?通过",
    r"验证通过",
    r"构建通过",
    r"lint\s*通过",
]

VERIFY_HEAD = re.compile(
    r"^(pytest|npm (run )?(test|lint|build)|pnpm (run )?(test|lint|build)|yarn (run )?(test|lint|build)"
    r"|cargo (test|build|clippy)|go (test|build)|mvn (test|compile|verify)"
    r"|gradle (test|build)|dotnet (test|build)"
    r"|make(?: -\S+(?: \d+)?)*(?:\s*$|\s+(?:(?:test|tests|lint|check|typecheck|verify)(?:-[\w-]+)?|build|ci))"
    r"|tox|ruff (check|format --check)|eslint|tsc|mypy|pyright|shellcheck"
    r"|npm run (check|typecheck|type-check)"
    r"|bash (?:\S*/)?tests/(?:check-[^\s/]+\.sh|(?:[^\s/]+/)*test-[^\s/]+\.sh))(\s|:|$)",
)
WRAPPERS = {"time", "command", "exec", "nohup", "env", "sudo"}
PREFIX_RUNNERS = [("uv", "run"), ("poetry", "run"), ("pnpm", "exec"), ("npx",), ("python", "-m"), ("python3", "-m")]
OPERATORS = {"&&", "||", ";", "|", "&", "|&"}
INPLACE_FLAG = re.compile(r"^-(?![MmIeE])[A-Za-z]*i")
REDIRECTS = {">", ">>", ">|", "&>", "&>>"}
SCRATCH_PREFIXES = ("/dev/", "/tmp/", "&")  # noqa: S108 - a prefix to ignore, not a file to open
STASH_MUTATIONS = {"push", "save", "pop", "apply", "drop", "clear"}


def _segments(cmd, posix=True):
    lexer = shlex.shlex(cmd.replace("\n", " ; "), posix=posix, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError:
        return None
    segs, cur = [], []
    for tok in tokens:
        if tok in OPERATORS:
            segs.append((cur, tok))
            cur = []
        else:
            cur.append(tok)
    segs.append((cur, None))
    return segs


def _head_tokens(tokens):
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tok) or tok in WRAPPERS:
            i += 1
            continue
        for pre in PREFIX_RUNNERS:
            if tuple(tokens[i:i + len(pre)]) == pre:
                i += len(pre)
                break
        else:
            break
    return tokens[i:]


def _head(tokens):
    return " ".join(_head_tokens(tokens))


def is_verify_run(cmd):
    """True when a verification command's exit status is the whole command's exit status."""
    segs = _segments(cmd or "")
    if not segs:
        return False
    pipefail = "pipefail" in (cmd or "")
    for idx, (tokens, _op) in enumerate(segs):
        if not VERIFY_HEAD.match(_head(tokens) + " "):
            continue
        tail_ops = [op for _t, op in segs[idx:] if op]
        if all(op == "&&" for op in tail_ops) or (pipefail and all(op in ("&&", "|") for op in tail_ops)):
            return True
    return False


def _scratch(target):
    return target.startswith(SCRATCH_PREFIXES)


def _git_edit(words):
    rest = words[1:]
    i = 0
    while i < len(rest) and rest[i].startswith("-"):
        i += 2 if rest[i] in ("-C", "-c") else 1
    if i >= len(rest):
        return False
    sub, args = rest[i], rest[i + 1 :]
    if sub in ("apply", "am"):
        return True
    if sub == "checkout":
        return "--" in args
    if sub == "restore":
        staged_only = ("--staged" in args or "-S" in args) and not ({"--worktree", "-W"} & set(args))
        return not staged_only
    if sub == "stash":
        first = args[0] if args else None
        return first is None or first.startswith("-") or first in STASH_MUTATIONS
    return False


def _segment_edits(tokens):
    for i, tok in enumerate(tokens):
        if tok in REDIRECTS and i + 1 < len(tokens) and not _scratch(tokens[i + 1]):
            return True
    words = _head_tokens(tokens)
    if not words:
        return False
    name, args = words[0], words[1:]
    if name in ("sed", "perl"):
        return any(INPLACE_FLAG.match(a) or a.startswith("--in-place") for a in args)
    if name == "patch":
        return True
    if name == "tee":
        return any(not a.startswith("-") and not _scratch(a) for a in args)
    if name == "git":
        return _git_edit(words)
    return False


def is_bash_edit(cmd):
    """True when a Bash command writes a file: an in-place edit, a patch, a mutating git verb or a redirect."""
    segs = _segments(cmd or "", posix=False)
    if segs is None:
        return False
    return any(_segment_edits(tokens) for tokens, _op in segs)


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
    session_id = re.sub(r"[^A-Za-z0-9_.-]", "_", str(payload.get("session_id") or "unknown"))[:64]
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
                if isinstance(b, dict) and b.get("type") == "tool_use" and (
                    b.get("name") in EDIT_TOOLS
                    or (b.get("name") == "Bash" and is_bash_edit((b.get("input") or {}).get("command")))
                ):
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
                    tool_input = b.get("input") or {}
                    cmd = tool_input.get("command", "")
                    if is_verify_run(cmd) and not tool_input.get("run_in_background"):
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
            if marker.exists() and marker.read_text(encoding="utf-8").strip() == state:
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
            marker.write_text(state, encoding="utf-8")

    msg = "[claim-check] " + warn + ". Re-run the verification command and confirm it passes before finishing."
    print(json.dumps({"systemMessage": msg}))


if __name__ == "__main__":
    main()
