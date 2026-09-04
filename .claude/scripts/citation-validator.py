#!/usr/bin/env python3
"""Validate report citations against local roots and read-only authorities."""

from __future__ import annotations

import argparse
import functools
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
ALIAS_RE = re.compile(r"^[A-Za-z0-9._-]+$")
GITHUB_PR_RE = re.compile(r"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)")
JIRA_RE = re.compile(r"(?<![A-Z0-9])([A-Z][A-Z0-9]{1,9}-[1-9][0-9]*)(?![A-Z0-9-])")
CONFLUENCE_RE = re.compile(r"https://[A-Za-z0-9.-]+\.atlassian\.net/wiki/[A-Za-z0-9_?&=./%#+:-]+")
BACKTICK_RE = re.compile(r"`([^`\r\n]+)`")
SOURCE_SUFFIXES = {
    ".c", ".cc", ".cfg", ".conf", ".cpp", ".cs", ".css", ".go", ".h", ".hpp",
    ".html", ".ini", ".java", ".js", ".json", ".jsx", ".kt", ".md", ".mjs", ".py",
    ".rb", ".rs", ".scala", ".sh", ".sql", ".swift", ".toml", ".ts", ".tsx", ".txt",
    ".xml", ".yaml", ".yml",
}


class ValidationError(ValueError):
    """Invalid invocation or unsafe filesystem input."""


def load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ValidationError(f"cannot load helper: {path.name}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SECRET = load_module(
    "nase_citation_secret_scan", SCRIPT_ROOT / ".claude" / "scripts" / "verify-bundle.py"
)


def secret_kind(data: bytes) -> str | None:
    hit = SECRET.scan_stream_for_secret(io.BytesIO(data))
    return str(hit[0]) if hit else None


def safe_text(value: Any, limit: int = 500) -> str | None:
    if value is None:
        return None
    text = str(value)[:limit]
    return "<redacted-sensitive-value>" if secret_kind(text.encode()) else text


def parse_root(value: str) -> tuple[str, Path]:
    if "=" not in value:
        raise ValidationError("root must use ALIAS=PATH")
    alias, raw_path = value.split("=", 1)
    if not ALIAS_RE.fullmatch(alias) or not raw_path:
        raise ValidationError("invalid root alias or path")
    path = Path(raw_path).expanduser()
    if path.is_symlink() or not path.is_dir():
        raise ValidationError(f"root {alias!r} must be a real directory")
    return alias, path.resolve()


