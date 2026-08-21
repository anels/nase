#!/usr/bin/env python3
"""Collect and validate count-critical evidence for monthly effort rollups."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
BASIS_VERSION = "effort-rollup-v2"
MAX_CAPTURE_AGE_SECONDS = 7200
GH_TIMEOUT_SECONDS = 30
GH_ATTEMPTS = 3
CONTEXT_REPO_RE = re.compile(
    r"^\s*-\s+`([^`]+)`\s+\(([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(?:,|\))"
)
FULL_PR_RE = re.compile(r"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)")
QUALIFIED_PR_RE = re.compile(r"(?<![A-Za-z0-9_.-])([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([1-9][0-9]*)")
JIRA_RE = re.compile(r"(?<![A-Z0-9])([A-Z][A-Z0-9]{1,9}-[1-9][0-9]*)(?![A-Z0-9-])")
PHASE_PR_KEY_RE = re.compile(r"^phase_[a-z0-9_-]+_pr$", re.I)
VALID_EFFORT_STATUSES = {
    "planned", "in-progress", "needs-revision", "blocked", "merge-ready",
    "awaiting-deploy", "tracked", "ready", "completed", "wontfix",
}
ACTIVE_EFFORT_STATUSES = VALID_EFFORT_STATUSES - {"completed", "wontfix"}
DONE_EFFORT_STATUSES = {"completed", "wontfix"}


class EvidenceError(ValueError):
    """Invalid scope, capture, or evidence state."""


def load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise EvidenceError(f"cannot load helper: {path.name}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


FRONTMATTER = load_module(
    "nase_frontmatter_scalar", SCRIPT_ROOT / ".claude" / "scripts" / "frontmatter_scalar.py"
)
EFFORT_STATE = load_module(
    "nase_effort_state", SCRIPT_ROOT / ".claude" / "scripts" / "effort-state.py"
)
SECRET = load_module(
    "nase_effort_rollup_secret_scan", SCRIPT_ROOT / ".claude" / "scripts" / "codex-verify-bundle.py"
)


def secret_kind(data: bytes) -> str | None:
    hit = SECRET.scan_stream_for_secret(io.BytesIO(data))
    return str(hit[0]) if hit else None


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_sha(path: Path) -> str:
    return sha256(path.read_bytes())


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("wb", dir=path.parent, delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def atomic_json(path: Path, value: Any) -> None:
    data = canonical_bytes(value)
    if secret_kind(data):
        raise EvidenceError(f"sensitive JSON refused: {path.name}")
    atomic_write(path, data)


def inside(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def safe_child(root: Path, relative: str) -> Path:
    path = Path(relative)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise EvidenceError(f"unsafe bundle path: {relative}")
    candidate = root / path
    if candidate.is_symlink():
        raise EvidenceError(f"bundle path is a symlink: {relative}")
    resolved = candidate.resolve()
    if not inside(resolved, root.resolve()):
        raise EvidenceError(f"bundle path escapes: {relative}")
    return resolved


def month_bounds(month: str) -> tuple[datetime, datetime, str, str]:
    if not re.fullmatch(r"[0-9]{4}-(?:0[1-9]|1[0-2])", month):
        raise EvidenceError("month must use YYYY-MM")
    year, number = map(int, month.split("-"))
    start = datetime(year, number, 1, tzinfo=timezone.utc)
    if number == 12:
        end = datetime(year + 1, 1, 1, tzinfo=timezone.utc)
    else:
        end = datetime(year, number + 1, 1, tzinfo=timezone.utc)
    return start, end, start.date().isoformat(), (end.date() - timedelta(days=1)).isoformat()


def required_file(root: Path, relative: str) -> Path:
    path = root / relative
    if path.is_symlink() or not path.is_file():
        raise EvidenceError(f"required input is missing or symlinked: {relative}")
    return path


def section_lines(text: str, heading: str) -> list[str]:
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if line.strip().lower() == f"## {heading}".lower():
            start = index + 1
            break
    if start is None:
        return []
    selected: list[str] = []
    for line in lines[start:]:
        if re.match(r"^#{1,6}\s+", line):
            break
        selected.append(line)
    return selected


def parse_scope(context: Path, repo_filter: str | None) -> list[dict[str, str]]:
    repos: list[dict[str, str]] = []
    aliases: set[str] = set()
    canonical: set[str] = set()
    for line in section_lines(context.read_text(encoding="utf-8"), "Repos"):
        if not line.lstrip().startswith("-"):
            continue
        match = CONTEXT_REPO_RE.match(line)
        if not match:
            raise EvidenceError(f"malformed repo entry in context: {line.strip()}")
        alias, full_name = match.groups()
        key = full_name.lower()
        if alias in aliases or key in canonical:
            raise EvidenceError(f"duplicate repo alias or owner/repo: {alias}")
        aliases.add(alias)
        canonical.add(key)
        owner, name = full_name.split("/", 1)
        repos.append({"alias": alias, "owner": owner, "repo": name, "full_name": full_name})
    if not repos:
        raise EvidenceError("context ## Repos is empty")
    if repo_filter:
        repos = [repo for repo in repos if repo["alias"] == repo_filter]
        if not repos:
            raise EvidenceError(f"repo filter is outside declared scope: {repo_filter}")
    return repos


def config_values(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^([A-Za-z0-9_]+):\s*(\S.*?)\s*$", line)
        if match:
            if match.group(1) in values:
                raise EvidenceError(f"duplicate config key: {match.group(1)}")
            values[match.group(1)] = match.group(2)
    return values


def local_path_values(path: Path, aliases: set[str]) -> dict[str, Path]:
    values: dict[str, Path] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in stripped:
            continue
        alias, raw = stripped.split("=", 1)
        if alias not in aliases:
            continue
        if alias in values:
            raise EvidenceError(f"duplicate .local-paths alias: {alias}")
        values[alias] = Path(raw).expanduser()
    return values


def github_remote(path: Path) -> str | None:
    try:
        completed = subprocess.run(
            ["git", "-C", str(path), "remote", "get-url", "origin"],
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0:
        return None
    remote = completed.stdout.strip()
    match = re.search(r"github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?$", remote, re.I)
    return f"{match.group(1)}/{match.group(2)}" if match else None


def local_availability(scope: list[dict[str, str]], mappings: dict[str, Path]) -> list[dict[str, str]]:
    records: list[dict[str, str]] = []
    for repo in scope:
        path = mappings.get(repo["alias"])
        status = "missing"
        if path is not None:
            if path.is_symlink():
                status = "symlinked"
            elif not path.is_dir():
                status = "missing"
            elif not (path / ".git").exists() and not (path / ".git").is_file():
                status = "non-git"
            elif (github_remote(path) or "").lower() != repo["full_name"].lower():
                status = "remote-mismatch"
            else:
                status = "available"
        records.append({"alias": repo["alias"], "status": status})
    return records


def discovery_account(repo: dict[str, str], config: dict[str, str]) -> str | None:
    owner = repo["owner"].lower()
    if owner == config.get("github_org", "").lower():
        return config.get("work_gh_account") or config.get("gh_account")
    personal = config.get("personal_gh_account", "")
    if owner == personal.lower():
        return personal
    return None


def canonical_pr(owner: str, repo: str, number: str | int) -> str:
    return f"https://github.com/{owner}/{repo}/pull/{int(number)}"


def pr_key(url: str) -> str:
    match = FULL_PR_RE.fullmatch(url)
    if not match:
        raise EvidenceError(f"non-canonical PR URL: {url}")
    return f"{match.group(1).lower()}/{match.group(2).lower()}#{int(match.group(3))}"


def dedupe_prs(urls: list[str]) -> list[str]:
    deduped: dict[str, str] = {}
    for url in urls:
        deduped.setdefault(pr_key(url), url)
    return list(deduped.values())


def extract_prs(value: str) -> list[str]:
    found = [canonical_pr(*match.groups()) for match in FULL_PR_RE.finditer(value)]
    found.extend(canonical_pr(*match.groups()) for match in QUALIFIED_PR_RE.finditer(value))
    return dedupe_prs(found)


def context_prs(text: str) -> list[str]:
    """Body references for reporting, excluding shorthand in rows that deny PR meaning."""
    found: list[str] = []
    for line in text.splitlines():
        if EFFORT_STATE.BARE_PR_DENIAL_RE.search(EFFORT_STATE.deemphasize(line)):
            found.extend(canonical_pr(*match.groups()) for match in FULL_PR_RE.finditer(line))
        else:
            found.extend(extract_prs(line))
    return dedupe_prs(found)


def frontmatter_block(text: str) -> list[str]:
    match = re.match(r"^---\s*\n(.*?)\n---\s*(?:\n|$)", text, re.S)
    return match.group(1).splitlines() if match else []


def list_field(lines: list[str], key: str) -> tuple[list[str], bool]:
    starts = [index for index, line in enumerate(lines) if re.match(rf"^{re.escape(key)}\s*:", line, re.I)]
    if not starts:
        return [], True
    if len(starts) != 1:
        return [], False
    index = starts[0]
    if lines[index].split(":", 1)[1].strip():
        return [], False
    values: list[str] = []
    for line in lines[index + 1 :]:
        if not line.strip():
            continue
        if line.lstrip().startswith("#"):
            continue
        if not line[:1].isspace() and not re.match(r"^-\s+", line):
            break
        match = re.match(r"^\s*-\s+(.+?)\s*$", line)
        if not match or re.search(r"(^|\s)[A-Za-z0-9_-]+:\s", match.group(1)):
            return [], False
        values.append(match.group(1))
    return values, bool(values)


def scalar(text: str, key: str, errors: list[str]) -> str | None:
    raw, valid = FRONTMATTER.extract_frontmatter_scalar(text, key)
    if not valid:
        errors.append(f"invalid-{key}")
    return raw


def effort_files(root: Path) -> list[tuple[Path, str]]:
    efforts = root / "workspace" / "efforts"
    if efforts.is_symlink() or not efforts.is_dir():
        raise EvidenceError("workspace/efforts is missing or symlinked")
    files: list[tuple[Path, str]] = []
    for path in sorted(efforts.glob("*.md")):
        files.append((path, "active"))
    done = efforts / "done"
    if done.is_dir() and not done.is_symlink():
        files.extend((path, "done") for path in sorted(done.glob("*.md")))
    archive = efforts / "archive"
    if archive.is_dir() and not archive.is_symlink():
        files.extend((path, "archive") for path in sorted(archive.glob("*/*.md")))
    for path, _ in files:
        if path.is_symlink() or not path.is_file() or not inside(path.resolve(), root.resolve()):
            raise EvidenceError(f"unsafe effort path: {path.name}")
    return files


def parse_efforts(root: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    slugs: set[str] = set()
    for path, location in effort_files(root):
        if path.stem in slugs:
            raise EvidenceError(f"duplicate effort slug: {path.stem}")
        slugs.add(path.stem)
        text = path.read_text(encoding="utf-8")
        lines = frontmatter_block(text)
        errors: list[str] = []
        status = scalar(text, "status", errors)
        owner = scalar(text, "owner", errors)
        repo_name = scalar(text, "repo", errors)
        tracking_raw = scalar(text, "tracking_only", errors)
        tracking_only, tracking_valid = FRONTMATTER.canonical_bool(tracking_raw)
        if not tracking_valid:
            errors.append("invalid-tracking_only")
        normalized_status = FRONTMATTER.normalize_scalar(status) if status else None
        if normalized_status not in VALID_EFFORT_STATUSES:
            errors.append("invalid-status")
        elif normalized_status not in (ACTIVE_EFFORT_STATUSES if location == "active" else DONE_EFFORT_STATUSES):
            errors.append("status-location-mismatch")
        if tracking_only and not owner:
            errors.append("missing-owner")

        references = EFFORT_STATE.pr_references(text)
        errors.extend(str(error) for error in references["validation_errors"])
        resolved_delivery_numbers = {int(ref["number"]) for ref in references["delivery"]}

        def resolves_delivery_bare(value: str, *, exactly_one: bool = False) -> bool:
            numbers = [int(number) for number in EFFORT_STATE.BARE_PR_RE.findall(value)]
            if not numbers or (exactly_one and len(numbers) != 1):
                return False
            return all(number in resolved_delivery_numbers for number in numbers)

        for key in ["pr", *sorted({line.split(":", 1)[0] for line in lines if PHASE_PR_KEY_RE.fullmatch(line.split(":", 1)[0])})]:
            raw = scalar(text, key, errors)
            if not raw:
                continue
            names_one_pr = len(extract_prs(raw)) == 1 or resolves_delivery_bare(raw, exactly_one=True)
            if raw.lstrip().startswith(("{", "[")) or not names_one_pr:
                errors.append(f"unresolved-{key}")
        prs, prs_valid = list_field(lines, "prs")
        if any(re.match(r"^prs\s*:", line, re.I) for line in lines) and not prs_valid:
            errors.append("invalid-prs")
        for raw in prs:
            if not extract_prs(raw) and not resolves_delivery_bare(raw):
                errors.append("unresolved-prs")
        blocked_fields = [line for line in lines if re.match(r"^blocked-by\s*:", line, re.I)]
        if len(blocked_fields) > 1:
            errors.append("invalid-blocked-by")
        elif blocked_fields and not blocked_fields[0].split(":", 1)[1].strip():
            _, blocked_valid = list_field(lines, "blocked-by")
            if not blocked_valid:
                errors.append("invalid-blocked-by")

        delivery = [
            canonical_pr(str(ref["owner"]), str(ref["repo"]), ref["number"])
            for ref in references["delivery"]
        ]
        dependencies = [
            canonical_pr(str(ref["owner"]), str(ref["repo"]), ref["number"])
            for ref in references["dependency"]
        ]

        delivery_map = {pr_key(url): url for url in delivery}
        dependency_map = {pr_key(url): url for url in dependencies}
        all_body = {pr_key(url): url for url in context_prs(text)}
        context_only = {
            key: url
            for key, url in all_body.items()
            if key not in delivery_map and key not in dependency_map
        }
        modified = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc)
        records.append(
            {
                "id": f"effort:{path.stem}",
                "slug": path.stem,
                "source_path": path.relative_to(root).as_posix(),
                "source_sha256": file_sha(path),
                "location": location,
                "source_mtime_month": modified.strftime("%Y-%m"),
                "status": normalized_status,
                "repo_alias": repo_name,
                "owner": owner,
                "tracking_only": tracking_only,
                "delivery_prs": sorted(delivery_map.values(), key=pr_key),
                "report_only_prs": [],
                "dependency_prs": sorted(dependency_map.values(), key=pr_key),
                "context_only_prs": sorted(context_only.values(), key=pr_key),
                "jira_keys": sorted(set(JIRA_RE.findall(text))),
                "classification_errors": sorted(set(errors)),
                "bucket": None,
                "countable": False,
                "reason": None,
            }
        )
    return records


def efforts_for_scope(efforts: list[dict[str, Any]], scope: list[dict[str, str]]) -> list[dict[str, Any]]:
    aliases = {repo["alias"] for repo in scope}
    repositories = {repo["full_name"].lower() for repo in scope}
    selected: list[dict[str, Any]] = []
    for effort in efforts:
        repo_alias = EFFORT_STATE.repo_token(
            FRONTMATTER.normalize_scalar(str(effort.get("repo_alias") or ""))
        )
        delivery_repos = {
            "/".join(FULL_PR_RE.fullmatch(url).groups()[:2]).lower()
            for url in effort["delivery_prs"]
            if FULL_PR_RE.fullmatch(url)
        }
        if repo_alias in aliases or repo_alias.lower() in repositories or delivery_repos & repositories:
            if delivery_repos - repositories:
                effort["classification_errors"] = sorted(
                    set(effort["classification_errors"] + ["delivery-pr-outside-scope"])
                )
            selected.append(effort)
    return selected


@dataclass
class CommandResult:
    status: str
    data: Any
    raw: bytes
    attempts: int
    error: str | None


def error_category(stderr: str) -> tuple[str, int | None]:
    lowered = stderr.lower()
    wait_match = re.search(r"(?:retry[- ]after|wait)\D{0,10}([0-9]{1,4})", lowered)
    wait = int(wait_match.group(1)) if wait_match else None
    if any(token in lowered for token in ("rate limit", "secondary rate", "429")):
        return "rate-limited", wait
    if any(token in lowered for token in ("auth", "login", "unauthorized", "forbidden", "401", "403")):
        return "auth-failed", None
    if any(token in lowered for token in ("network", "connection", "resolve host", "server error", "500", "502", "503", "504")):
        return "transient-network", None
    if any(token in lowered for token in ("not found", "404")):
        return "not-found", None
    return "command-failed", None


def run_json(args: list[str], timeout: int = GH_TIMEOUT_SECONDS, attempts: int = GH_ATTEMPTS) -> CommandResult:
    last_category = "command-failed"
    last_raw = b""
    for attempt in range(1, attempts + 1):
        try:
            completed = subprocess.run(args, text=True, capture_output=True, timeout=timeout, check=False)
        except FileNotFoundError:
            return CommandResult("failed", None, b"", attempt, "missing-gh")
        except subprocess.TimeoutExpired as exc:
            last_category = "timeout"
            last_raw = exc.stdout.encode() if isinstance(exc.stdout, str) else (exc.stdout or b"")
            if attempt < attempts:
                continue
            break
        raw = completed.stdout.encode()
        last_raw = raw
        if completed.returncode == 0:
            try:
                return CommandResult("complete", json.loads(completed.stdout), raw, attempt, None)
            except json.JSONDecodeError:
                return CommandResult("failed", None, raw, attempt, "invalid-json")
        last_category, wait = error_category(completed.stderr[:4096])
        if last_category == "rate-limited":
            if wait is None or wait > 60:
                return CommandResult("partial", None, raw, attempt, "rate-limit-wait-too-long")
            if attempt < attempts:
                time.sleep(wait)
                continue
        elif last_category == "transient-network" and attempt < attempts:
            time.sleep(1 if attempt == 1 else 2)
            continue
        else:
            return CommandResult("failed", None, raw, attempt, last_category)
    return CommandResult("partial", None, last_raw, attempts, f"retry-exhausted-{last_category}")


def command_ok(args: list[str]) -> str:
    try:
        completed = subprocess.run(args, text=True, capture_output=True, timeout=15, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise EvidenceError(f"required command unavailable: {args[0]}") from exc
    if completed.returncode != 0:
        raise EvidenceError(f"capability check failed: {' '.join(args[:3])}")
    return completed.stdout.strip()


class Collector:
    def __init__(self, bundle: Path):
        self.bundle = bundle
        self.captures: list[dict[str, Any]] = []
        self.counter = 0

    def save(self, source_id: str, kind: str, command: list[str], logical_window: dict[str, Any], outcome: CommandResult) -> None:
        self.counter += 1
        relative = f"captures/{self.counter:04d}-{kind}.json"
        target = safe_child(self.bundle, relative)
        raw = outcome.raw if outcome.raw else b"null\n"
        kind_hit = secret_kind(raw)
        if kind_hit:
            raise EvidenceError(f"sensitive capture refused: {kind_hit}")
        atomic_write(target, raw)
        self.captures.append(
            {
                "source_id": source_id,
                "kind": kind,
                "logical_window": logical_window,
                "command": command,
                "capture_path": relative,
                "sha256": sha256(raw),
                "collected_at": utc_now(),
                "attempt_count": outcome.attempts,
                "status": outcome.status,
                "error_category": outcome.error,
                "record_count": len(outcome.data) if isinstance(outcome.data, list) else (1 if isinstance(outcome.data, dict) else 0),
            }
        )


def auth_preflight() -> tuple[str, str]:
    if not shutil.which("gh"):
        raise EvidenceError("gh is unavailable")
    version = command_ok(["gh", "--version"]).splitlines()[0][:200]
    command_ok(["gh", "search", "prs", "--help"])
    command_ok(["gh", "pr", "view", "--help"])
    auth = run_json(["gh", "auth", "status", "--active", "--hostname", "github.com", "--json", "hosts"], timeout=15, attempts=1)
    if auth.status != "complete" or not isinstance(auth.data, dict):
        raise EvidenceError("GitHub auth preflight failed")
    entries = auth.data.get("hosts", {}).get("github.com", [])
    active = next((item for item in entries if item.get("active") is True and item.get("state") == "success"), None)
    if not active or not active.get("login"):
        raise EvidenceError("GitHub auth has no active successful account")
    return version, str(active["login"])


def search_candidates(
    collector: Collector,
    repo: dict[str, str],
    author: str,
    start: date,
    end: date,
) -> tuple[dict[str, str], list[str]]:
    query = f"{start.isoformat()}..{end.isoformat()}"
    source_id = f"github-search:{repo['alias']}:{author}:{query}"
    command = [
        "gh", "search", "prs", "--repo", repo["full_name"], "--author", author,
        "--merged-at", query, "--limit", "1000", "--json",
        "number,title,url,state,author,createdAt,closedAt",
    ]
    outcome = run_json(command)
    collector.save(source_id, "github-search", command, {"start": start.isoformat(), "end": end.isoformat()}, outcome)
    if outcome.status != "complete" or not isinstance(outcome.data, list):
        return {}, [outcome.error or "search-failed"]
    urls: dict[str, str] = {}
    schema_error = False
    for item in outcome.data:
        url = str(item.get("url", "")) if isinstance(item, dict) else ""
        match = FULL_PR_RE.fullmatch(url)
        if not match or f"{match.group(1)}/{match.group(2)}".lower() != repo["full_name"].lower():
            schema_error = True
            continue
        urls[pr_key(url)] = url
    if schema_error:
        return urls, ["search-schema"]
    if len(outcome.data) < 1000:
        return urls, []
    if start == end:
        return urls, ["search-cap-one-day"]
    midpoint = start + timedelta(days=(end - start).days // 2)
    left, left_gaps = search_candidates(collector, repo, author, start, midpoint)
    right, right_gaps = search_candidates(collector, repo, author, midpoint + timedelta(days=1), end)
    left.update(right)
    return left, left_gaps + right_gaps


def collect_pr_views(collector: Collector, candidates: dict[str, str]) -> tuple[dict[str, dict[str, Any]], list[str]]:
    records: dict[str, dict[str, Any]] = {}
    gaps: list[str] = []
    for key, url in sorted(candidates.items()):
        match = FULL_PR_RE.fullmatch(url)
        assert match
        owner, repo, number = match.groups()
        command = ["gh", "pr", "view", number, "--repo", f"{owner}/{repo}", "--json", "number,title,state,mergedAt,author,url"]
        source_id = f"github-pr:{key}"
        outcome = run_json(command)
        collector.save(source_id, "github-pr", command, {"pr": key}, outcome)
        if outcome.status != "complete" or not isinstance(outcome.data, dict):
            gaps.append(f"{key}:{outcome.error or 'view-failed'}")
            continue
        data = outcome.data
        try:
            canonical = canonical_pr(owner, repo, int(data["number"]))
            if pr_key(canonical) != key or pr_key(str(data["url"])) != key:
                raise ValueError("view identity mismatch")
            records[pr_key(canonical)] = {
                "id": f"pr:{pr_key(canonical)}",
                "url": canonical,
                "owner": owner,
                "repo": repo,
                "number": int(data["number"]),
                "title": str(data["title"])[:1000],
                "author": (data.get("author") or {}).get("login"),
                "state": data["state"],
                "merged_at": data.get("mergedAt"),
                "source_ids": [source_id],
            }
        except (KeyError, TypeError, ValueError) as exc:
            raise EvidenceError(f"invalid canonical PR view: {key}") from exc
    return records, gaps


def classify(
    efforts: list[dict[str, Any]],
    live_prs: dict[str, dict[str, Any]],
    search_keys: set[str],
    start: datetime,
    end: datetime,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, int]]:
    memberships: dict[str, dict[str, set[str]]] = {}
    for effort in efforts:
        for role, field in (
            ("delivery", "delivery_prs"),
            ("report-only", "report_only_prs"),
            ("dependency", "dependency_prs"),
            ("context-only", "context_only_prs"),
        ):
            for url in effort[field]:
                memberships.setdefault(pr_key(url), {}).setdefault(role, set()).add(effort["slug"])

    for effort in efforts:
        delivery = [live_prs.get(pr_key(url)) for url in effort["delivery_prs"]]
        unresolved = any(item is None for item in delivery)
        merged_dates = [
            parse_time(item["merged_at"])
            for item in delivery
            if item and item.get("state") == "MERGED" and item.get("merged_at")
        ]
        in_month = any(start <= merged < end for merged in merged_dates)
        merged_before = any(merged < start for merged in merged_dates)
        intersects_terminal_month = effort["location"] in {"done", "archive"} and effort["source_mtime_month"] == start.strftime("%Y-%m")
        active_tail = effort["location"] == "active" and effort["status"] in {"awaiting-deploy", "merged", "completed"}
        if effort["classification_errors"]:
            effort["bucket"], effort["reason"] = "excluded", "classification-error"
        elif effort["status"] == "wontfix":
            effort["bucket"], effort["reason"] = "excluded", "wontfix"
        elif effort["tracking_only"] and (in_month or intersects_terminal_month or active_tail):
            effort["bucket"], effort["reason"] = "tracked-external", "tracking-only"
        elif unresolved:
            effort["bucket"], effort["reason"] = "claimed-unverified", "missing-live-pr"
        elif in_month:
            effort["bucket"], effort["reason"] = "merged-in-month", "canonical-merged-at"
            effort["countable"] = True
        elif merged_before and (intersects_terminal_month or active_tail):
            effort["bucket"], effort["reason"] = "merged-earlier", "terminal-month-or-active-tail"
            effort["countable"] = True
        else:
            effort["bucket"], effort["reason"] = "excluded", "outside-month-or-unmerged"

    priority = ("delivery", "report-only", "dependency", "context-only")
    pr_records: list[dict[str, Any]] = []
    all_keys = set(live_prs) | set(memberships) | search_keys
    for key in sorted(all_keys):
        base = live_prs.get(key)
        roles = memberships.get(key, {})
        role = next((candidate for candidate in priority if candidate in roles), "untracked-candidate")
        linked = sorted(set().union(*roles.values())) if roles else []
        countable_efforts = {effort["slug"] for effort in efforts if effort["countable"]}
        merged_in_month = bool(
            base
            and base.get("state") == "MERGED"
            and base.get("merged_at")
            and start <= parse_time(base["merged_at"]) < end
        )
        countable = role == "delivery" and merged_in_month and bool(set(linked) & countable_efforts)
        if base:
            record = dict(base)
        else:
            owner_repo, number = key.split("#", 1)
            owner, repo = owner_repo.split("/", 1)
            record = {
                "id": f"pr:{key}", "url": canonical_pr(owner, repo, number), "owner": owner,
                "repo": repo, "number": int(number), "title": None, "author": None,
                "state": "UNKNOWN", "merged_at": None, "source_ids": [],
            }
        record.update(
            {
                "linked_efforts": linked,
                "role": role,
                "countable": countable,
                "exclusion_reason": None if countable else (
                    "untracked-candidate" if role == "untracked-candidate" else
                    "non-delivery-role" if role != "delivery" else
                    "not-merged-in-month" if not merged_in_month else "no-countable-effort"
                ),
            }
        )
        pr_records.append(record)
    totals = {
        "delivered_efforts": len({effort["slug"] for effort in efforts if effort["countable"]}),
        "merged_delivery_prs_in_month": sum(record["countable"] for record in pr_records),
        "tracked_external_efforts": sum(effort["bucket"] == "tracked-external" for effort in efforts),
        "untracked_merged_pr_candidates": sum(
            record["role"] == "untracked-candidate"
            and bool(record.get("merged_at"))
            and start <= parse_time(record["merged_at"]) < end
            for record in pr_records
        ),
    }
    return efforts, pr_records, totals


def inventory_capture(root: Path, month: str, bundle: Path) -> dict[str, Any]:
    commands: list[list[str]] = []
    outputs: list[bytes] = []
    script = required_file(root, ".claude/scripts/month-efforts.sh")
    directories = [root / "workspace" / "efforts" / "done", root / "workspace" / "efforts" / "archive" / month[:4]]
    for directory in directories:
        if not directory.is_dir():
            continue
        command = ["bash", str(script), month, str(directory)]
        completed = subprocess.run(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=False)
        if completed.returncode != 0:
            raise EvidenceError("month-efforts.sh failed")
        commands.append(["bash", ".claude/scripts/month-efforts.sh", month, directory.relative_to(root).as_posix()])
        outputs.append(completed.stdout)
    raw = b"\n".join(outputs)
    kind_hit = secret_kind(raw)
    if kind_hit:
        raise EvidenceError(f"sensitive capture refused: {kind_hit}")
    relative = "captures/effort-inventory.txt"
    atomic_write(safe_child(bundle, relative), raw)
    return {
        "source_id": "effort-inventory",
        "kind": "effort-inventory",
        "logical_window": {"month": month},
        "command": commands,
        "capture_path": relative,
        "sha256": sha256(raw),
        "collected_at": utc_now(),
        "attempt_count": 1,
        "status": "complete",
        "error_category": None,
        "record_count": len(effort_files(root)),
    }


def build_evidence(
    root: Path,
    month: str,
    run: dict[str, Any],
    captures: list[dict[str, Any]],
    effort_records: list[dict[str, Any]],
    live_prs: dict[str, dict[str, Any]],
    search_keys: set[str],
    gaps: list[str],
) -> dict[str, Any]:
    start = parse_time(run["window"]["start"])
    end = parse_time(run["window"]["end_exclusive"])
    efforts, prs, totals = classify(effort_records, live_prs, search_keys, start, end)
    classification_gaps = [f"{effort['slug']}:classification-error" for effort in efforts if effort["classification_errors"]]
    all_gaps = sorted(set(gaps + classification_gaps))
    coverage = {"status": "partial" if all_gaps else "complete-for-declared-sources", "gaps": all_gaps}
    return {
        "schema_version": 1,
        "run_id": run["run_id"],
        "month": month,
        "measurement_basis_version": BASIS_VERSION,
        "scope": run["scope"],
        "captures": captures,
        "coverage": coverage,
        "efforts": efforts,
        "prs": prs,
        "totals": totals,
    }


def collect(args: argparse.Namespace) -> int:
    root = Path(args.root).expanduser()
    if root.is_symlink() or not root.is_dir():
        raise EvidenceError("root must be a real directory")
    root = root.resolve()
    start, end, start_date, end_date = month_bounds(args.month)
    bundle = Path(args.bundle).expanduser()
    if bundle.is_symlink():
        raise EvidenceError("bundle must not be a symlink")
    if bundle.exists() and any(bundle.iterdir()):
        raise EvidenceError("bundle must be empty; resume is unsupported")
    bundle.mkdir(parents=True, exist_ok=True)
    (bundle / "captures").mkdir(exist_ok=True)
    (bundle / "supplemental").mkdir(exist_ok=True)

    context = required_file(root, "workspace/context.md")
    config_path = required_file(root, "workspace/config.md")
    local_paths_path = required_file(root, ".local-paths")
    config = config_values(config_path)
    scope = parse_scope(context, args.repo)
    mappings = local_path_values(local_paths_path, {repo["alias"] for repo in scope})
    local = local_availability(scope, mappings)
    version, reader = auth_preflight()
    started_at = utc_now()
    collector = Collector(bundle)
    collector.captures.append(inventory_capture(root, args.month, bundle))

    effort_records = efforts_for_scope(parse_efforts(root), scope)
    candidates: dict[str, str] = {}
    for effort in effort_records:
        for field in ("delivery_prs", "report_only_prs", "dependency_prs", "context_only_prs"):
            for url in effort[field]:
                candidates.setdefault(pr_key(url), url)
    search_keys: set[str] = set()
    source_coverage: list[dict[str, Any]] = []
    for repo in scope:
        author = discovery_account(repo, config)
        if not author:
            reason = "discovery-account-unresolved"
            source_coverage.append({"alias": repo["alias"], "account": None, "status": "partial", "reasons": [reason]})
            continue
        rate_command = ["gh", "api", "rate_limit"]
        rate = run_json(rate_command, timeout=15, attempts=1)
        collector.save(f"github-rate:{repo['alias']}", "github-rate", rate_command, {"repo": repo["full_name"]}, rate)
        rate_valid = (
            rate.status == "complete"
            and isinstance(rate.data, dict)
            and isinstance(rate.data.get("resources"), dict)
            and isinstance(rate.data["resources"].get("search"), dict)
        )
        rate_reason = None if rate_valid else (rate.error or "invalid-rate-schema")
        discovered, repo_gaps = search_candidates(collector, repo, author, start.date(), (end - timedelta(days=1)).date())
        search_keys.update(discovered)
        candidates.update(discovered)
        source_coverage.append(
            {
                "alias": repo["alias"],
                "account": author,
                "status": "complete" if rate_valid and not repo_gaps else "partial",
                "reasons": sorted(set(repo_gaps + ([] if rate_reason is None else [rate_reason]))),
            }
        )
    live_prs, view_gaps = collect_pr_views(collector, candidates)

    finished_at = utc_now()
    run = {
        "schema_version": 1,
        "run_id": str(uuid.uuid4()),
        "month": args.month,
        "window": {"start": start.isoformat().replace("+00:00", "Z"), "end_exclusive": end.isoformat().replace("+00:00", "Z")},
        "collection_started_at": started_at,
        "collection_finished_at": finished_at,
        "max_capture_age_seconds": MAX_CAPTURE_AGE_SECONDS,
        "measurement_basis_version": BASIS_VERSION,
        "gh": {"version": version, "hostname": "github.com", "active_account": reader, "auth_status": "success"},
        "input_hashes": {
            "workspace/context.md": file_sha(context),
            "workspace/config.md": file_sha(config_path),
            ".local-paths": file_sha(local_paths_path),
        },
        "scope": {
            "repo_filter": args.repo,
            "expected_repos": scope,
            "local_availability": local,
            "github_sources": source_coverage,
        },
    }
    local_gaps = [
        f"{record['alias']}:local-{record['status']}"
        for record in local
        if record["status"] != "available"
    ]
    source_gaps = [
        f"{source['alias']}:{reason}"
        for source in source_coverage
        for reason in source.get("reasons", [])
    ]
    capture_gaps = [
        f"{entry['source_id']}:{entry.get('error_category') or entry['status']}"
        for entry in collector.captures
        if entry["kind"] != "github-pr" and entry["status"] != "complete"
    ]
    evidence = build_evidence(
        root,
        args.month,
        run,
        collector.captures,
        effort_records,
        live_prs,
        search_keys,
        local_gaps + source_gaps + capture_gaps + view_gaps,
    )
    atomic_json(bundle / "run.json", run)
    atomic_json(bundle / "evidence.json", evidence)
    output = {
        "run_id": run["run_id"],
        "bundle": str(bundle.resolve()),
        "coverage": evidence["coverage"],
        "totals": evidence["totals"],
    }
    print(json.dumps(output, indent=2, sort_keys=True) if args.format == "json" else f"run_id={run['run_id']} coverage={evidence['coverage']['status']}")
    return 0


def capture_data(bundle: Path, entries: list[dict[str, Any]], started: datetime, finished: datetime) -> dict[str, Any]:
    values: dict[str, Any] = {}
    for entry in entries:
        path = safe_child(bundle, entry["capture_path"])
        if not path.is_file():
            raise EvidenceError(f"capture is missing: {entry['source_id']}")
        raw = path.read_bytes()
        if sha256(raw) != entry["sha256"]:
            raise EvidenceError(f"capture hash mismatch: {entry['source_id']}")
        kind_hit = secret_kind(raw)
        if kind_hit:
            raise EvidenceError(f"sensitive capture refused: {kind_hit}")
        collected = parse_time(entry["collected_at"])
        if collected < started or collected > finished or collected > datetime.now(timezone.utc) + timedelta(seconds=5):
            raise EvidenceError(f"capture timestamp outside collection interval: {entry['source_id']}")
        if entry["kind"] == "effort-inventory":
            continue
        try:
            value = json.loads(raw)
        except json.JSONDecodeError:
            if entry["status"] == "complete":
                raise EvidenceError(f"complete capture is malformed: {entry['source_id']}")
            value = None
        record_count = len(value) if isinstance(value, list) else (1 if isinstance(value, dict) else 0)
        if entry.get("record_count") != record_count:
            raise EvidenceError(f"capture record count mismatch: {entry['source_id']}")
        values[entry["source_id"]] = value
    return values


def validate_capture_contract(entries: list[dict[str, Any]], run: dict[str, Any]) -> None:
    source_ids: set[str] = set()
    capture_paths: set[str] = set()
    repos = {repo["alias"]: repo for repo in run["scope"]["expected_repos"]}
    raw_sources = run["scope"].get("github_sources", [])
    if not isinstance(raw_sources, list) or any(not isinstance(source, dict) for source in raw_sources):
        raise EvidenceError("invalid GitHub source coverage")
    expected_sources = {source.get("alias"): source.get("account") for source in raw_sources}
    if len(expected_sources) != len(raw_sources) or set(expected_sources) != set(repos):
        raise EvidenceError("GitHub source coverage does not match scope")
    seen_inventory = False
    seen_rate: set[str] = set()
    seen_search: set[str] = set()
    for entry in entries:
        source_id = entry.get("source_id")
        capture_path = entry.get("capture_path")
        if not isinstance(source_id, str) or source_id in source_ids:
            raise EvidenceError("duplicate or invalid capture source ID")
        if not isinstance(capture_path, str) or capture_path in capture_paths:
            raise EvidenceError("duplicate or invalid capture path")
        source_ids.add(source_id)
        capture_paths.add(capture_path)
        if entry.get("status") not in {"complete", "partial", "failed"}:
            raise EvidenceError(f"invalid capture status: {source_id}")
        if (entry["status"] == "complete") != (entry.get("error_category") is None):
            raise EvidenceError(f"capture status and error disagree: {source_id}")
        attempts = entry.get("attempt_count")
        if not isinstance(attempts, int) or not 1 <= attempts <= GH_ATTEMPTS:
            raise EvidenceError(f"invalid capture attempt count: {source_id}")
        if not isinstance(entry.get("record_count"), int) or entry["record_count"] < 0:
            raise EvidenceError(f"invalid capture record count: {source_id}")
        if not re.fullmatch(r"[0-9a-f]{64}", str(entry.get("sha256", ""))):
            raise EvidenceError(f"invalid capture hash: {source_id}")
        kind = entry.get("kind")
        command = entry.get("command")
        if kind == "effort-inventory":
            if seen_inventory or source_id != "effort-inventory" or capture_path != "captures/effort-inventory.txt":
                raise EvidenceError("invalid effort inventory identity")
            if entry.get("logical_window") != {"month": run["month"]} or not isinstance(command, list) or any(
                not isinstance(item, list)
                or item[:2] != ["bash", ".claude/scripts/month-efforts.sh"]
                or len(item) != 4
                for item in command
            ):
                raise EvidenceError("invalid effort inventory command")
            seen_inventory = True
            continue
        if not isinstance(command, list) or any(not isinstance(item, str) for item in command):
            raise EvidenceError(f"invalid capture command: {source_id}")
        if kind == "github-rate":
            match = re.fullmatch(r"github-rate:(.+)", source_id)
            if (
                not match
                or match.group(1) not in repos
                or expected_sources.get(match.group(1)) is None
                or command != ["gh", "api", "rate_limit"]
            ):
                raise EvidenceError(f"invalid rate capture: {source_id}")
            seen_rate.add(match.group(1))
        elif kind == "github-search":
            match = re.fullmatch(r"github-search:([^:]+):([^:]+):([0-9-]+\.\.[0-9-]+)", source_id)
            if not match or match.group(1) not in repos:
                raise EvidenceError(f"invalid search capture: {source_id}")
            alias, author, query = match.groups()
            window = entry.get("logical_window", {})
            expected_query = f"{window.get('start')}..{window.get('end')}"
            expected = [
                "gh", "search", "prs", "--repo", repos[alias]["full_name"], "--author", author,
                "--merged-at", expected_query, "--limit", "1000", "--json",
                "number,title,url,state,author,createdAt,closedAt",
            ]
            if query != expected_query or author != expected_sources.get(alias) or command != expected:
                raise EvidenceError(f"search capture command drift: {source_id}")
            seen_search.add(alias)
        elif kind == "github-pr":
            key = entry.get("logical_window", {}).get("pr")
            if (
                source_id != f"github-pr:{key}"
                or not isinstance(key, str)
                or re.fullmatch(r"[a-z0-9_.-]+/[a-z0-9_.-]+#[1-9][0-9]*", key) is None
            ):
                raise EvidenceError(f"invalid PR capture: {source_id}")
            owner_repo, number = key.split("#", 1)
            expected = ["gh", "pr", "view", number, "--repo", command[5] if len(command) > 5 else "", "--json", "number,title,state,mergedAt,author,url"]
            if command != expected or command[5].lower() != owner_repo:
                raise EvidenceError(f"PR capture command drift: {source_id}")
        else:
            raise EvidenceError(f"unsupported capture kind: {kind}")
    if not seen_inventory:
        raise EvidenceError("effort inventory capture is missing")
    for alias, account in expected_sources.items():
        if account and (alias not in seen_rate or alias not in seen_search):
            raise EvidenceError(f"missing discovery capture for {alias}")


def reconstruct_discovery(
    entries: list[dict[str, Any]],
    values: dict[str, Any],
    scope: list[dict[str, str]],
    accounts: dict[str, str | None],
    start: date,
    end: date,
) -> tuple[list[dict[str, Any]], set[str]]:
    rates = {
        entry["source_id"].removeprefix("github-rate:"): entry
        for entry in entries
        if entry["kind"] == "github-rate"
    }
    searches: dict[tuple[str, str, str], dict[str, Any]] = {}
    for entry in entries:
        if entry["kind"] != "github-search":
            continue
        alias, author, query = entry["source_id"].split(":", 3)[1:]
        searches[(alias, author, query)] = entry

    visited: set[tuple[str, str, str]] = set()
    search_keys: set[str] = set()
    sources: list[dict[str, Any]] = []
    for repo in scope:
        alias = repo["alias"]
        account = accounts[alias]
        if not account:
            sources.append({
                "alias": alias,
                "account": None,
                "status": "partial",
                "reasons": ["discovery-account-unresolved"],
            })
            continue

        reasons: list[str] = []
        rate_entry = rates[alias]
        rate_value = values.get(rate_entry["source_id"])
        if rate_entry["status"] != "complete":
            reasons.append(rate_entry.get("error_category") or "rate-limit-unavailable")
        elif not (
            isinstance(rate_value, dict)
            and isinstance(rate_value.get("resources"), dict)
            and isinstance(rate_value["resources"].get("search"), dict)
        ):
            reasons.append("invalid-rate-schema")

        def visit(window_start: date, window_end: date) -> None:
            query = f"{window_start.isoformat()}..{window_end.isoformat()}"
            index = (alias, account, query)
            entry = searches.get(index)
            if entry is None:
                raise EvidenceError(f"missing canonical search capture: {alias}:{query}")
            visited.add(index)
            value = values.get(entry["source_id"])
            if entry["status"] != "complete" or not isinstance(value, list):
                reasons.append(entry.get("error_category") or "search-failed")
                return
            schema_error = False
            for item in value:
                url = str(item.get("url", "")) if isinstance(item, dict) else ""
                match = FULL_PR_RE.fullmatch(url)
                author = item.get("author") if isinstance(item, dict) else None
                if not (
                    match
                    and f"{match.group(1)}/{match.group(2)}".lower() == repo["full_name"].lower()
                    and int(match.group(3)) == item.get("number")
                    and isinstance(author, dict)
                    and author.get("login") == account
                ):
                    schema_error = True
                    continue
                search_keys.add(pr_key(url))
            if schema_error:
                reasons.append("search-schema")
                return
            if len(value) < 1000:
                return
            if window_start == window_end:
                reasons.append("search-cap-one-day")
                return
            midpoint = window_start + timedelta(days=(window_end - window_start).days // 2)
            visit(window_start, midpoint)
            visit(midpoint + timedelta(days=1), window_end)

        visit(start, end)
        reasons = sorted(set(reasons))
        sources.append({
            "alias": alias,
            "account": account,
            "status": "partial" if reasons else "complete",
            "reasons": reasons,
        })

    if set(searches) != visited:
        raise EvidenceError("unexpected search capture outside canonical month partition")
    return sources, search_keys


def reconstruct_live_prs(entries: list[dict[str, Any]], values: dict[str, Any]) -> tuple[dict[str, dict[str, Any]], list[str]]:
    live: dict[str, dict[str, Any]] = {}
    gaps: list[str] = []
    for entry in entries:
        value = values.get(entry["source_id"])
        if entry["kind"] != "github-pr":
            continue
        key = entry["logical_window"]["pr"]
        if entry["status"] != "complete" or not isinstance(value, dict):
            gaps.append(f"{key}:{entry.get('error_category') or 'view-failed'}")
            continue
        try:
            owner_repo, number = key.split("#", 1)
            owner, repo = owner_repo.split("/", 1)
            canonical = canonical_pr(owner, repo, number)
            if int(value["number"]) != int(number) or pr_key(str(value["url"])) != key:
                raise ValueError("PR identity mismatch")
            if not isinstance(value["title"], str) or not isinstance(value["state"], str):
                raise TypeError("invalid PR fields")
            merged_at = value.get("mergedAt")
            if merged_at is not None:
                parse_time(merged_at)
            author = value.get("author")
            if author is not None and (not isinstance(author, dict) or not isinstance(author.get("login"), str)):
                raise TypeError("invalid PR author")
        except (KeyError, TypeError, ValueError) as exc:
            raise EvidenceError(f"invalid canonical PR capture: {key}") from exc
        live[key] = {
            "id": f"pr:{key}", "url": canonical, "owner": owner, "repo": repo,
            "number": int(number), "title": value["title"][:1000],
            "author": author.get("login") if author else None, "state": value["state"],
            "merged_at": merged_at, "source_ids": [entry["source_id"]],
        }
    return live, gaps


def markdown_errors(markdown: Path, evidence: dict[str, Any], evidence_sha: str) -> list[str]:
    text = markdown.read_text(encoding="utf-8")
    required = [
        f"Evidence SHA: {evidence_sha}",
        f"Measurement basis: {BASIS_VERSION}",
        f"Coverage: {evidence['coverage']['status']}",
        f"Delivered efforts: {evidence['totals']['delivered_efforts']}",
        f"Merged delivery PRs in month: {evidence['totals']['merged_delivery_prs_in_month']}",
    ]
    if evidence["scope"].get("repo_filter"):
        required.append(f"Repo filter: {evidence['scope']['repo_filter']}")
    required.extend(record["url"] for record in evidence["prs"] if record["countable"])
    required.extend(effort["id"] for effort in evidence["efforts"] if effort["countable"])
    return [item for item in required if item not in text]


def validate(args: argparse.Namespace) -> int:
    root = Path(args.root).expanduser()
    if root.is_symlink() or not root.is_dir():
        raise EvidenceError("root must be a real directory")
    root = root.resolve()
    month_bounds(args.month)
    manifest = Path(args.manifest).expanduser()
    if manifest.is_symlink() or not manifest.is_file() or manifest.name != "evidence.json":
        raise EvidenceError("manifest must be a real evidence.json file")
    bundle = manifest.resolve().parent
    run_path = safe_child(bundle, "run.json")
    if not run_path.is_file():
        raise EvidenceError("run.json is missing")
    run_bytes = run_path.read_bytes()
    evidence_bytes = manifest.read_bytes()
    kind_hit = secret_kind(run_bytes) or secret_kind(evidence_bytes)
    if kind_hit:
        raise EvidenceError(f"sensitive manifest refused: {kind_hit}")
    run = json.loads(run_bytes)
    evidence = json.loads(evidence_bytes)
    if run.get("schema_version") != 1 or evidence.get("schema_version") != 1:
        raise EvidenceError("unsupported schema version")
    try:
        parsed_run_id = uuid.UUID(str(run.get("run_id")))
    except ValueError as exc:
        raise EvidenceError("invalid run ID") from exc
    if str(parsed_run_id) != run.get("run_id"):
        raise EvidenceError("non-canonical run ID")
    if run.get("run_id") != evidence.get("run_id") or run.get("month") != args.month or evidence.get("month") != args.month:
        raise EvidenceError("foreign run ID or month")
    if run.get("measurement_basis_version") != BASIS_VERSION or evidence.get("measurement_basis_version") != BASIS_VERSION:
        raise EvidenceError("measurement basis mismatch")
    if run.get("max_capture_age_seconds") != MAX_CAPTURE_AGE_SECONDS:
        raise EvidenceError("capture age contract drift")
    gh = run.get("gh")
    if not (
        isinstance(gh, dict)
        and isinstance(gh.get("version"), str)
        and bool(gh["version"])
        and gh.get("hostname") == "github.com"
        and isinstance(gh.get("active_account"), str)
        and bool(gh["active_account"])
        and gh.get("auth_status") == "success"
    ):
        raise EvidenceError("invalid GitHub collection metadata")
    expected_start, expected_end, _, _ = month_bounds(args.month)
    expected_window = {
        "start": expected_start.isoformat().replace("+00:00", "Z"),
        "end_exclusive": expected_end.isoformat().replace("+00:00", "Z"),
    }
    if run.get("window") != expected_window:
        raise EvidenceError("month window drift")
    input_hashes = run.get("input_hashes")
    required_hashes = {"workspace/context.md", "workspace/config.md", ".local-paths"}
    if not isinstance(input_hashes, dict) or set(input_hashes) != required_hashes:
        raise EvidenceError("input hash set drift")
    for relative, expected in input_hashes.items():
        if file_sha(required_file(root, relative)) != expected:
            raise EvidenceError(f"input hash drift: {relative}")
    started = parse_time(run["collection_started_at"])
    finished = parse_time(run["collection_finished_at"])
    now = datetime.now(timezone.utc)
    if started > finished or finished > now + timedelta(seconds=5):
        raise EvidenceError("invalid collection interval")
    if (now - finished).total_seconds() > run.get("max_capture_age_seconds", 0):
        raise EvidenceError("evidence bundle is stale")
    validate_capture_contract(evidence["captures"], run)
    values = capture_data(bundle, evidence["captures"], started, finished)
    config = config_values(required_file(root, "workspace/config.md"))
    current_scope = parse_scope(required_file(root, "workspace/context.md"), run["scope"].get("repo_filter"))
    if current_scope != run["scope"].get("expected_repos"):
        raise EvidenceError("scope drift")
    expected_accounts = {
        repo["alias"]: discovery_account(repo, config)
        for repo in current_scope
    }
    recorded_accounts = {
        source["alias"]: source.get("account")
        for source in run["scope"].get("github_sources", [])
    }
    if expected_accounts != recorded_accounts:
        raise EvidenceError("discovery account drift")
    current_local = local_availability(
        current_scope,
        local_path_values(required_file(root, ".local-paths"), {repo["alias"] for repo in current_scope}),
    )
    if current_local != run["scope"].get("local_availability"):
        raise EvidenceError("local availability drift")
    derived_sources, search_keys = reconstruct_discovery(
        evidence["captures"],
        values,
        current_scope,
        expected_accounts,
        expected_start.date(),
        (expected_end - timedelta(days=1)).date(),
    )
    if derived_sources != run["scope"].get("github_sources"):
        raise EvidenceError("GitHub source coverage does not match captures")
    live, view_gaps = reconstruct_live_prs(evidence["captures"], values)
    capture_gaps = [
        f"{entry['source_id']}:{entry.get('error_category') or entry['status']}"
        for entry in evidence["captures"]
        if entry["kind"] != "github-pr" and entry["status"] != "complete"
    ]
    source_gaps = [
        f"{source['alias']}:{reason}"
        for source in derived_sources
        for reason in source.get("reasons", [])
    ]
    local_gaps = [
        f"{record['alias']}:local-{record['status']}"
        for record in run["scope"].get("local_availability", [])
        if record["status"] != "available"
    ]
    current_efforts = efforts_for_scope(parse_efforts(root), current_scope)
    required_views = {
        pr_key(url)
        for effort in current_efforts
        for field in ("delivery_prs", "report_only_prs", "dependency_prs", "context_only_prs")
        for url in effort[field]
    } | search_keys
    captured_views = {
        entry.get("logical_window", {}).get("pr")
        for entry in evidence["captures"]
        if entry.get("kind") == "github-pr"
    }
    if required_views != captured_views:
        detail = "missing" if required_views - captured_views else "unexpected"
        raise EvidenceError(f"{detail} canonical PR view capture")
    derived = build_evidence(
        root,
        args.month,
        run,
        evidence["captures"],
        current_efforts,
        live,
        search_keys,
        local_gaps + source_gaps + capture_gaps + view_gaps,
    )
    compared = ("measurement_basis_version", "scope", "coverage", "efforts", "prs", "totals")
    mismatches = [field for field in compared if evidence.get(field) != derived.get(field)]
    evidence_sha = file_sha(manifest)
    missing_markdown: list[str] = []
    if args.markdown:
        markdown = Path(args.markdown).expanduser()
        if markdown.is_symlink() or not markdown.is_file() or not inside(markdown.resolve(), bundle):
            raise EvidenceError("markdown must be a real file inside the bundle")
        missing_markdown = markdown_errors(markdown, evidence, evidence_sha)
    validation = {
        "schema_version": 1,
        "run_id": run["run_id"],
        "validated_at": utc_now(),
        "evidence_sha256": evidence_sha,
        "measurement_basis_version": BASIS_VERSION,
        "coverage": evidence["coverage"],
        "totals": evidence["totals"],
        "mismatched_fields": mismatches,
        "missing_markdown_contract": missing_markdown,
        "ok": not mismatches and not missing_markdown,
    }
    atomic_json(bundle / "validation.json", validation)
    print(json.dumps(validation, indent=2, sort_keys=True) if args.format == "json" else f"ok={str(validation['ok']).lower()} evidence_sha256={evidence_sha}")
    return 0 if validation["ok"] else 1


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    subparsers = root.add_subparsers(dest="command", required=True)
    command = subparsers.add_parser("collect")
    command.add_argument("--root", required=True)
    command.add_argument("--month", required=True)
    command.add_argument("--bundle", required=True)
    command.add_argument("--repo")
    command.add_argument("--format", choices=("text", "json"), default="text")
    command.set_defaults(handler=collect)
    command = subparsers.add_parser("validate")
    command.add_argument("--root", required=True)
    command.add_argument("--month", required=True)
    command.add_argument("--manifest", required=True)
    command.add_argument("--markdown")
    command.add_argument("--format", choices=("text", "json"), default="text")
    command.set_defaults(handler=validate)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        return int(args.handler(args))
    except (EvidenceError, OSError, UnicodeDecodeError, json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
