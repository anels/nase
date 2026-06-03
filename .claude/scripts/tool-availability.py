#!/usr/bin/env python3
"""Report optional CLI tool availability for nase workflows."""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from dataclasses import dataclass
from typing import Iterable


@dataclass(frozen=True)
class Tool:
    group: str
    tool: str
    binary: str
    brew: str
    impact: str


TOOLS: tuple[Tool, ...] = (
    Tool("baseline", "ripgrep", "rg", "ripgrep", "repo search, context gathering, sensitive artifact scans"),
    Tool("baseline", "fd", "fd", "fd", "file discovery and scoped inventory"),
    Tool("baseline", "yq", "yq", "yq", "YAML, TOML, XML, HCL, and JSON inspection"),
    Tool("baseline", "shellcheck", "shellcheck", "shellcheck", "shell and hook validation"),
    Tool("baseline", "shfmt", "shfmt", "shfmt", "shell formatting"),
    Tool("ci", "actionlint", "actionlint", "actionlint", "GitHub Actions workflow validation"),
    Tool("review", "ast-grep", "ast-grep", "ast-grep", "structural code search and rewrite"),
    Tool("review", "semgrep", "semgrep", "semgrep", "focused static-analysis scans"),
    Tool("review", "trivy", "trivy", "trivy", "dependency, image, filesystem, IaC, and secret scans"),
    Tool("security", "gitleaks", "gitleaks", "gitleaks", "secret scanning for repos, diffs, and staged changes"),
    Tool("security", "hadolint", "hadolint", "hadolint", "Dockerfile linting"),
    Tool("diff", "difftastic", "difft", "difftastic", "syntax-aware diffs with JSON output"),
    Tool("repo", "ripgrep-all", "rga", "ripgrep-all", "search inside PDFs, Office docs, and archives"),
    Tool("repo", "just", "just", "just", "project command discovery from justfiles"),
    Tool("repo", "universal-ctags", "ctags", "universal-ctags", "symbol inventory and language-aware indexes"),
    Tool("data", "jc", "jc", "jc", "convert CLI output to JSON"),
    Tool("data", "duckdb", "duckdb", "duckdb", "SQL over local CSV, JSON, Parquet, and logs"),
    Tool("data", "miller", "mlr", "miller", "CSV and JSONL reshaping"),
    Tool("data", "qsv", "qsv", "qsv", "fast CSV sampling, stats, and slicing"),
    Tool("usage", "ccusage", "ccusage", "ccusage", "coding-agent token and cost summaries"),
    Tool("api", "httpie", "http", "httpie", "REST smoke checks"),
    Tool("api", "grpcurl", "grpcurl", "grpcurl", "gRPC service discovery and calls"),
    Tool("api", "websocat", "websocat", "websocat", "WebSocket smoke checks"),
    Tool("docs", "lychee", "lychee", "lychee", "local Markdown link checks"),
    Tool("docs", "pandoc", "pandoc", "pandoc", "document conversion"),
    Tool("docs", "qpdf", "qpdf", "qpdf", "PDF inspection and transformation"),
    Tool("docs", "pdftotext", "pdftotext", "poppler", "PDF text extraction"),
    Tool("docs", "imagemagick", "magick", "imagemagick", "image inspection and conversion"),
    Tool("perf", "hyperfine", "hyperfine", "hyperfine", "local command benchmarking"),
)


GROUPS = tuple(dict.fromkeys(tool.group for tool in TOOLS))


def selected_tools(args: argparse.Namespace) -> list[Tool]:
    if args.all:
        return list(TOOLS)
    groups = args.group or ["baseline"]
    selected = [tool for tool in TOOLS if tool.group in groups]
    return selected


def status_for(tool: Tool) -> dict[str, str | None]:
    path = shutil.which(tool.binary)
    return {
        "group": tool.group,
        "tool": tool.tool,
        "binary": tool.binary,
        "status": "ok" if path else "missing",
        "path": path,
        "brew": tool.brew,
        "impact": tool.impact,
    }


def rows_for(tools: Iterable[Tool], missing_only: bool) -> list[dict[str, str | None]]:
    rows = [status_for(tool) for tool in tools]
    if missing_only:
        rows = [row for row in rows if row["status"] == "missing"]
    return rows


def print_table(rows: list[dict[str, str | None]]) -> None:
    if not rows:
        print("All selected tools are available.")
        return
    print("| Group | Tool | Binary | Status | Install | Impact |")
    print("|-------|------|--------|--------|---------|--------|")
    for row in rows:
        install = f"brew install {row['brew']}" if row["status"] == "missing" else "-"
        print(
            f"| {row['group']} | {row['tool']} | `{row['binary']}` | "
            f"{row['status']} | `{install}` | {row['impact']} |"
        )


def print_brew_install(rows: list[dict[str, str | None]]) -> None:
    formulas = sorted({str(row["brew"]) for row in rows if row["status"] == "missing"})
    if formulas:
        print("brew install " + " ".join(formulas))
    else:
        print("All selected tools are available.")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--group", action="append", choices=GROUPS, help="Tool group to report; repeatable")
    parser.add_argument("--all", action="store_true", help="Report every known tool")
    parser.add_argument("--format", choices=("table", "json"), default="table")
    parser.add_argument("--missing", action="store_true", help="Show only missing tools")
    parser.add_argument("--install", choices=("brew",), help="Print one install command for missing tools")
    args = parser.parse_args(argv)
    if args.all and args.group:
        parser.error("--all cannot be combined with --group")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    rows = rows_for(selected_tools(args), args.missing)
    if args.install == "brew":
        print_brew_install(rows)
    elif args.format == "json":
        print(json.dumps(rows, indent=2))
    else:
        print_table(rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
