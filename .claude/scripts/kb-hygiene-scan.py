#!/usr/bin/env python3
"""Scan a project KB for stale or unsafe-to-trust claims.

The scanner is intentionally read-only. `/nase:onboard` decides whether a
reported item is safe to auto-fix under `.claude/docs/kb-hygiene.md`.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import date, datetime
from typing import Any


SOURCE_EXTS = {
    ".bicep",
    ".cs",
    ".cshtml",
    ".csproj",
    ".css",
    ".fsproj",
    ".go",
    ".gradle",
    ".h",
    ".hpp",
    ".java",
    ".js",
    ".json",
    ".jsx",
    ".kt",
    ".md",
    ".props",
    ".proto",
    ".ps1",
    ".py",
    ".rb",
    ".rs",
    ".sbt",
    ".scala",
    ".sh",
    ".sln",
    ".sql",
    ".targets",
    ".tf",
    ".tfvars",
    ".toml",
    ".ts",
    ".tsx",
    ".xml",
    ".yaml",
    ".yml",
}

SPECIAL_FILES = {
    ".editorconfig",
    ".gitignore",
    "Dockerfile",
    "Jenkinsfile",
    "Makefile",
    "NuGet.config",
    "Package.resolved",
    "Taskfile.yml",
    "azure-pipelines.yml",
    "azure-pipelines.yaml",
    "build.sbt",
    "docker-compose.yml",
    "go.mod",
    "go.sum",
    "package-lock.json",
    "package.json",
    "pnpm-lock.yaml",
    "pyproject.toml",
    "requirements.txt",
    "yarn.lock",
}

CURRENT_TOP_HEADINGS = {
    "api surface",
    "architecture map",
    "azure pipelines",
    "build & run commands",
    "change playbook",
    "ci/cd pipelines",
    "code standards",
    "config schema",
    "contract index",
    "critical constraints",
    "data flow / architecture",
    "data layer",
    "deployment",
    "key files",
    "overview",
    "ownership map",
    "related repos",
}

RISKY_SECTION_RE = re.compile(
    r"\b(api|auth|authorization|schema|storage|data layer|ownership|contract|related repos|cross-validation)\b",
    re.I,
)
HISTORICAL_SECTION_RE = re.compile(
    r"\b(history|changelog|decision|incident|recent changes|refresh|notes)\b|20[0-9]{2}-[0-9]{2}-[0-9]{2}",
    re.I,
)
CURRENT_SECTION_RE = re.compile(
    r"\b(overview|architecture|api surface|deployment|ci/cd|build|key files|change playbook|contract index|ownership)\b",
    re.I,
)
PLACEHOLDER_RE = re.compile(
    r"\b(FILL_IN|TBD|TO_BE_FILLED|FIXME_PLACEHOLDER)\b|<[^>\n]*(fill|repo|path|todo)[^>\n]*>",
    re.I,
)
STALE_RE = re.compile(
    r"\b(stale local|stale tree|stale kb|is stale|was stale|now stale|outdated|no longer correct|incorrectly claimed|behind origin|drift correction|superseded by)\b",
    re.I,
)
CORRECTION_RE = re.compile(r"(Correction\s+20[0-9]{2}-[0-9]{2}-[0-9]{2}:|Superseded by:)", re.I)
LAST_UPDATED_RE = re.compile(r"Last updated:\s*(20[0-9]{2}-[0-9]{2}-[0-9]{2})", re.I)
HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
BACKTICK_RE = re.compile(r"`([^`\n]+)`")
WORKSPACE_REF_PREFIXES = (
    "workspace/",
    "memory/",
)


class RepoIndex:
    def __init__(self, repo_root: pathlib.Path):
        self.repo_root = repo_root
        self.paths = self._load_paths()
        self.by_basename: dict[str, list[str]] = defaultdict(list)
        for path in self.paths:
            self.by_basename[pathlib.PurePosixPath(path).name].append(path)

    def _git(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", "-C", str(self.repo_root), *args],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def _load_paths(self) -> set[str]:
        result = self._git("ls-tree", "-r", "--name-only", "HEAD")
        if result.returncode == 0:
            return {line.strip() for line in result.stdout.splitlines() if line.strip()}

        paths: set[str] = set()
        for root, dirs, files in os.walk(self.repo_root):
            dirs[:] = [d for d in dirs if d not in {".git", "node_modules", ".venv", "__pycache__"}]
            root_path = pathlib.Path(root)
            for filename in files:
                rel = (root_path / filename).relative_to(self.repo_root).as_posix()
                paths.add(rel)
        return paths

    def exists(self, path: str) -> bool:
        return path in self.paths

    def suggestions(self, path: str) -> list[str]:
        basename = pathlib.PurePosixPath(path).name
        matches = sorted(self.by_basename.get(basename, []))
        return matches[:5]

    def line_count(self, path: str) -> int | None:
        result = self._git("show", f"HEAD:{path}")
        if result.returncode == 0:
            return len(result.stdout.splitlines())
        fs_path = self.repo_root / path
        if not fs_path.exists():
            return None
        try:
            return len(fs_path.read_text(encoding="utf-8", errors="replace").splitlines())
        except OSError:
            return None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Scan a project KB for hygiene issues.")
    parser.add_argument("--repo-root", required=True, help="Repo root used to validate source refs.")
    parser.add_argument("--kb-file", required=True, help="Project KB file to scan.")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON.")
    parser.add_argument("--today", help="Override current date as YYYY-MM-DD for tests.")
    parser.add_argument("--stale-days", type=int, default=30, help="Age threshold for Last updated warnings.")
    parser.add_argument(
        "--max-corrections",
        type=int,
        default=3,
        help="Corrections/supersessions per section before compaction is suggested.",
    )
    return parser.parse_args()


def normalize_heading(title: str) -> str:
    title = re.sub(r"`([^`]+)`", r"\1", title)
    title = re.sub(r"\s+", " ", title.strip().lower())
    return title.rstrip(":")


def today_value(raw: str | None) -> date:
    if raw:
        return datetime.strptime(raw, "%Y-%m-%d").date()
    return date.today()


def issue(
    *,
    line: int,
    category: str,
    action: str,
    message: str,
    text: str,
    section: str,
    suggestions: list[str] | None = None,
) -> dict[str, Any]:
    data: dict[str, Any] = {
        "line": line,
        "category": category,
        "action": action,
        "message": message,
        "section": section,
        "text": text.strip(),
    }
    if suggestions:
        data["suggestions"] = suggestions
    return data


def section_text(stack: list[tuple[int, str, int]]) -> str:
    return " > ".join(title for _, title, _ in stack)


def section_kind(stack: list[tuple[int, str, int]]) -> str:
    text = section_text(stack)
    if RISKY_SECTION_RE.search(text):
        return "risky"
    if HISTORICAL_SECTION_RE.search(text):
        return "historical"
    if CURRENT_SECTION_RE.search(text):
        return "current"
    return "general"


def source_candidate(raw: str, repo_root: pathlib.Path) -> tuple[str, int | None] | None:
    token = raw.strip().rstrip(".,;)")
    if not token or "://" in token or token.startswith(("$", "{")):
        return None
    if " " in token or "\t" in token:
        return None
    if token.startswith("/") and not str(pathlib.Path(token)).startswith(str(repo_root)):
        return None

    if token.startswith("/"):
        try:
            token = pathlib.Path(token).relative_to(repo_root).as_posix()
        except ValueError:
            return None

    token = token.removeprefix("./")
    token = token.split("#", 1)[0]
    if token.startswith(WORKSPACE_REF_PREFIXES):
        return None
    match = re.match(r"^(.+?)(?::([0-9]+)(?:[-,][0-9]+)*)?$", token)
    if not match:
        return None

    path = match.group(1)
    line = int(match.group(2)) if match.group(2) else None
    if any(part in path for part in ("*", "{", "}")):
        return None

    name = pathlib.PurePosixPath(path).name
    suffix = pathlib.PurePosixPath(path).suffix
    if suffix in SOURCE_EXTS or name in SPECIAL_FILES:
        return path, line
    return None


def broken_ref_action(suggestions: list[str]) -> tuple[str, str]:
    if len(suggestions) == 1:
        return "auto-fix", "Source reference does not exist at HEAD; one replacement path was found"
    if suggestions:
        return "needs_human", "Source reference does not exist at HEAD and has multiple possible replacements"
    return "needs_human", "Source reference does not exist at HEAD and no replacement path was found"


def scan(args: argparse.Namespace) -> dict[str, Any]:
    repo_root = pathlib.Path(args.repo_root).resolve()
    kb_file = pathlib.Path(args.kb_file).resolve()
    text = kb_file.read_text(encoding="utf-8")
    lines = text.splitlines()
    repo = RepoIndex(repo_root)
    today = today_value(args.today)

    issues: list[dict[str, Any]] = []
    stack: list[tuple[int, str, int]] = []
    seen_current_headings: dict[str, int] = {}
    correction_counts: Counter[tuple[str, int]] = Counter()

    for idx, line in enumerate(lines, start=1):
        heading = HEADING_RE.match(line)
        if heading:
            level = len(heading.group(1))
            title = heading.group(2).strip()
            while stack and stack[-1][0] >= level:
                stack.pop()
            stack.append((level, title, idx))
            normalized = normalize_heading(title)
            if level == 2 and normalized in CURRENT_TOP_HEADINGS:
                if normalized in seen_current_headings:
                    issues.append(
                        issue(
                            line=idx,
                            category="duplicate_current_section",
                            action="needs_human",
                            message=f"Duplicate current-state section; first seen on line {seen_current_headings[normalized]}.",
                            text=line,
                            section=section_text(stack),
                        )
                    )
                else:
                    seen_current_headings[normalized] = idx

        current_section = section_text(stack)
        kind = section_kind(stack)

        last_updated = LAST_UPDATED_RE.search(line)
        if last_updated:
            parsed = datetime.strptime(last_updated.group(1), "%Y-%m-%d").date()
            age = (today - parsed).days
            if age > args.stale_days:
                issues.append(
                    issue(
                        line=idx,
                        category="stale_timestamp",
                        action="stale_mark",
                        message=f"Last updated is {age} days old.",
                        text=line,
                        section=current_section,
                    )
                )

        if PLACEHOLDER_RE.search(line):
            issues.append(
                issue(
                    line=idx,
                    category="unresolved_placeholder",
                    action="needs_human",
                    message="Placeholder remains in KB content.",
                    text=line,
                    section=current_section,
                )
            )

        if STALE_RE.search(line) and not CORRECTION_RE.search(line):
            if kind == "historical":
                category = "historical_note_needs_marker"
                action = "mark-not-delete"
                message = "Historical stale claim should be preserved with Correction/Superseded marker."
            elif kind == "risky":
                category = "stale_risky_claim"
                action = "needs_human"
                message = "Risky API/auth/schema/ownership/contract claim looks stale; report instead of auto-fixing."
            else:
                category = "stale_current_claim"
                action = "stale_mark"
                message = "Current-state claim looks stale and needs a dated correction or refresh."
            issues.append(
                issue(
                    line=idx,
                    category=category,
                    action=action,
                    message=message,
                    text=line,
                    section=current_section,
                )
            )

        if CORRECTION_RE.search(line) and stack:
            section_key = (section_text(stack), stack[-1][2])
            correction_counts[section_key] += 1

        for raw_ref in BACKTICK_RE.findall(line):
            candidate = source_candidate(raw_ref, repo_root)
            if not candidate:
                continue
            path, line_no = candidate
            if not repo.exists(path):
                suggestions = repo.suggestions(path)
                action, message = broken_ref_action(suggestions)
                issues.append(
                    issue(
                        line=idx,
                        category="broken_ref",
                        action=action,
                        message=f"{message}: {path}",
                        text=line,
                        section=current_section,
                        suggestions=suggestions,
                    )
                )
                continue
            if line_no is not None:
                count = repo.line_count(path)
                if count is not None and line_no > count:
                    issues.append(
                        issue(
                            line=idx,
                            category="line_out_of_range",
                            action="needs_human",
                            message=f"Line {line_no} is beyond HEAD file length {count}: {path}",
                            text=line,
                            section=current_section,
                        )
                    )

    for (section_name, section_line), count in correction_counts.items():
        if count > args.max_corrections:
            issues.append(
                issue(
                    line=section_line,
                    category="compact_section",
                    action="needs_human",
                    message=f"Section has {count} corrections/supersessions; compact before adding more.",
                    text=section_name,
                    section=section_name,
                )
            )

    summary = Counter(item["action"] for item in issues)
    return {
        "kb_file": str(kb_file),
        "repo_root": str(repo_root),
        "summary": {
            "total": len(issues),
            "auto_fix": summary.get("auto-fix", 0),
            "stale_mark": summary.get("stale_mark", 0),
            "needs_human": summary.get("needs_human", 0),
            "mark_not_delete": summary.get("mark-not-delete", 0),
        },
        "issues": sorted(issues, key=lambda item: (item["line"], item["category"])),
    }


def print_text(result: dict[str, Any]) -> None:
    summary = result["summary"]
    print(f"KB hygiene scan: {result['kb_file']}")
    print(
        "Summary: "
        f"total={summary['total']} "
        f"auto-fix={summary['auto_fix']} "
        f"stale-mark={summary['stale_mark']} "
        f"mark-not-delete={summary['mark_not_delete']} "
        f"needs-human={summary['needs_human']}"
    )
    if not result["issues"]:
        print("No hygiene issues found.")
        return
    for item in result["issues"]:
        label = item["action"].upper()
        print(f"[{label}] line {item['line']} {item['category']}: {item['message']}")
        if item.get("suggestions"):
            print(f"  suggestions: {', '.join(item['suggestions'])}")
        print(f"  section: {item['section'] or '(none)'}")


def main() -> int:
    args = parse_args()
    result = scan(args)
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print_text(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