def inside(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def contains_symlink(path: Path, root: Path) -> bool:
    try:
        relative = path.absolute().relative_to(root.absolute())
    except ValueError:
        return False
    cursor = root.absolute()
    for part in relative.parts:
        cursor /= part
        if cursor.is_symlink():
            return True
    return False


def validate_artifact(path: str, primary_alias: str, primary_root: Path) -> tuple[Path, str]:
    artifact = Path(path).expanduser()
    if artifact.is_symlink() or not artifact.is_file():
        raise ValidationError("artifact must be a regular non-symlink file")
    if contains_symlink(artifact, primary_root):
        raise ValidationError("artifact path crosses a symlink")
    resolved = artifact.resolve()
    if not inside(resolved, primary_root):
        raise ValidationError("artifact must be inside the primary root")
    return resolved, f"{primary_alias}:{resolved.relative_to(primary_root).as_posix()}"


def result(kind: str, ref: str, status: str, detail: str, metadata: dict[str, Any] | None = None) -> dict[str, Any]:
    return {"kind": kind, "ref": ref, "status": status, "detail": detail, "metadata": metadata or {}}


def run_command(args: list[str], timeout: int) -> tuple[str, str, int] | tuple[None, str, None]:
    try:
        completed = subprocess.run(args, text=True, capture_output=True, timeout=timeout, check=False)
    except FileNotFoundError:
        return None, "missing-cli", None
    except subprocess.TimeoutExpired:
        return None, "timeout", None
    return completed.stdout, completed.stderr[:4096], completed.returncode


def failure_detail(stderr: str) -> tuple[str, str]:
    lowered = stderr.lower()
    if any(token in lowered for token in ("404", "not found", "could not resolve to")):
        return "BROKEN", "not-found"
    if any(token in lowered for token in ("auth", "login", "unauthorized", "forbidden", "401", "403")):
        return "UNKNOWN", "auth-unavailable"
    if any(token in lowered for token in ("rate limit", "secondary rate", "429")):
        return "UNKNOWN", "rate-limited"
    if any(token in lowered for token in ("network", "timed out", "timeout", "connection", "resolve host", "502", "503", "504")):
        return "UNKNOWN", "network-unavailable"
    return "UNKNOWN", "authority-error"


@functools.lru_cache(maxsize=8)
def github_auth(timeout: int) -> tuple[bool, str]:
    _, stderr, returncode = run_command(["gh", "auth", "status", "--hostname", "github.com"], timeout)
    if returncode is None:
        return False, stderr
    if returncode != 0:
        _, detail = failure_detail(stderr)
        return False, detail if detail != "not-found" else "auth-unavailable"
    return True, "resolved"


@functools.lru_cache(maxsize=128)
def github_repo_access(owner: str, repo: str, timeout: int) -> tuple[bool, str]:
    authenticated, detail = github_auth(timeout)
    if not authenticated:
        return False, detail
    stdout, stderr, returncode = run_command(
        ["gh", "repo", "view", f"{owner}/{repo}", "--json", "nameWithOwner"], timeout
    )
    if returncode is None:
        return False, stderr
    if returncode != 0:
        status, detail = failure_detail(stderr)
        return False, detail if status == "UNKNOWN" else "repository-unavailable"
    try:
        data = json.loads(stdout or "")
        if str(data["nameWithOwner"]).lower() != f"{owner}/{repo}".lower():
            raise KeyError("repository identity mismatch")
    except (json.JSONDecodeError, KeyError, TypeError):
        return False, "invalid-authority-response"
    return True, "resolved"


def validate_github(ref: str, timeout: int) -> dict[str, Any]:
    match = GITHUB_PR_RE.fullmatch(ref)
    assert match
    owner, repo, number = match.groups()
    accessible, detail = github_repo_access(owner, repo, timeout)
    if not accessible:
        return result("github_pr", ref, "UNKNOWN", detail)
    stdout, stderr, returncode = run_command(
        ["gh", "pr", "view", number, "--repo", f"{owner}/{repo}", "--json", "number,title,state,mergedAt,author,url"],
        timeout,
    )
    if returncode is None:
        return result("github_pr", ref, "UNKNOWN", stderr)
    if returncode != 0:
        status, detail = failure_detail(stderr)
        return result("github_pr", ref, status, detail)
    try:
        data = json.loads(stdout or "")
        returned = GITHUB_PR_RE.fullmatch(str(data["url"]))
        if not returned or int(data["number"]) != int(number) or (
            returned.group(1).lower(), returned.group(2).lower(), returned.group(3)
        ) != (owner.lower(), repo.lower(), number):
            raise KeyError("authority identity mismatch")
        metadata = {
            "number": data["number"],
            "title": safe_text(data["title"]),
            "state": safe_text(data["state"], 50),
            "mergedAt": safe_text(data.get("mergedAt"), 100),
            "author": safe_text((data.get("author") or {}).get("login"), 100),
            "url": data["url"],
        }
    except (json.JSONDecodeError, KeyError, TypeError):
        return result("github_pr", ref, "UNKNOWN", "invalid-authority-response")
    return result("github_pr", ref, "OK", "resolved", metadata)


def validate_jira(key: str, timeout: int) -> dict[str, Any]:
    if not shutil.which("acli"):
        return result("jira", key, "UNKNOWN", "missing-cli")
    _, stderr, returncode = run_command(["acli", "auth", "status"], timeout)
    if returncode is None:
        return result("jira", key, "UNKNOWN", stderr)
    if returncode != 0:
        _, detail = failure_detail(stderr)
        return result("jira", key, "UNKNOWN", detail)
    stdout, stderr, returncode = run_command(
        ["acli", "jira", "workitem", "view", key, "--fields", "summary,status,assignee", "--json"],
        timeout,
    )
    if returncode is None:
        return result("jira", key, "UNKNOWN", stderr)
    if returncode != 0:
        status, detail = failure_detail(stderr)
        return result("jira", key, status, detail)
    try:
        data = json.loads(stdout or "")
    except json.JSONDecodeError:
        return result("jira", key, "UNKNOWN", "invalid-authority-response")
    fields = data.get("fields", data) if isinstance(data, dict) else {}
    if not isinstance(fields, dict):
        return result("jira", key, "UNKNOWN", "invalid-authority-response")
    status_value = fields.get("status")
    assignee_value = fields.get("assignee")
    metadata = {
        "summary": safe_text(fields.get("summary", "")),
        "status": safe_text(status_value.get("name") if isinstance(status_value, dict) else status_value, 100),
        "assignee": safe_text(assignee_value.get("displayName") if isinstance(assignee_value, dict) else assignee_value, 200),
    }
    return result("jira", key, "OK", "resolved", metadata)


def eligible_path_token(token: str) -> tuple[str, int] | None:
    token = token.strip()
    if not token or token.startswith("/nase:") or re.match(r"^[a-z][a-z0-9+.-]*://", token, re.I):
        return None
    if any(marker in token for marker in ("*", "?", "[", "]", "{", "}", "$(", "${")):
        return None
    if ":" not in token:
        return None
    base, raw_line = token.rsplit(":", 1)
    if not raw_line.isdigit() or int(raw_line) < 1 or not base or "\0" in base:
        return None
    path_part = base.split(":", 1)[-1]
    if not Path(path_part).is_absolute() and "/" not in path_part and Path(path_part).suffix.lower() not in SOURCE_SUFFIXES:
        return None
    return base, int(raw_line)


def safe_candidate(root: Path, raw: str) -> tuple[Path | None, str | None]:
    path = Path(raw)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        return None, "path-escape"
    lexical = root / path
    if contains_symlink(lexical, root):
        return None, "symlink-escape"
    resolved = lexical.resolve()
    if not inside(resolved, root):
        return None, "path-escape"
    return resolved, None


def validate_line(alias: str, root: Path, path: Path, line: int) -> dict[str, Any]:
    relative = path.relative_to(root).as_posix()
    canonical = f"{alias}:{relative}:{line}"
    if not path.exists():
        return result("path", canonical, "BROKEN", "missing-file")
    if not path.is_file():
        return result("path", canonical, "BROKEN", "not-a-file")
    try:
        line_count = sum(1 for _ in path.open(encoding="utf-8"))
    except (OSError, UnicodeDecodeError):
        return result("path", canonical, "BROKEN", "unreadable-file")
    if line > line_count:
        return result("path", canonical, "BROKEN", "line-out-of-range", {"line_count": line_count})
    return result("path", canonical, "OK", "resolved")


def validate_path(base: str, line: int, roots: dict[str, Path]) -> dict[str, Any]:
    absolute = Path(base).is_absolute()
    if absolute:
        lexical = Path(base).absolute()
        resolved_path = lexical.resolve()
        matches: list[tuple[str, Path, Path]] = []
        for alias, root in roots.items():
            if inside(resolved_path, root):
                matches.append((alias, root, resolved_path))
        if not matches:
            return result("path", f"absolute:{line}", "BROKEN", "path-escape")
        if len(matches) > 1:
            return result("path", f"absolute:{line}", "UNKNOWN", "ambiguous-root")
        alias, root, resolved = matches[0]
        return validate_line(alias, root, resolved, line)

    if ":" in base:
        alias, raw_path = base.split(":", 1)
        if not ALIAS_RE.fullmatch(alias):
            return result("path", f"{alias}:{raw_path}:{line}", "BROKEN", "invalid-root-alias")
        root = roots.get(alias)
        if root is None:
            return result("path", f"{alias}:{raw_path}:{line}", "UNKNOWN", "unavailable-root")
        candidate, error = safe_candidate(root, raw_path)
        if error:
            return result("path", f"{alias}:{raw_path}:{line}", "BROKEN", error)
        assert candidate is not None
        return validate_line(alias, root, candidate, line)

    if any(part in {"", ".", ".."} for part in Path(base).parts):
        return result("path", f"unqualified:{base}:{line}", "BROKEN", "path-escape")
    matches: list[tuple[str, Path, Path]] = []
    for alias, root in roots.items():
        candidate, error = safe_candidate(root, base)
        if error == "symlink-escape":
            return result("path", f"unqualified:{base}:{line}", "BROKEN", error)
        if candidate is not None and candidate.is_file():
            matches.append((alias, root, candidate))
    if not matches:
        return result("path", f"unqualified:{base}:{line}", "UNKNOWN", "unqualified-root")
    if len(matches) > 1:
        return result("path", f"unqualified:{base}:{line}", "UNKNOWN", "ambiguous-root")
    alias, root, candidate = matches[0]
    return validate_line(alias, root, candidate, line)


def extract(text: str, roots: dict[str, Path], timeout: int) -> list[dict[str, Any]]:
    found: list[dict[str, Any]] = []
    for match in GITHUB_PR_RE.finditer(text):
        found.append(validate_github(match.group(0), timeout))
    for key in JIRA_RE.findall(text):
        found.append(validate_jira(key, timeout))
    for match in CONFLUENCE_RE.finditer(text):
        found.append(result("confluence", match.group(0).rstrip(".,;)"), "UNKNOWN", "mcp-required"))
    for token in BACKTICK_RE.findall(text):
        parsed = eligible_path_token(token)
        if parsed:
            found.append(validate_path(parsed[0], parsed[1], roots))
    deduplicated: dict[tuple[str, str], dict[str, Any]] = {}
    for item in found:
        deduplicated.setdefault((item["kind"], item["ref"]), item)
    return sorted(deduplicated.values(), key=lambda item: (item["kind"], item["ref"]))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact")
    parser.add_argument("--root", required=True)
    parser.add_argument("--repo-root", action="append", default=[])
    parser.add_argument("--format", choices=("text", "json"), default="text")
    parser.add_argument("--timeout-seconds", type=int, default=15)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.timeout_seconds < 1:
            raise ValidationError("timeout must be positive")
        primary_alias, primary_root = parse_root(args.root)
        roots = {primary_alias: primary_root}
        for raw in args.repo_root:
            alias, root = parse_root(raw)
            if alias in roots:
                raise ValidationError(f"duplicate root alias: {alias}")
            roots[alias] = root
        artifact, artifact_ref = validate_artifact(args.artifact, primary_alias, primary_root)
        results = extract(artifact.read_text(encoding="utf-8"), roots, args.timeout_seconds)
    except (OSError, UnicodeDecodeError, ValidationError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    summary = {
        "ok": sum(item["status"] == "OK" for item in results),
        "broken": sum(item["status"] == "BROKEN" for item in results),
        "unknown": sum(item["status"] == "UNKNOWN" for item in results),
    }
    payload = {
        "schema_version": 1,
        "artifact": artifact_ref,
        "roots": [{"alias": alias, "status": "available"} for alias in sorted(roots)],
        "summary": summary,
        "results": results,
    }
    if secret_kind(json.dumps(payload, sort_keys=True).encode()):
        print("ERROR: validation output contains sensitive data", file=sys.stderr)
        return 2
    if args.format == "json":
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"artifact={artifact_ref} ok={summary['ok']} broken={summary['broken']} unknown={summary['unknown']}")
        for item in results:
            print(f"{item['status']} {item['kind']} {item['ref']} {item['detail']}")
    if summary["broken"]:
        return 1
    if summary["unknown"]:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
