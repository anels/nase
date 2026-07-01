#!/usr/bin/env python3
"""Append-only KB usage telemetry helper.

This script is intentionally small and non-fatal. Callers use it from hooks and
deterministic KB scripts, so logging failures should never block the original
workflow.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any

from nase_time import parse_ts


ALLOWED_ACCESS = {"read", "resolve", "search-result"}
ALLOWED_SOURCE = {"read-hook", "kb-domain-resolve", "kb-search"}
KB_EXTENSIONS = {".md", ".sql"}
DEDUP_SECONDS = 60


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def format_ts(value: datetime) -> str:
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def resolve_root(explicit: str | None = None) -> pathlib.Path | None:
    candidate = explicit or os.environ.get("NASE_ROOT")
    if candidate:
        return pathlib.Path(candidate).expanduser().resolve()

    try:
        proc = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            return pathlib.Path(proc.stdout.strip()).resolve()
    except Exception:
        pass

    return pathlib.Path.cwd().resolve()


def session_id(explicit: str | None = None) -> str:
    return stable_session_id(explicit) or f"local-{os.getppid()}"


def stable_session_id(explicit: str | None = None) -> str | None:
    return (
        explicit
        or os.environ.get("CLAUDE_SESSION_ID")
        or os.environ.get("CLAUDE_SESSIONID")
    )


def session_slug(session: str) -> str:
    digest = hashlib.sha256(session.encode("utf-8")).hexdigest()[:16]
    return digest


def context_path(root: pathlib.Path, session: str) -> pathlib.Path:
    return root / "workspace" / "tmp" / f"kb-active-skill-{session_slug(session)}.json"


def fallback_context_path(root: pathlib.Path) -> pathlib.Path:
    return root / "workspace" / "tmp" / "kb-active-skill-current.json"


def normalize_skill(skill: str | None) -> str:
    value = (skill or "").strip()
    if value.startswith("/nase:"):
        value = value[len("/nase:") :]
    elif value.startswith("nase:"):
        value = value[len("nase:") :]
    return value or "unknown"


def normalize_kb_file(root: pathlib.Path, file_path: str) -> str | None:
    if not file_path:
        return None

    raw = pathlib.Path(file_path).expanduser()
    full = raw if raw.is_absolute() else root / raw
    try:
        rel = full.resolve(strict=False).relative_to(root.resolve(strict=False))
    except Exception:
        return None

    parts = rel.parts
    if len(parts) < 3 or parts[0] != "workspace" or parts[1] != "kb":
        return None

    rel_posix = rel.as_posix()
    if rel_posix == "workspace/kb/.domain-map.md":
        return None
    if pathlib.PurePosixPath(rel_posix).suffix.lower() not in KB_EXTENSIONS:
        return None
    return rel_posix


def activate(args: argparse.Namespace) -> int:
    root = resolve_root(args.root)
    if root is None:
        return 0

    stable = stable_session_id(args.session)
    session = session_id(args.session)
    payload = {
        "ts": format_ts(utc_now()),
        "skill": normalize_skill(args.skill),
        "source": args.source or "unknown",
        "session": session,
    }
    try:
        path = context_path(root, session)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, separators=(",", ":")) + "\n", encoding="utf-8")
        if stable is None:
            fallback_context_path(root).write_text(
                json.dumps(payload, separators=(",", ":")) + "\n",
                encoding="utf-8",
            )
    except Exception:
        return 0
    return 0


def active_skill_from_path(path: pathlib.Path, now: datetime) -> str:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return "unknown"

    ts = parse_ts(str(payload.get("ts", "")))
    if ts is None or (now - ts).total_seconds() > 12 * 60 * 60:
        return "unknown"
    return normalize_skill(str(payload.get("skill", "")))


def active_skill(root: pathlib.Path, session: str, now: datetime) -> str:
    skill = active_skill_from_path(context_path(root, session), now)
    if skill != "unknown":
        return skill
    return active_skill_from_path(fallback_context_path(root), now)


def recent_duplicate(jsonl: pathlib.Path, event: dict[str, Any], now: datetime) -> bool:
    try:
        lines = jsonl.read_text(encoding="utf-8").splitlines()[-200:]
    except Exception:
        return False

    for line in reversed(lines):
        try:
            existing = json.loads(line)
        except Exception:
            continue
        if not all(existing.get(k) == event.get(k) for k in ("skill", "file", "access", "source", "session")):
            continue
        ts = parse_ts(str(existing.get("ts", "")))
        if ts is None:
            continue
        delta = (now - ts).total_seconds()
        if 0 <= delta <= DEDUP_SECONDS:
            return True
    return False


def record(args: argparse.Namespace) -> int:
    if args.access not in ALLOWED_ACCESS or args.source not in ALLOWED_SOURCE:
        return 0

    root = resolve_root(args.root)
    if root is None:
        return 0

    normalized_file = normalize_kb_file(root, args.file)
    if normalized_file is None:
        return 0

    now = utc_now()
    session = session_id(args.session)
    skill = normalize_skill(args.skill) if args.skill else active_skill(root, session, now)
    event = {
        "ts": format_ts(now),
        "skill": skill,
        "file": normalized_file,
        "access": args.access,
        "source": args.source,
        "session": session,
    }
    jsonl = root / "workspace" / "stats" / "kb-usage.jsonl"

    try:
        jsonl.parent.mkdir(parents=True, exist_ok=True)
        if recent_duplicate(jsonl, event, now):
            return 0
        with jsonl.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(event, separators=(",", ":")) + "\n")
    except Exception:
        return 0
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Record KB usage telemetry")
    subparsers = parser.add_subparsers(dest="command", required=True)

    activate_parser = subparsers.add_parser("activate", help="store active skill context for this session")
    activate_parser.add_argument("--skill", required=True)
    activate_parser.add_argument("--source", default="unknown")
    activate_parser.add_argument("--session")
    activate_parser.add_argument("--root")
    activate_parser.set_defaults(func=activate)

    record_parser = subparsers.add_parser("record", help="append one KB usage event")
    record_parser.add_argument("--file", required=True)
    record_parser.add_argument("--access", required=True, choices=sorted(ALLOWED_ACCESS))
    record_parser.add_argument("--source", required=True, choices=sorted(ALLOWED_SOURCE))
    record_parser.add_argument("--skill")
    record_parser.add_argument("--session")
    record_parser.add_argument("--root")
    record_parser.set_defaults(func=record)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except Exception:
        return 0


if __name__ == "__main__":
    sys.exit(main())
