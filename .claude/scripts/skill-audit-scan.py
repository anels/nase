#!/usr/bin/env python3
"""Deterministically scan skill Markdown for security-review leads."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class Rule:
    category: int
    name: str
    severity: str
    label: str
    pattern: re.Pattern[str]
    reason: str


def rule(category: int, name: str, severity: str, label: str, pattern: str, reason: str) -> Rule:
    return Rule(category, name, severity, label, re.compile(pattern, re.IGNORECASE), reason)


RULES = (
    rule(1, "Command Injection", "FAIL", "recursive delete outside workspace", r"\brm\s+(?:(?:--recursive|-[A-Za-z]*r[A-Za-z]*)(?:\s+--?[A-Za-z-]+)*)\s+(?:--\s+)?[\"']?(?:/|~|\.\.)", "can delete files outside the workspace"),
    rule(1, "Command Injection", "FAIL", "piped download", r"\b(?:curl|wget)\b[^\n|]*\|\s*[\"']?(?:(?:/[A-Za-z0-9._-]+)*/)?(?:bash|sh|python(?:3)?)\b", "downloads and executes untrusted content"),
    rule(1, "Command Injection", "FAIL", "dynamic shell evaluation", r"\b(?:(?:eval|exec)\b[^\n]*\$(?:\{)?(?:ARGUMENTS|USER_INPUT|INPUT|URL|PATH)\b|source\s+[\"']?\$(?:\{)?(?:ARGUMENTS|USER_INPUT|INPUT|URL|PATH)\b)", "executes dynamically supplied input"),
    rule(1, "Command Injection", "FAIL", "decoded command execution", r"\bbase64\s+(?:-[^| ]*d|--decode)\b[^|]*\|\s*[\"']?(?:(?:/[A-Za-z0-9._-]+)*/)?(?:bash|sh|python(?:3)?)\b", "decodes and executes hidden content"),
    rule(1, "Command Injection", "FAIL", "sudo", r"\bsudo\b", "elevates command privileges"),
    rule(1, "Command Injection", "FAIL", "external command substitution", r"(?:\$\([^\n)]*\$(?:\{)?(?:ARGUMENTS|USER_INPUT|INPUT|URL|PATH)\b[^\n)]*\)|`(?=[^\n`]*\s)[^\n`]*\$(?:\{)?(?:ARGUMENTS|USER_INPUT|INPUT|URL|PATH)\b[^\n`]*`)", "expands external input through the shell"),
    rule(2, "Data Exfiltration", "FAIL", "file upload", r"\b(?:curl\b[^\n]*(?:-d|--data(?:-binary)?)\s*[\"']?@|wget\b[^\n]*--post-file)", "uploads local file content"),
    rule(2, "Data Exfiltration", "FAIL", "sensitive data network send", r"\bbase64\b[^\n]*(?:\.env|\.ssh|credential|secret|token)[^\n]*(?:curl|wget|http)", "encodes sensitive data for a network request"),
    rule(2, "Data Exfiltration", "FAIL", "workspace copy outside root", r"\b(?:cp|mv|rsync|tee)\b[^\n]*(?:workspace/|\.claude/)[^\n]*(?:/tmp/|~/Desktop/|/[A-Za-z])", "copies workspace content outside the workspace"),
    rule(2, "Data Exfiltration", "FAIL", "workspace redirection outside root", r"\b(?:cat|base64)\b[^\n]*(?:workspace/|\.claude/)[^\n]*>{1,2}\s*[\"']?(?:/|~)", "writes workspace content outside the workspace"),
    rule(2, "Data Exfiltration", "FAIL", "GitHub content upload", r"\bgh\s+(?:gist\s+create|api\b[^\n]*(?:--method\s+POST|-X\s+POST|--input))", "uploads content to GitHub"),
    rule(3, "Prompt Injection", "WARN", "instruction override", r"\bignore\s+(?:all\s+)?(?:previous|prior)\s+instructions\b", "attempts to override governing instructions"),
    rule(3, "Prompt Injection", "WARN", "role reassignment", r"\b(?:you are now|from this point on,?\s+you are)\b", "attempts to reassign the model role"),
    rule(3, "Prompt Injection", "WARN", "rules bypass", r"\bdo not follow\b[^\n]*\b(?:CLAUDE\.md|rules|instructions)\b", "attempts to bypass repository rules"),
    rule(3, "Prompt Injection", "WARN", "system prompt injection", r"(?:\b(?:new\s+)?system prompt\s*:|<system>)", "introduces a competing system prompt"),
    rule(3, "Prompt Injection", "WARN", "hidden behavior", r"\b(?:do not tell|hide this from)\s+the user\b", "asks the agent to conceal behavior"),
    rule(3, "Prompt Injection", "WARN", "safety bypass", r"\b(?:disable|bypass|skip)\b[^\n]{0,40}\b(?:safety(?:\s+checks?)?|verification(?:\s+(?:steps?|checks?))?)\b", "asks the agent to bypass a safety control"),
    rule(4, "Unsafe File Operations", "FAIL", "protected user or system path", r"(?:~/(?:\.claude/(?!projects/)|\.ssh/|\.gnupg/|\.aws/|\.kube/)|~/(?:\.bashrc|\.zshrc|\.profile|\.gitconfig)\b|/(?:etc|usr|var)/)", "modifies a protected path outside the workspace"),
    rule(4, "Unsafe File Operations", "FAIL", "absolute path write", r"(?:\d*>{1,2}\s*[\"']?/(?!dev/(?:null|stdout|stderr)\b)[A-Za-z0-9._/-]+|\b(?:touch|mkdir|install|tee|cp|mv|chmod|chown)\b[^\n]*\s[\"']?/[A-Za-z0-9._/-]+)", "writes to an absolute path outside the workspace"),
    rule(4, "Unsafe File Operations", "FAIL", "global git configuration", r"\bgit\s+config\s+--global\b", "changes global Git configuration"),
    rule(5, "Supply Chain", "WARN", "non-standard package source", r"\b(?:pip|npm|go|cargo)\s+install\b[^\n]*(?:https?://|--index-url|--registry|--git)", "installs code from a non-standard source"),
    rule(5, "Supply Chain", "WARN", "clone and execute", r"\bgit\s+clone\b[^\n]*(?:&&|;)\s*(?:cd|bash|sh|python|make|\./)", "executes code immediately after cloning it"),
    rule(5, "Supply Chain", "WARN", "downloaded executable or script", r"\bcurl\b(?=[^\n]*https?://)(?=[^\n]*(?:-o|--output|-O)\b)[^\n]*", "downloads executable content from a URL"),
    rule(5, "Supply Chain", "WARN", "unknown MCP server", r"\b(?:add|install|register)\b[^\n]*\bMCP server\b", "adds an external tool server"),
    rule(6, "Credential Exposure", "FAIL", "API token", r"\b(?:sk-(?:proj-)?[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})\b|\bBearer\s+[A-Za-z0-9._~+/=-]{8,}", "contains a hardcoded credential-like token"),
    rule(6, "Credential Exposure", "FAIL", "hardcoded secret", r"\b(?:[A-Z0-9_]*(?:PASSWORD|PASSWD|PWD|TOKEN|API[_-]?KEY|CLIENT[_-]?SECRET|ACCESS[_-]?TOKEN|REFRESH[_-]?TOKEN|SECRET))\b\s*[:=]\s*[\"']?(?!(?:YOUR_[A-Z0-9_]+|EXAMPLE|DUMMY|PLACEHOLDER|REDACTED|CHANGEME)\b)[A-Za-z0-9._~+/@!#%^&*=-]{8,}", "contains a non-placeholder hardcoded secret"),
    rule(6, "Credential Exposure", "FAIL", "private key", r"-----BEGIN (?:RSA )?PRIVATE KEY-----", "contains private key material"),
)

EXPLANATION_RE = re.compile(
    r"\b(?:avoid|do not|don't|never|must not|e\.g\.|for example|flag|detect|pattern|"
    r"such as|quoted|explanatory|should not|not automatically)\b",
    re.IGNORECASE,
)
PROMPT_EXPLANATION_RE = re.compile(
    r"\b(?:avoid|e\.g\.|for example|flag|detect|pattern|such as|quoted|"
    r"explanatory|not automatically)\b",
    re.IGNORECASE,
)
EXAMPLE_RE = re.compile(r"(?<![./@A-Za-z0-9_-])examples?\b", re.IGNORECASE)
NON_EXECUTABLE_FENCES = {"text", "txt", "markdown", "md", "json", "yaml", "yml"}
PRIVILEGE_CATEGORIES = {1, 2, 4, 5}


def shell_line_continues(line: str) -> bool:
    stripped = line.rstrip()
    trailing_backslashes = len(stripped) - len(stripped.rstrip("\\"))
    return trailing_backslashes % 2 == 1 or bool(re.search(r"(?:\|\||\|&|&&|\|)\s*$", stripped))


def markdown_lines(text: str) -> Iterable[tuple[int, str, str]]:
    in_fence = False
    fence_language = ""
    continued_line = ""
    continued_number = 0
    for number, line in enumerate(text.splitlines(), 1):
        fence = re.match(r"^\s*```\s*([^\s`]*)", line)
        if fence:
            if continued_line:
                yield continued_number, continued_line, "executable"
                continued_line = ""
            in_fence = not in_fence
            fence_language = fence.group(1).lower() if in_fence else ""
            continue
        context = "prose"
        if in_fence:
            context = "non-executable" if fence_language in NON_EXECUTABLE_FENCES else "executable"
        if context == "executable" and shell_line_continues(line):
            if not continued_line:
                continued_number = number
            stripped = line.rstrip()
            continued_line += (stripped[:-1] if stripped.endswith("\\") else stripped) + " "
            continue
        if continued_line:
            yield continued_number, continued_line + line, "executable"
            continued_line = ""
            continue
        yield number, line, context
    if continued_line:
        yield continued_number, continued_line, "executable"


def explanatory(line: str, context: str, rule_item: Rule, match_start: int) -> bool:
    stripped = line.strip()
    if "pragma: allowlist secret" in line and rule_item.category == 6:
        return True
    if context == "non-executable" and rule_item.category != 6:
        return True
    if rule_item.label == "absolute path write" and re.search(r"<[A-Za-z0-9_-]+$", line[:match_start]):
        return True
    if (
        rule_item.label == "external command substitution"
        and context == "prose"
        and line[match_start] == "`"
        and line[:match_start].count("`") % 2 == 1
    ):
        return True
    if context == "executable":
        return False
    if stripped.startswith(">"):
        return True
    if rule_item.label == "safety bypass" and re.search(
        r"\b(?:never|not|cannot|can't)\b[^\n]{0,30}\b(?:safety|verification)\b",
        line,
        re.IGNORECASE,
    ):
        return True
    explanation = PROMPT_EXPLANATION_RE if rule_item.category == 3 else EXPLANATION_RE
    markers = [match.start() for regex in (explanation, EXAMPLE_RE) if (match := regex.search(line))]
    return any(marker < match_start for marker in markers)


def finding(rule_item: Rule, line: int) -> dict[str, object]:
    return {
        "category": rule_item.category,
        "category_name": rule_item.name,
        "severity": rule_item.severity,
        "line": line,
        "pattern": rule_item.label,
        "reason": rule_item.reason,
    }


def scan_file(path: Path, display_path: str) -> dict[str, object]:
    text = path.read_text(encoding="utf-8", errors="replace")
    findings: list[dict[str, object]] = []
    privilege_line: int | None = None
    for line_number, line, context in markdown_lines(text):
        for rule_item in RULES:
            match = rule_item.pattern.search(line)
            if match and not explanatory(line, context, rule_item, match.start()):
                findings.append(finding(rule_item, line_number))
                if rule_item.category in PRIVILEGE_CATEGORIES and privilege_line is None:
                    privilege_line = line_number

    if privilege_line is not None:
        findings.append({
            "category": 7,
            "category_name": "Tool Privilege Hygiene",
            "severity": "WARN",
            "line": privilege_line,
            "pattern": "dangerous surface requires enforcement review",
            "reason": "verify deny rules, sandboxing, or hooks cover the scanner lead",
        })

    verdict = "FAIL" if any(item["severity"] == "FAIL" for item in findings) else "WARN" if findings else "PASS"
    return {"file": display_path, "verdict": verdict, "findings": findings}


def resolve_targets(target: str, root: Path) -> list[Path]:
    if target == "all":
        candidates = (
            list((root / "workspace" / "skills").glob("*.md"))
            + list((root / ".claude" / "commands" / "nase").glob("*.md"))
            + list((root / ".claude" / "commands" / "nase" / "workspace").glob("*.md"))
        )
        return sorted({path.resolve() for path in candidates if path.is_file()})
    path = Path(target)
    if not path.is_absolute():
        path = root / path
    if path.is_file():
        return [path.resolve()]
    if path.is_dir():
        return sorted(item.resolve() for item in path.rglob("*.md"))
    raise ValueError(f"target not found: {target}")


def display_path(path: Path, root: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return str(path)


def payload(paths: list[Path], root: Path) -> dict[str, object]:
    results = [scan_file(path, display_path(path, root)) for path in paths]
    counts = {verdict.lower(): sum(item["verdict"] == verdict for item in results) for verdict in ("PASS", "WARN", "FAIL")}
    return {"results": results, "summary": {"files": len(results), **counts}}


def print_report(data: dict[str, object]) -> None:
    summary = data["summary"]
    print("## Skill Security Audit")
    print(f"\nScanned: {summary['files']} files\n")
    print("| File | Verdict | Findings |")
    print("|---|---|---:|")
    for result in data["results"]:
        print(f"| `{result['file']}` | {result['verdict']} | {len(result['findings'])} |")
    for result in data["results"]:
        if not result["findings"]:
            continue
        print(f"\n### `{result['file']}` - {result['verdict']}")
        for item in result["findings"]:
            print(
                f"- [{item['severity']}] Category {item['category']} {item['category_name']} "
                f"(line {item['line']}): {item['pattern']} - {item['reason']}"
            )
    print(f"\nSummary: {summary['pass']} PASS, {summary['warn']} WARN, {summary['fail']} FAIL")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", nargs="?", default="all", help="file, directory, or all")
    parser.add_argument("--root", default=".", help="workspace root used by target=all")
    parser.add_argument("--format", choices=("json", "report"), default="report")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    try:
        paths = resolve_targets(args.target, root)
    except ValueError as exc:
        parser.error(str(exc))
    data = payload(paths, root)
    if args.format == "json":
        json.dump(data, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        print_report(data)
    return 1 if data["summary"]["fail"] else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
