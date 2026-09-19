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
from datetime import date
from typing import Any

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import nase_git
from nase_time import calendar_day, local_today

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
FENCE_RE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
DATED_HEADING_RE = re.compile(r"^###\s+(20[0-9]{2}-[0-9]{2}-[0-9]{2})\s+[—-]\s+(.+?)\s*$")
DOMAIN_MAP_TARGET_RE = re.compile(r"^\s*-\s+.+?→\s+([^ \t\[]+)")
BACKTICK_RE = re.compile(r"`([^`\n]+)`")
WORKSPACE_REF_PREFIXES = (
    "workspace/",
    "memory/",
)

CURATION_PROTECTED_RE = re.compile(
    r"\b(incidents?|postmortems?|post-mortems?|outages?|sev[0-9]|decisions?|adr|rationales?"
    r"|constraints?|invariants?|gotchas?|footguns?|ownership|alumni|security|credentials?"
    r"|secrets?|runbooks?|cross-validation)\b",
    re.I,
)
CURATION_DATE_RE = re.compile(r"(20[0-9]{2})-([0-9]{2})(?:-([0-9]{2}))?")
VERIFIED_RE = re.compile(r"\bverified\s+20[0-9]{2}-[0-9]{2}-[0-9]{2}\b", re.I)
CURATION_BUDGET_RATIO = 0.30
MERGE_OVERLAP_RATIO = 0.25


class RepoIndex:
    def __init__(self, repo_root: pathlib.Path):
        self.repo_root = repo_root
        self.paths = self._load_paths()
        self.by_basename: dict[str, list[str]] = defaultdict(list)
        for path in self.paths:
            self.by_basename[pathlib.PurePosixPath(path).name].append(path)

    def _git(self, *args: str) -> subprocess.CompletedProcess[str]:
        return nase_git.run(*args, repo=self.repo_root, text=True)

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
    parser.add_argument("--repo-root", help="Repo root used to validate source refs.")
    parser.add_argument("--kb-file", help="Project KB file to scan.")
    parser.add_argument("--workspace-scan", action="store_true", help="Scan workspace/kb structure.")
    parser.add_argument("--root", default=".", help="Workspace root for --workspace-scan.")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON.")
    parser.add_argument("--today", help="Override current date as YYYY-MM-DD for tests.")
    parser.add_argument("--stale-days", type=int, default=30, help="Age threshold for Last updated warnings.")
    parser.add_argument(
        "--max-corrections",
        type=int,
        default=3,
        help="Corrections/supersessions per section before compaction is suggested.",
    )
    parser.add_argument(
        "--curate-age-days",
        type=int,
        default=90,
        help="Age after which a dated log section is nominated for curation.",
    )
    parser.add_argument(
        "--max-kb-lines",
        type=int,
        default=800,
        help="Non-blank line budget for one project KB file.",
    )
    parser.add_argument(
        "--no-curate",
        action="store_true",
        help="Skip the curation pass and report hygiene issues only.",
    )
    return parser.parse_args()


def require_file_mode_args(args: argparse.Namespace) -> None:
    if not args.repo_root or not args.kb_file:
        raise SystemExit("--repo-root and --kb-file are required unless --workspace-scan is used")


def fenced_lines(lines: list[str]) -> set[int]:
    """Line numbers inside fenced code blocks.

    Shell comments such as `# 1. VSTest run ids` match the heading pattern, so
    without this the scanner reports section paths that do not exist and, worse,
    hands curation a section span that starts inside a code block.
    """
    inside: set[int] = set()
    fence: str | None = None
    for idx, line in enumerate(lines, start=1):
        match = FENCE_RE.match(line)
        if fence is None:
            if match:
                fence = match.group(1)[0]
                inside.add(idx)
            continue
        inside.add(idx)
        if match and match.group(1)[0] == fence:
            fence = None
    return inside


def normalize_heading(title: str) -> str:
    title = re.sub(r"`([^`]+)`", r"\1", title)
    title = re.sub(r"\s+", " ", title.strip().lower())
    return title.rstrip(":")


def today_value(raw: str | None) -> date:
    if raw:
        return calendar_day(raw).date()
    return local_today()


def issue(
    *,
    line: int,
    category: str,
    action: str,
    message: str,
    text: str,
    section: str,
    suggestions: list[str] | None = None,
    **extra: Any,
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
    data.update(extra)
    return data


def workspace_issue(category: str, message: str, path: pathlib.Path, **extra: Any) -> dict[str, Any]:
    data: dict[str, Any] = {
        "category": category,
        "action": "needs_human",
        "message": message,
        "path": path.as_posix(),
    }
    data.update(extra)
    return data


def kb_markdown_files(root: pathlib.Path) -> list[pathlib.Path]:
    kb_root = root / "workspace" / "kb"
    if not kb_root.is_dir():
        return []
    return sorted(path for path in kb_root.rglob("*.md") if path.name != ".domain-map.md")


def normalize_dated_heading_title(title: str) -> str:
    return re.sub(r"\s+", " ", title.strip().lower())


def domain_map_targets(root: pathlib.Path) -> set[str]:
    domain_map = root / "workspace" / "kb" / ".domain-map.md"
    if not domain_map.is_file():
        return set()
    targets: set[str] = set()
    in_comment = False
    for line in domain_map.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.strip()
        if in_comment:
            if "-->" in stripped:
                in_comment = False
            continue
        if stripped.startswith("<!--"):
            if "-->" not in stripped:
                in_comment = True
            continue
        match = DOMAIN_MAP_TARGET_RE.match(line)
        if match:
            targets.add(match.group(1).strip().removeprefix("./"))
    return targets


def content_line_count(path: pathlib.Path) -> int:
    count = 0
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith(("#", "<!--")):
            continue
        count += 1
    return count


def workspace_scan(root: pathlib.Path) -> dict[str, Any]:
    root = root.resolve()
    files = kb_markdown_files(root)
    issues: list[dict[str, Any]] = []
    dated_headings: dict[tuple[str, str], list[tuple[str, int]]] = defaultdict(list)

    for file_path in files:
        rel = file_path.relative_to(root).as_posix()
        for idx, line in enumerate(file_path.read_text(encoding="utf-8", errors="replace").splitlines(), start=1):
            match = DATED_HEADING_RE.match(line)
            if match:
                key = (match.group(1), normalize_dated_heading_title(match.group(2)))
                dated_headings[key].append((rel, idx))
        if content_line_count(file_path) <= 2:
            issues.append(
                workspace_issue(
                    "sparse_file",
                    "KB file has two or fewer non-heading content lines.",
                    pathlib.Path(rel),
                )
            )

    for (date_value, title), hits in sorted(dated_headings.items()):
        if len(hits) <= 1:
            continue
        first_path = pathlib.Path(hits[0][0])
        issues.append(
            workspace_issue(
                "duplicate_dated_heading",
                f"Duplicate dated heading: {date_value} — {title}",
                first_path,
                hits=[{"path": path, "line": line} for path, line in hits],
            )
        )

    targets = domain_map_targets(root)
    issues.extend(
        workspace_issue(
            "domain_map_missing_target",
            "Domain map target does not exist.",
            pathlib.Path(target),
        )
        for target in sorted(targets)
        if not (root / target).is_file()
    )

    mapped = {path for path in targets if path.startswith("workspace/kb/")}
    for file_path in files:
        rel = file_path.relative_to(root).as_posix()
        if rel not in mapped:
            issues.append(
                workspace_issue(
                    "domain_map_orphan",
                    "KB markdown file is not referenced by workspace/kb/.domain-map.md.",
                    pathlib.Path(rel),
                )
            )

    category_counts = Counter(item["category"] for item in issues)
    return {
        "root": str(root),
        "summary": {
            "total": len(issues),
            "duplicate_dated_headings": category_counts["duplicate_dated_heading"],
            "domain_map_missing_targets": category_counts["domain_map_missing_target"],
            "domain_map_orphans": category_counts["domain_map_orphan"],
            "sparse_files": category_counts["sparse_file"],
        },
        "issues": sorted(issues, key=lambda item: (item["category"], item["path"])),
    }


def section_text(stack: list[tuple[int, str, int]]) -> str:
    return " > ".join(title for _, title, _ in stack)


def section_kind(stack: list[tuple[int, str, int]]) -> str:
    text = section_text(stack)
    if RISKY_SECTION_RE.search(text):
        return "risky"
    if HISTORICAL_SECTION_RE.search(text):
        return "historical"
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


def heading_date(title: str) -> date | None:
    """Newest date named in a heading, or None.

    A range heading such as `2026-04-07 -> 2026-04-09` ages from its newest
    date, so a still-running topic is never aged out by the day it started.
    """
    best: date | None = None
    for match in CURATION_DATE_RE.finditer(title):
        year, month, day = int(match.group(1)), int(match.group(2)), int(match.group(3) or 1)
        try:
            value = date(year, month, day)
        except ValueError:
            continue
        if best is None or value > best:
            best = value
    return best


def build_sections(lines: list[str], fenced: set[int]) -> list[dict[str, Any]]:
    """Every heading with its line span and its ancestor titles."""
    heads: list[tuple[int, str, int]] = []
    for idx, line in enumerate(lines, start=1):
        match = None if idx in fenced else HEADING_RE.match(line)
        if match:
            heads.append((len(match.group(1)), match.group(2).strip(), idx))

    sections: list[dict[str, Any]] = []
    for pos, (level, title, start) in enumerate(heads):
        end = len(lines)
        for next_level, _, next_start in heads[pos + 1 :]:
            if next_level <= level:
                end = next_start - 1
                break
        ancestors: list[str] = []
        want = level - 1
        for prev_level, prev_title, _ in reversed(heads[:pos]):
            if prev_level <= want:
                ancestors.append(prev_title)
                want = prev_level - 1
                if want <= 0:
                    break
        sections.append(
            {
                "level": level,
                "title": title,
                "start": start,
                "end": end,
                "path": [*reversed(ancestors), title],
            }
        )
    return sections


def is_protected(section: dict[str, Any]) -> bool:
    """Sections curation never nominates.

    A section that records why something is the way it is answers a question no
    `git log` replays, so age says nothing about its value. The same test guards
    every curation category, deletion and merge alike.
    """
    return bool(
        CURATION_PROTECTED_RE.search(" > ".join(section["path"]))
        or VERIFIED_RE.search(section["title"])
    )


def section_ref_health(
    body: list[str], repo: RepoIndex, repo_root: pathlib.Path
) -> tuple[int, int]:
    """Source refs in a section that still resolve at HEAD, and those that do not."""
    live = dead = 0
    for line in body:
        for raw_ref in BACKTICK_RE.findall(line):
            candidate = source_candidate(raw_ref, repo_root)
            if not candidate:
                continue
            if repo.exists(candidate[0]):
                live += 1
            else:
                dead += 1
    return live, dead


TOPIC_STOPWORDS = {
    "and",
    "api",
    "fix",
    "fixes",
    "for",
    "from",
    "into",
    "new",
    "note",
    "notes",
    "the",
    "update",
    "updates",
    "with",
}


def topic_key(title: str) -> frozenset[str]:
    """Significant words in a heading, with dates, PR refs, and noise removed."""
    text = CURATION_DATE_RE.sub(" ", title)
    text = re.sub(r"#\s*[0-9]+", " ", text)
    words = {
        word
        for word in re.findall(r"[a-z][a-z0-9.]{2,}", text.lower())
        if word not in TOPIC_STOPWORDS
    }
    return frozenset(words)


def merge_candidates(sections: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Sections that cover one topic across several dated entries.

    Splitting one subject over five dated blocks forces a reader to replay
    history to learn the current state. Only dated, unprotected headings are
    grouped, because an undated heading is a topical current-state section and
    merging two of those destroys a distinction the author made on purpose.

    Two shared significant words plus a quarter of the combined vocabulary is a
    deliberately narrow signal, because a wrong grouping costs a wrong rewrite.
    """
    keyed: list[tuple[dict[str, Any], frozenset[str]]] = []
    for section in sections:
        if section["level"] < 2 or heading_date(section["title"]) is None:
            continue
        if is_protected(section):
            continue
        key = topic_key(section["title"])
        if len(key) >= 2:
            keyed.append((section, key))
    parent = list(range(len(keyed)))

    def find(node: int) -> int:
        while parent[node] != node:
            parent[node] = parent[parent[node]]
            node = parent[node]
        return node

    for left in range(len(keyed)):
        key = keyed[left][1]
        for right in range(left + 1, len(keyed)):
            other = keyed[right][1]
            shared = key & other
            if len(shared) >= 2 and len(shared) / len(key | other) >= MERGE_OVERLAP_RATIO:
                parent[find(left)] = find(right)

    groups: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for index, (section, _) in enumerate(keyed):
        groups[find(index)].append(section)

    issues: list[dict[str, Any]] = []
    for group in groups.values():
        if len(group) < 2:
            continue
        group.sort(key=lambda item: item["start"])
        head = group[0]
        others = ", ".join(f"line {item['start']}" for item in group[1:])
        issues.append(
            issue(
                line=head["start"],
                category="merge_candidate",
                action="curate",
                message=(
                    f"{len(group)} sections cover the same topic ({others}). "
                    "Reconcile them into one current-state section and keep only the "
                    "dated entries that record a decision."
                ),
                text="#" * head["level"] + f" {head['title']}",
                section=" > ".join(head["path"]),
                duplicate_lines=[item["start"] for item in group],
            )
        )
    return sorted(issues, key=lambda item: item["line"])


def curation_scan(
    *,
    lines: list[str],
    repo: RepoIndex,
    repo_root: pathlib.Path,
    fenced: set[int],
    today: date,
    age_days: int,
    max_kb_lines: int,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Report which dated sections have outlived their usefulness.

    The scanner never decides to delete. It measures age, size, and whether the
    code a section describes still exists, so `/nase:onboard` can fold the
    durable half into a current-state section before removing the rest.
    """
    sections = build_sections(lines, fenced)
    issues: list[dict[str, Any]] = []
    total_lines = sum(1 for line in lines if line.strip())
    candidate_lines = 0
    covered_end = 0

    for section in sections:
        if section["level"] < 2 or section["start"] <= covered_end:
            continue

        # A dated heading is what marks an entry as a log rather than a topic, so
        # `## API Surface` stays whatever dates its body happens to cite.
        own = heading_date(section["title"])
        if own is None or is_protected(section):
            continue

        # Age from the newest date anywhere inside, so an old container still
        # collecting this month's findings is not nominated along with them.
        body = lines[section["start"] : section["end"]]
        dates = [own]
        dates += [
            found
            for nested in sections
            if section["start"] <= nested["start"] <= section["end"]
            and (found := heading_date(nested["title"])) is not None
        ]
        dates += [found for line in body if (found := heading_date(line)) is not None]
        when = max(dates)
        age = (today - when).days
        if age <= age_days:
            continue

        live, dead = section_ref_health(body, repo, repo_root)
        span = sum(1 for line in body if line.strip()) + 1
        candidate_lines += span
        covered_end = section["end"]
        issues.append(
            issue(
                line=section["start"],
                category="curation_candidate",
                action="curate",
                message=(
                    f"Dated section is {age} days old and {span} lines; "
                    f"{live} source refs still resolve at HEAD, {dead} do not. "
                    "Fold any durable fact into a current-state section before removing it."
                ),
                text=lines[section["start"] - 1],
                section=" > ".join(section["path"]),
                age_days=age,
                span_lines=span,
                refs_at_head=live,
                refs_missing=dead,
            )
        )

    issues.extend(merge_candidates(sections))

    top_sections = [item for item in sections if item["level"] == 2]
    dated_top = [item for item in top_sections if heading_date(item["title"])]
    if len(dated_top) >= 12 and len(dated_top) >= 0.4 * len(top_sections):
        issues.append(
            issue(
                line=1,
                category="reorganize_candidate",
                action="curate",
                message=(
                    f"{len(dated_top)} of {len(top_sections)} top-level sections are dated entries; "
                    "the file reads as a changelog rather than a KB. Regroup the durable facts under "
                    "`.claude/docs/kb-template.md -> Project KB Structure`."
                ),
                text="",
                section="(file)",
                dated_top_sections=len(dated_top),
                top_sections=len(top_sections),
            )
        )

    if total_lines > max_kb_lines:
        issues.append(
            issue(
                line=1,
                category="oversized_kb",
                action="curate",
                message=(
                    f"KB is {total_lines} non-blank lines against a {max_kb_lines} budget; "
                    "curate or split by topic."
                ),
                text="",
                section="(file)",
                total_lines=total_lines,
            )
        )

    budget_lines = int(total_lines * CURATION_BUDGET_RATIO)
    curation = {
        "dated_top_sections": len(dated_top),
        "top_sections": len(top_sections),
        "total_lines": total_lines,
        "candidate_lines": candidate_lines,
        "candidate_ratio": round(candidate_lines / total_lines, 4) if total_lines else 0.0,
        "budget_ratio": CURATION_BUDGET_RATIO,
        "budget_lines": budget_lines,
        "over_budget": candidate_lines > budget_lines,
    }
    return issues, curation


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

    fenced = fenced_lines(lines)

    for idx, line in enumerate(lines, start=1):
        heading = None if idx in fenced else HEADING_RE.match(line)
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
            parsed = calendar_day(last_updated.group(1)).date()
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

    curation: dict[str, Any] | None = None
    if not args.no_curate:
        curation_issues, curation = curation_scan(
            lines=lines,
            repo=repo,
            repo_root=repo_root,
            fenced=fenced,
            today=today,
            age_days=args.curate_age_days,
            max_kb_lines=args.max_kb_lines,
        )
        issues.extend(curation_issues)

    summary = Counter(item["action"] for item in issues)
    result: dict[str, Any] = {
        "kb_file": str(kb_file),
        "repo_root": str(repo_root),
        "summary": {
            "total": len(issues),
            "auto_fix": summary.get("auto-fix", 0),
            "stale_mark": summary.get("stale_mark", 0),
            "needs_human": summary.get("needs_human", 0),
            "mark_not_delete": summary.get("mark-not-delete", 0),
            "curate": summary.get("curate", 0),
        },
        "issues": sorted(issues, key=lambda item: (item["line"], item["category"])),
    }
    if curation is not None:
        result["curation"] = curation
    return result


def print_text(result: dict[str, Any]) -> None:
    summary = result["summary"]
    if "kb_file" not in result:
        print(f"KB workspace scan: {result['root']}")
        print(
            "Summary: "
            f"total={summary['total']} "
            f"duplicate-dated-headings={summary['duplicate_dated_headings']} "
            f"domain-map-missing-targets={summary['domain_map_missing_targets']} "
            f"domain-map-orphans={summary['domain_map_orphans']} "
            f"sparse-files={summary['sparse_files']}"
        )
        if not result["issues"]:
            print("No workspace hygiene issues found.")
            return
        for item in result["issues"]:
            label = item["action"].upper()
            print(f"[{label}] {item['path']} {item['category']}: {item['message']}")
        return

    print(f"KB hygiene scan: {result['kb_file']}")
    print(
        "Summary: "
        f"total={summary['total']} "
        f"auto-fix={summary['auto_fix']} "
        f"stale-mark={summary['stale_mark']} "
        f"mark-not-delete={summary['mark_not_delete']} "
        f"needs-human={summary['needs_human']} "
        f"curate={summary.get('curate', 0)}"
    )
    curation = result.get("curation")
    if curation:
        budget = "over budget" if curation["over_budget"] else "within budget"
        print(
            f"Curation: {curation['candidate_lines']}/{curation['total_lines']} lines "
            f"({curation['candidate_ratio']:.0%}) are candidates, "
            f"budget {curation['budget_lines']} lines per run - {budget}."
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
    if args.workspace_scan:
        result = workspace_scan(pathlib.Path(args.root))
    else:
        require_file_mode_args(args)
        result = scan(args)
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print_text(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
