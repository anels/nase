#!/usr/bin/env python3
"""Classify one active effort file with the shared lifecycle contract."""

from __future__ import annotations

import argparse
import json
import re
import shlex
import sys
from collections.abc import Callable
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, NamedTuple

from frontmatter_scalar import (
    canonical_bool,
    extract_frontmatter_scalar,
    normalize_scalar,
)
from nase_time import local_today

Classification = dict[str, Any]
PrRef = dict[str, Any]
LiveRecord = dict[str, Any]
Action = dict[str, Any]

STAGE_DISPLAY = {
    "planning": "Planning",
    "implementing": "Implementing",
    "in_review": "In review",
    "awaiting_deploy": "Awaiting deploy",
    "follow_up_only": "Follow-up only",
}

CHECKBOX_RE = re.compile(r"^\s*-\s*\[([ xX])\]\s+(.+?)\s*$")
PR_REFERENCE_RE = re.compile(
    r"https://github\.com/[^/\s]+/[^/\s]+/pull/[1-9]\d*|\b[^/\s]+/[^#\s]+#[1-9]\d*"
)
FULL_PR_RE = re.compile(
    r"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)"
)
QUALIFIED_PR_RE = re.compile(
    r"(?<![A-Za-z0-9_.-/])([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([1-9][0-9]*)\b"
)
BARE_PR_RE = re.compile(r"(?<![\w#])#([1-9]\d*)\b")
MARKDOWN_PR_LINK_RE = re.compile(
    r"\[([^]]+)\]\(\s*https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*[^)]*\)"
)
DELIVERY_PR_KEY_RE = re.compile(r"(?i)^(pr|prs|phase_[\w-]*_pr)\s*:")
BLOCKED_BY_KEY_RE = re.compile(r"(?i)^blocked-by\s*:")
FRONTMATTER_LIST_ITEM_RE = re.compile(r"^\s*-\s+\S")
REPO_KEY_RE = re.compile(r"(?i)^repo\s*:\s*(.+?)\s*$")
REPO_FULL_NAME_RE = re.compile(r"^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$")
TARGET_PR_COUNT_RE = re.compile(r"(?i)(?:\*\*)?Target PR count(?:\*\*)?\s*:\s*(\d+)\b")
LIFECYCLE_HEADING_RE = re.compile(r"^(#{2,6})\s+Lifecycle\s*$", re.IGNORECASE)
HEADING_RE = re.compile(r"^(#{1,6})\s+\S")
VALIDATION_HEADING_RE = re.compile(r"^(#{2,6})\s+Validation\b", re.IGNORECASE)

# A merged PR whose every changed path matches NON_DEPLOYED_PATH_PATTERNS and none matches
# NON_DEPLOYED_DENY_PATTERNS ships nothing to a ring, so `Deployed` is not applicable to
# it. Matched against both sides of a rename. The deny list wins: these paths are read at
# runtime or drive a deploy even when they sit under a test or docs name. `.github/` is an
# allow-list, not a deny-list: any workflow or script outside it can build, push or apply.
NON_DEPLOYED_DENY_PATTERNS = (
    re.compile(r"(?i)(^|/)\.claude/"),
    re.compile(r"(?i)(^|/)(CLAUDE|SKILL)\.md$"),
    re.compile(r"(?i)(^|/)(prompts?|skills?|agents?|commands)/"),
    re.compile(r"(?i)(^|/)appsettings[^/]*$"),
    re.compile(r"^\.github/actions/"),
    re.compile(
        r"(?i)^\.github/workflows/[^/]*"
        r"(terraform|apply|push|image|docker|infra|azure|aws|gcp|webapp"
        r"|deploy|release|publish|promote|(?<![a-z0-9])cd(?![a-z0-9]))[^/]*$"
    ),
)
NON_DEPLOYED_PATH_PATTERNS = (
    re.compile(r"(?i)(^|/)(tests?|__tests__)/"),
    re.compile(r"(?i)(^|/)[^/]*\.tests?/"),
    re.compile(r"(?i)\.(test|spec)\.(ts|tsx|js|jsx|mjs|cs|py|go|java|rs)$"),
    re.compile(
        r"(?i)^\.github/workflows/(ci|tests?|lint|checks?|validate|pr|verify)"
        r"([-_](linux|macos|windows|unit|e2e|integration|smoke|node|python|dotnet"
        r"|java|go|rust|js|ts))?\.ya?ml$"
    ),
    re.compile(r"^\.github/(CODEOWNERS|pull_request_template\.md)$"),
    re.compile(r"^\.github/ISSUE_TEMPLATE/"),
    re.compile(r"(?i)^docs/.*\.md$"),
    re.compile(r"(?i)^[^/]+\.md$"),
)

STALLED_IDLE_DAYS = 14

# Only a backtick span that starts with one of these is read as a command; other
# spans are identifiers, paths or values.
COMMAND_WORDS = frozenset(
    {
        "gh", "az", "git", "dotnet", "npm", "npx", "pnpm", "yarn", "node", "python",
        "python3", "pytest", "vitest", "jest", "bash", "sh", "curl", "kubectl",
        "terraform", "make", "cargo", "go", "mvn", "gradle", "gradlew",
    }
)  # fmt: skip
HEAVY_COMMAND_RE = re.compile(
    r"""(?ix)^(?:
        dotnet\s+(?:test|build)
      | (?:npm|pnpm|yarn)\s+(?:run\s+)?(?:test|build|ci)
      | (?:npx\s+)?(?:vitest|jest)
      | pytest | python3?\s+-m\s+pytest
      | node\s+--test
      | cargo\s+(?:test|build)
      | go\s+test
      | mvn | gradlew? | make\s+test
      | bash\s+tests/
    )\b"""
)
BACKTICK_SPAN_RE = re.compile(r"`([^`\n]+)`")
ENV_ASSIGNMENT_RE = re.compile(r"^\w+=\S*\s+")
EXPECT_RE = re.compile(r"(?i)\bexpect(?:s|ed)?\b\W{0,4}`([^`\n]+)`")
SHELL_PUNCTUATION = frozenset("();<>|&")
GH_FIELD_FLAGS = frozenset({"-f", "-F", "--field", "--raw-field"})
GH_METHOD_OVERRIDE_RE = re.compile(r"(?i)x-http-method-override")
GH_BUNDLED_SHORT_RE = re.compile(r"^-(?!X)[A-Za-z]{2,}")
AZ_READ_ONLY_VERBS = frozenset(
    {
        ("monitor", "log-analytics", "query"),
        ("monitor", "app-insights", "query"),
        ("monitor", "metrics", "list"),
        ("monitor", "activity-log", "list"),
    }
)


class GitFlagSpec(NamedTuple):
    """The only flags a read-only `git` subcommand may carry; anything else refuses."""

    digits: bool
    short: str
    short_value: str
    long: frozenset[str]
    long_value: frozenset[str]


def _flag_set(names: str) -> frozenset[str]:
    return frozenset(names.split())


GIT_FLAG_SPECS = {
    "grep": GitFlagSpec(
        digits=True,
        short="nivwEFPGlLcohHIaqzpW",
        short_value="eABC",
        long=_flag_set(
            "--cached --untracked --line-number --ignore-case --word-regexp"
            " --invert-match --extended-regexp --fixed-strings --perl-regexp"
            " --basic-regexp --only-matching --count --files-with-matches"
            " --files-without-match --name-only --full-name --heading --break"
            " --null --quiet --show-function --function-context --no-color"
            " --color --text --recursive --no-recursive --all-match --and --or"
            " --not"
        ),
        long_value=_flag_set(
            "--max-depth --regexp --context --after-context --before-context"
        ),
    ),
    "log": GitFlagSpec(
        digits=True,
        short="pi",
        short_value="nSG",
        long=_flag_set(
            "--oneline --all --no-merges --merges --first-parent --reverse --stat"
            " --shortstat --numstat --name-only --name-status --graph --decorate"
            " --no-decorate --abbrev-commit --no-color --color --follow --patch"
            " --no-patch --date-order --topo-order --author-date-order --branches"
            " --tags --remotes --full-history --simplify-merges --ancestry-path"
            " --left-right --cherry-pick --boundary"
        ),
        long_value=_flag_set(
            "--max-count --format --pretty --since --until --after --before --author"
            " --committer --grep --date --skip --abbrev --diff-filter --min-parents"
            " --max-parents"
        ),
    ),
    "show": GitFlagSpec(
        digits=False,
        short="sp",
        short_value="U",
        long=_flag_set(
            "--stat --name-only --name-status --oneline --no-patch --patch"
            " --abbrev-commit --no-color --color --decorate --shortstat --numstat"
            " --first-parent"
        ),
        long_value=_flag_set("--format --pretty --date --abbrev --diff-filter"),
    ),
}
BARE_DEPLOYED_ROW_RE = re.compile(
    r"(?i)^deployed(?:\s*\((?:if applicable|n/a|optional)\))?\s*$"
)
JIRA_ABSENT_VALUES = frozenset({"", "none", "null", "n/a", "~", "-"})
PLAN_ID_RE = re.compile(r"(?i)\bPR[- ]?(\d+[a-z]?)\b")
SEPARATOR_CELL_RE = re.compile(r"^:?-{3,}:?$")

FILE_EVIDENCE_REASONS = frozenset({"files-outside-tests-ci-docs", "files-unverified"})
# Closed set from effort-drift.md -> Next actions. The skill, not next_action, sets
# validation-failed and validation-inconclusive after a run.
NEXT_ACTION_REASONS = frozenset(
    {
        "tests-ci-docs-only",
        "read-only-validation",
        "merge-ready-open-pr",
        "planned-unblocked",
        "plan-row-startable",
        "blocked",
        "no-plan-table",
        "plan-prs-unattributed",
        "no-startable-pr",
        "deployed-checked",
        "deployed-needs-ring-evidence",
        "jira-not-done",
        "files-outside-tests-ci-docs",
        "files-unverified",
        "merge-checks-failing",
        "merge-checks-unknown",
        "validation-not-readonly",
        "validation-heavy-not-run",
        "validation-failed",
        "validation-inconclusive",
        "undelivered-row-stale",
        "delivery-state-unresolved",
        "delivery-pr-not-merged",
        "plan-rows-pending",
        "pending-followups",
        "stalled",
    }
)

# An unchecked row inside ## Lifecycle usually means "this deliverable is still
# owed". These status/bookkeeping rows do not describe another delivery PR, so
# they must not block the transition to `awaiting-deploy`.
#
# Anchored at the start of the row on purpose: matching these words anywhere would
# swallow real deliverables whose prose happens to contain them - "revert the
# CI-verified-only exclusion" names an unopened PR, not a completed verification.
BENIGN_LIFECYCLE_RE = re.compile(
    r"""(?ix)
    ^(?:
        deployed\b                        # Deployed / Deployed to alpha / Deployed (if applicable)
      | merged\b                          # merged-but-unticked is drift, not undelivered work
      | review\s+passed\b
      | effort\s+doc\s+moved\b
    )
    """
)

# These rows also do not represent another delivery PR, but once `Deployed` is
# checked they must remain visible so the effort cannot move to `completed`
# before its post-deploy validation is checked off.
POST_DEPLOY_LIFECYCLE_RE = re.compile(
    r"""(?ix)
    ^(?:
        outcome\s*:
      | verified\b
      | validated\b
      | verification\s+(?:complete|completed|passed)\b
      | validation\s+(?:complete|completed|passed)\b
      | post-?deploy\b
      | (?:alpha|beta|staging|prod(?:uction)?|sc\d+)\s+validation\s+(?:complete|completed|passed)\b
      | (?:(?:alpha|beta|staging|prod(?:uction)?|sc\d+)\s+)?(?:deploy|soak|bake)\s+(?:window|observation|verification)\b
    )
    """
)

# A bare `#{n}` inside `## Lifecycle` is definitionally a PR, except when the row
# itself says the numbers are something else. Effort docs label query, finding and
# step numbers exactly this way, and a greedy sweep turns them into PRs that then
# read UNREADABLE and freeze the effort's transition for good. Matched against a
# de-emphasized copy of the row so `**not** PR numbers` still reads as a denial.
BARE_PR_DENIAL_RE = re.compile(
    r"""(?ix)
    \b(?:
        not \s+ (?:a \s+ )? prs?\b
      | (?:query|finding|step|question|phase|comment|item|criterion|criteria)
        \s+ numbers?\b
    )
    """
)

# Authors of multi-PR efforts often record the outstanding PRs as a trailing
# clause on the *checked* `PR opened` row ("PR-1 #173 (draft); PR-1b + PR-2 still
# pending") instead of giving each one its own row. The row is checked, so the
# unchecked-row scan cannot see it, yet it says plainly that delivery is partial.
OUTSTANDING_CLAUSE_RE = re.compile(
    r"(?i)\b(?:still\s+pending|not\s+(?:yet\s+)?started|remain(?:s|ing)?\s+pending|yet\s+to\s+be\s+opened)\b"
)
PARTIAL_MERGED_RE = re.compile(r"(?i)\bpr[- ]?\d+\s+only\b")


def frontmatter_status(text: str) -> str:
    raw = extract_frontmatter_scalar(text, "status")[0]
    return "" if raw is None else normalize_scalar(raw)


def tracking_only_state(text: str) -> tuple[bool, bool]:
    """Return the ownership flag and whether its scalar is canonical.

    Terminal transitions file these under `archive/{year}/` instead of `done/`,
    so `done/` keeps meaning "work this workspace delivered". The flag is
    deliberately separate from `status: tracked`: status is overwritten by the
    lifecycle transitions below, ownership is not.
    """
    raw, singleton = extract_frontmatter_scalar(text, "tracking_only")
    if not singleton:
        return False, False
    return canonical_bool(raw)


def document_structure(text: str, lines: list[str]) -> dict[str, object]:
    """Report whether the doc carries the structure the lifecycle machinery reads.

    `classify` degrades to the frontmatter fallback when a doc has no canonical
    checkbox, and that degradation is silent: `method: frontmatter` looks the same
    whether the author wrote a Lifecycle block that has not been ticked yet or never
    wrote one at all. The second case is unauditable - no row can ever contradict the
    frontmatter, so `needs_live_verification` stays False and the doc keeps whatever
    status it was last given, forever.

    Only offline-provable defects land in `defects`. Whether a `wontfix` effort's
    delivery PRs actually merged needs a live read, so that pairing is reported as
    fields for `effort-pr-sweep.py --closed` to resolve rather than asserted here.
    """
    has_lifecycle_section = bool(lifecycle_line_ranges(lines))
    # An umbrella/roadmap parent indexes child efforts and delivers nothing itself, so
    # it has no deliverable to record. `children:` is what makes it an index.
    umbrella = extract_frontmatter_scalar(text, "children")[0] is not None
    closed_reason = any(
        extract_frontmatter_scalar(text, key)[0] is not None
        for key in ("closed_reason", "closure", "resolution", "superseded_by")
    )
    partial_raw, partial_singleton = extract_frontmatter_scalar(
        text, "partial_delivery"
    )
    if partial_raw is None:
        partial_delivery, partial_valid = None, True
    elif not partial_singleton:
        partial_delivery, partial_valid = None, False
    else:
        partial_delivery, partial_valid = canonical_bool(partial_raw)

    defects: list[str] = []
    if not has_lifecycle_section and not umbrella:
        defects.append("no-lifecycle-section")
    if partial_raw is not None and not partial_valid:
        defects.append("invalid-partial-delivery")

    return {
        "has_lifecycle_section": has_lifecycle_section,
        "umbrella": umbrella,
        "closed_reason": closed_reason,
        "partial_delivery": partial_delivery,
        "partial_delivery_valid": partial_valid,
        "defects": defects,
    }


def canonical_label(label: str) -> str | None:
    lowered = label.strip().lower()
    if lowered.startswith("implementation started"):
        return "Implementation started"
    if lowered.startswith("pr opened"):
        return "PR opened"
    if lowered.startswith("merged"):
        return "Merged"
    if lowered.startswith("deployed"):
        return "Deployed"
    return None


def stage_from_status(status: str, text: str) -> str:
    if status in {"proposed", "planned", "tracked"}:
        return "planning"
    if status in {"in-progress", "needs-revision", "blocked"}:
        return "implementing"
    if status in {"in-review", "merge-ready", "ready"}:
        return "in_review"
    if status in {"merged", "awaiting-deploy"}:
        return "awaiting_deploy"
    if PR_REFERENCE_RE.search(text):
        return "in_review"
    return "planning"


def section_line_ranges(
    lines: list[str], heading_re: re.Pattern[str]
) -> list[tuple[int, int]]:
    """1-indexed [start, end) spans of every section whose heading matches."""
    ranges: list[tuple[int, int]] = []
    for index, line in enumerate(lines, 1):
        match = heading_re.match(line)
        if not match:
            continue
        start = index + 1
        section_level = len(match.group(1))
        end = len(lines) + 1
        for next_index in range(start, len(lines) + 1):
            heading = HEADING_RE.match(lines[next_index - 1])
            if heading and len(heading.group(1)) <= section_level:
                end = next_index
                break
        ranges.append((start, end))
    return ranges


def lifecycle_line_ranges(lines: list[str]) -> list[tuple[int, int]]:
    """1-indexed [start, end) spans of every `## Lifecycle` section."""
    return section_line_ranges(lines, LIFECYCLE_HEADING_RE)


def strip_emphasis(label: str) -> str:
    return label.lstrip("*_ ").strip()


def deemphasize(line: str) -> str:
    """Drop Markdown emphasis markers so word-boundary matches survive `**not** PR`."""
    return re.sub(r"[*_`]+", " ", line)


def frontmatter_lines(text: str) -> list[str]:
    """The frontmatter body as a list of lines, or [] when absent."""
    match = re.match(r"^---\s*\n(.*?)\n---\s*(?:\n|$)", text, re.DOTALL)
    return match.group(1).splitlines() if match else []


def frontmatter_span(lines: list[str]) -> tuple[int, int]:
    """1-indexed [start, end) span of the frontmatter body, or (1, 1) when absent."""
    if not lines or lines[0].strip() != "---":
        return 1, 1
    for index in range(2, len(lines) + 1):
        if lines[index - 1].strip() == "---":
            return 2, index
    return 1, 1


def repo_token(value: str) -> str:
    """The repository identifier in a `repo:` value, ignoring any trailing prose.

    Real effort docs annotate the key (`repo: acme/widget (live; was greenfield)`,
    `repo: widget (+ acme/frontend coordination)`), so only the first token is the
    identifier. Reading the whole value instead rejects both as malformed, which
    fails the doc closed on a shape the frontmatter contract allows.
    """
    fields = value.split()
    return fields[0].strip("'\"") if fields else ""


def repo_tokens(lines: list[str]) -> list[str]:
    """Every frontmatter `repo:` identifier, trailing prose dropped."""
    start, end = frontmatter_span(lines)
    return [
        repo_token(match.group(1))
        for line in lines[start - 1 : end - 1]
        if (match := REPO_KEY_RE.match(line))
    ]


def frontmatter_repo(lines: list[str]) -> tuple[str, str] | None:
    """`{owner}/{repo}` implied by the `repo:` key, per PR Reference Resolution."""
    values = repo_tokens(lines)
    if len(values) != 1:
        return None
    value = values[0]
    if not value or value.lower() == "multiple":
        return None
    match = REPO_FULL_NAME_RE.fullmatch(value)
    return (match.group(1), match.group(2)) if match else None


def markdown_label_ranges(line: str) -> list[tuple[int, int]]:
    """Spans of the label in `[label](pr-url)`, where a `#{n}` is never its own citation."""
    return [match.span(1) for match in MARKDOWN_PR_LINK_RE.finditer(line)]


def qualified_pr_matches(line: str) -> list[re.Match[str]]:
    """`{owner}/{repo}#{n}` citations on one line, minus link labels and URL path segments."""
    label_ranges = markdown_label_ranges(line)
    return [
        match
        for match in QUALIFIED_PR_RE.finditer(line)
        if not any(start <= match.start() < end for start, end in label_ranges)
        and match.group(2).lower() not in {"pull", "issues"}
    ]


def explicit_pr_references(text: str) -> list[tuple[int, int, str, str]]:
    """Every fully qualified PR reference as `(line, column, owner, repo)`."""
    found: list[tuple[int, int, str, str]] = []
    for line_number, line in enumerate(text.splitlines(), 1):
        full_spans: list[tuple[int, int]] = []
        for match in FULL_PR_RE.finditer(line):
            found.append((line_number, match.start(), match.group(1), match.group(2)))
            full_spans.append(match.span())
        if BARE_PR_DENIAL_RE.search(deemphasize(line)):
            continue
        for match in qualified_pr_matches(line):
            if any(start <= match.start() < end for start, end in full_spans):
                continue
            found.append((line_number, match.start(), match.group(1), match.group(2)))
    return found


def collect_pr_references(
    line_number: int,
    line: str,
    source: str,
    allow_bare: bool,
    explicit: list[tuple[int, int, str, str]],
    fallback_repo: tuple[str, str] | None,
    discarded: list[dict[str, object]],
) -> list[dict[str, object]]:
    """Resolve one line's PR references per `PR Reference Resolution`.

    Bare `#{n}` resolves only where a number is definitionally a PR, and only to a
    repo we can actually name: an unresolvable guess would read UNREADABLE and stall
    the effort, which is worse than reporting the reference as discarded.
    """
    denied = bool(BARE_PR_DENIAL_RE.search(deemphasize(line)))
    refs: list[dict[str, object]] = []
    label_ranges = markdown_label_ranges(line)
    for owner, repo, number in FULL_PR_RE.findall(line):
        refs.append(
            {
                "owner": owner,
                "repo": repo,
                "number": int(number),
                "source": source,
                "line": line_number,
            }
        )
    for match in qualified_pr_matches(line):
        owner, repo, number = match.groups()
        # A row disclaiming its own numbers usually cites the wrong resolution as the
        # counter-example ("resolve `#5` to the unrelated CLOSED `owner/repo#5`"), so
        # shorthand here is the mistake being described, not delivery evidence. A full
        # URL survives: nobody writes one by accident while denying it.
        if denied:
            discarded.append(
                {"number": int(number), "line": line_number, "reason": "denied-in-row"}
            )
            continue
        refs.append(
            {
                "owner": owner,
                "repo": repo,
                "number": int(number),
                "source": source,
                "line": line_number,
            }
        )
    remainder = QUALIFIED_PR_RE.sub(
        lambda match: " " * len(match.group(0)),
        FULL_PR_RE.sub(lambda match: " " * len(match.group(0)), line),
    )
    markdown_label_starts = {
        start + match.start()
        for start, end in label_ranges
        for match in BARE_PR_RE.finditer(line[start:end])
    }
    bare_matches = [
        match
        for match in BARE_PR_RE.finditer(remainder)
        if match.start() not in markdown_label_starts
    ]
    if not bare_matches:
        return refs
    if not allow_bare:
        # A canonical `PR opened` row can sit outside any `## Lifecycle` section, and
        # then `#{n}` is no longer definitionally a PR. Dropping it is right; dropping
        # it silently is not - the effort would read `no-delivery-pr` forever with
        # nothing naming the row that holds the number.
        discarded.extend(
            {
                "number": int(match.group(1)),
                "line": line_number,
                "reason": "outside-lifecycle",
            }
            for match in bare_matches
        )
        return refs
    if denied:
        discarded.extend(
            {
                "number": int(match.group(1)),
                "line": line_number,
                "reason": "denied-in-row",
            }
            for match in bare_matches
        )
        return refs
    for match in bare_matches:
        number = int(match.group(1))
        nearest = min(
            explicit,
            key=lambda entry: (
                abs(entry[0] - line_number),
                abs(entry[1] - match.start()) if entry[0] == line_number else 0,
                entry[1] > match.start()
                if entry[0] == line_number
                else entry[0] > line_number,
                entry[0],
                entry[1],
            ),
            default=None,
        )
        repo_context = (nearest[2], nearest[3]) if nearest else fallback_repo
        if repo_context is None:
            discarded.append(
                {"number": number, "line": line_number, "reason": "no-repo-context"}
            )
            continue
        refs.append(
            {
                "owner": repo_context[0],
                "repo": repo_context[1],
                "number": number,
                "source": source,
                "line": line_number,
            }
        )
    return refs


def dedupe_references(refs: list[dict[str, object]]) -> list[dict[str, object]]:
    """Collapse the three citation forms onto one entry per `{owner}/{repo}#{n}`."""
    seen: dict[tuple[object, object, object], dict[str, object]] = {}
    cited: dict[tuple[object, object, object], set[int]] = {}
    for ref in refs:
        key = (str(ref["owner"]).casefold(), str(ref["repo"]).casefold(), ref["number"])
        if key not in seen:
            seen[key] = ref
        cited.setdefault(key, set()).add(int(str(ref["line"])))
    for key, ref in seen.items():
        ref["cited_lines"] = sorted(cited[key])
    return sorted(
        seen.values(),
        key=lambda ref: (
            str(ref["owner"]).casefold(),
            str(ref["repo"]).casefold(),
            int(str(ref["number"])),
        ),
    )


def pr_references(text: str) -> dict[str, object]:
    """Delivery and dependency PR sets for one effort doc.

    Single source for `/nase:today` and `/nase:efforts`: a caller re-deriving these from
    the prose rules turns a `#5` that means "query 5" into a phantom PR.
    """
    lines = text.splitlines()
    explicit = explicit_pr_references(text)
    fallback_repo = frontmatter_repo(lines)
    fm_start, fm_end = frontmatter_span(lines)
    lifecycle_ranges = lifecycle_line_ranges(lines)
    discarded: list[dict[str, object]] = []
    delivery: list[dict[str, object]] = []
    dependency: list[dict[str, object]] = []
    validation_errors: list[str] = []
    list_entries: set[str] = set()
    key_counts: dict[str, int] = {}
    inline_values: set[str] = set()
    for line in lines[fm_start - 1 : fm_end - 1]:
        delivery_match = DELIVERY_PR_KEY_RE.match(line)
        if delivery_match:
            key = delivery_match.group(1).lower()
        elif BLOCKED_BY_KEY_RE.match(line):
            key = "blocked-by"
        elif REPO_KEY_RE.match(line):
            key = "repo"
        else:
            continue
        key_counts[key] = key_counts.get(key, 0) + 1
        if line.split(":", 1)[1].strip():
            inline_values.add(key)
    for key, count in key_counts.items():
        if count > 1:
            validation_errors.append(f"invalid-{key}")
    repo_values = repo_tokens(lines)
    if (
        len(repo_values) == 1
        and "/" in repo_values[0]
        and not REPO_FULL_NAME_RE.fullmatch(repo_values[0])
    ):
        validation_errors.append("invalid-repo")

    def frontmatter_refs(line_number: int, line: str) -> list[dict[str, object]]:
        return collect_pr_references(
            line_number, line, "frontmatter", True, explicit, fallback_repo, discarded
        )

    active_key: str | None = None
    for line_number in range(fm_start, fm_end):
        line = lines[line_number - 1]
        delivery_key = DELIVERY_PR_KEY_RE.match(line)
        blocked_key = BLOCKED_BY_KEY_RE.match(line)
        if delivery_key:
            key = delivery_key.group(1).lower()
            if key_counts.get(key) != 1:
                active_key = None
                continue
            if key == "prs":
                if line.split(":", 1)[1].strip():
                    validation_errors.append("invalid-prs")
                    active_key = None
                else:
                    active_key = "delivery"
                continue
            line_refs = frontmatter_refs(line_number, line)
            if len(dedupe_references(line_refs)) == 1:
                delivery.extend(line_refs)
            else:
                validation_errors.append(f"unresolved-{key}")
            active_key = None
            continue
        if blocked_key:
            if key_counts.get("blocked-by") != 1:
                active_key = None
                continue
            dependency.extend(frontmatter_refs(line_number, line))
            active_key = "dependency" if not line.split(":", 1)[1].strip() else None
            continue
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not FRONTMATTER_LIST_ITEM_RE.match(line):
            active_key = None
        if active_key is None:
            continue
        bucket = delivery if active_key == "delivery" else dependency
        list_entries.add(active_key)
        line_refs = frontmatter_refs(line_number, line)
        if not line_refs and active_key == "delivery":
            validation_errors.append("unresolved-prs")
            continue
        bucket.extend(line_refs)

    # A key with an empty value promises a block list, so no list items is malformed. A
    # key carrying its value inline is a scalar and was already resolved above - only
    # `prs` rejects that shape, and `blocked-by` accepts a scalar per the frontmatter
    # contract, including short free text that has no PR to resolve at all.
    if (
        key_counts.get("prs") == 1
        and "prs" not in inline_values
        and "delivery" not in list_entries
    ):
        validation_errors.append("invalid-prs")
    if (
        key_counts.get("blocked-by") == 1
        and "blocked-by" not in inline_values
        and "dependency" not in list_entries
    ):
        validation_errors.append("invalid-blocked-by")

    for line_number, line in enumerate(lines, 1):
        match = CHECKBOX_RE.match(line)
        if not match or match.group(1).lower() != "x":
            continue
        if canonical_label(match.group(2)) != "PR opened":
            continue
        in_lifecycle = any(
            start <= line_number < end for start, end in lifecycle_ranges
        )
        delivery.extend(
            collect_pr_references(
                line_number,
                line,
                "lifecycle:PR opened",
                in_lifecycle,
                explicit,
                fallback_repo,
                discarded,
            )
        )

    # The same PR often appears on one row as both a URL and a shorthand or bare
    # number. Only the forms we actually dropped belong in the report - listing a
    # number we kept anyway would send a reader to fix a row that is already correct.
    kept = {(ref["line"], ref["number"]) for ref in delivery + dependency}
    surviving: dict[tuple[object, object], dict[str, object]] = {}
    for entry in discarded:
        key = (entry["line"], entry["number"])
        if key in kept or key in surviving:
            continue
        surviving[key] = entry
    return {
        "delivery": dedupe_references(delivery),
        "dependency": dedupe_references(dependency),
        "discarded_bare": [surviving[key] for key in sorted(surviving)],  # type: ignore[arg-type]
        "validation_errors": sorted(set(validation_errors)),
    }


def classify(text: str) -> Classification:
    status = frontmatter_status(text)
    tracking_only, tracking_only_valid = tracking_only_state(text)
    checked: set[str] = set()
    evidence: list[dict[str, object]] = []
    undelivered: list[dict[str, object]] = []
    pending_postdeploy_validation: list[dict[str, object]] = []
    stale_merged_candidates: list[dict[str, object]] = []
    pending_followups = 0

    lines = text.splitlines()
    lifecycle_ranges = lifecycle_line_ranges(lines)
    target_pr_counts = [
        {"count": int(match.group(1)), "line": line_number, "text": line.strip()}
        for line_number, line in enumerate(lines, 1)
        if (match := TARGET_PR_COUNT_RE.search(line))
    ]

    for line_number, line in enumerate(lines, 1):
        match = CHECKBOX_RE.match(line)
        if not match:
            continue
        is_checked = match.group(1).lower() == "x"
        label = match.group(2).strip()
        canonical = canonical_label(label)
        if canonical and is_checked:
            checked.add(canonical)
            evidence.append({"label": canonical, "line": line_number, "text": label})
            if canonical in {"PR opened", "Merged"} and OUTSTANDING_CLAUSE_RE.search(
                label
            ):
                undelivered.append({"line": line_number, "text": label})
        if not is_checked and label.lower().startswith("follow-up:"):
            pending_followups += 1
        in_lifecycle = any(
            start <= line_number < end for start, end in lifecycle_ranges
        )
        if (
            not is_checked
            and in_lifecycle
            and not label.lower().startswith("follow-up:")
        ):
            plain_label = strip_emphasis(label)
            if canonical_label(plain_label) == "Merged":
                if OUTSTANDING_CLAUSE_RE.search(label) or PARTIAL_MERGED_RE.search(
                    label
                ):
                    undelivered.append({"line": line_number, "text": label})
                else:
                    stale_merged_candidates.append(
                        {
                            "label": "Merged",
                            "line": line_number,
                            "text": label,
                            "bare_label": plain_label.lower() == "merged",
                        }
                    )
            elif POST_DEPLOY_LIFECYCLE_RE.search(plain_label):
                pending_postdeploy_validation.append(
                    {"line": line_number, "text": label}
                )
            # An unchecked, non-benign row inside `## Lifecycle` is the author
            # saying "there is still a deliverable owed here". Later PRs in a
            # multi-PR plan have no delivery-PR entry to be seen by, so this row
            # is the only signal that the effort is not actually deployable yet.
            elif not BENIGN_LIFECYCLE_RE.search(plain_label):
                undelivered.append({"line": line_number, "text": label})

    # A `Merged` row nobody ticked is drift, not owed work (`BENIGN_LIFECYCLE_RE`), and
    # the drift is self-perpetuating: the row keeps `stage` at `in_review` while
    # frontmatter reads `awaiting-deploy`, so `needs_live_verification` stays true and
    # every later run re-reads the same PRs to re-report the same conflict.
    #
    # Only an unambiguous row is offered for ticking. A doc with a checked `Merged`
    # row already, or with several unchecked ones, is a multi-PR ledger where each row
    # stands for a different PR - ticking one there would assert a merge that the
    # delivery-PR states do not single out.
    unticked_canonical_rows: list[dict[str, object]] = []
    if "Merged" not in checked and len(stale_merged_candidates) == 1:
        unticked_canonical_rows = stale_merged_candidates

    if "Deployed" in checked and pending_followups:
        stage = "follow_up_only"
    elif "Merged" in checked:
        stage = "awaiting_deploy"
    elif "PR opened" in checked:
        stage = "in_review"
    elif "Implementation started" in checked:
        stage = "implementing"
    else:
        stage = stage_from_status(status, text)

    method = "lifecycle" if evidence else "frontmatter"
    status_stage = stage_from_status(status, text) if status else None
    compatible_statuses = {"follow_up_only": {"awaiting_deploy", "follow_up_only"}}
    expected_stages = compatible_statuses.get(stage, {stage})
    needs_live_verification = bool(
        evidence and status_stage is not None and status_stage not in expected_stages
    )

    return {
        "stage": stage,
        "display_stage": STAGE_DISPLAY[stage],
        "method": method,
        "status": status or None,
        "evidence": evidence,
        "pending_followups": pending_followups,
        "needs_live_verification": needs_live_verification,
        "undelivered": undelivered,
        "pending_postdeploy_validation": pending_postdeploy_validation,
        "unticked_canonical_rows": unticked_canonical_rows,
        "pr_references": pr_references(text),
        "structure": document_structure(text, lines),
        "target_pr_counts": target_pr_counts,
        "tracking_only": tracking_only,
        "tracking_only_valid": tracking_only_valid,
    }


def terminal_destination_dir(classification: Classification, archive_year: int) -> str:
    """Directory a terminal transition files the effort into.

    `done/` is the record of what this workspace delivered, so a `tracking_only`
    effort someone else shipped goes straight to the yearly archive instead of
    padding that record. `/nase:effort-rollup` reads `done/` and would otherwise
    count another owner's delivery as ours.
    """
    if classification.get("tracking_only"):
        return f"workspace/efforts/archive/{archive_year}"
    return "workspace/efforts/done"


def transition(
    classification: Classification,
    delivery_pr_states: list[str],
    jira_state: str,
    blocked_by_unresolved: bool,
    archive_year: int | None = None,
) -> dict[str, object]:
    destination_dir = terminal_destination_dir(
        classification,
        archive_year if archive_year is not None else local_today().year,
    )
    if classification["pr_references"].get("validation_errors"):
        return {"action": "none", "status": None, "reason": "invalid-pr-reference"}
    if not delivery_pr_states:
        return {"action": "none", "status": None, "reason": "no-delivery-pr"}
    if "UNREADABLE" in delivery_pr_states:
        return {"action": "none", "status": None, "reason": "unreadable-delivery-pr"}
    if jira_state == "unreadable":
        return {"action": "none", "status": None, "reason": "unreadable-jira"}
    if blocked_by_unresolved:
        return {"action": "none", "status": None, "reason": "unresolved-blocker"}
    if "OPEN" in delivery_pr_states:
        return {"action": "none", "status": None, "reason": "open-delivery-pr"}
    if classification.get("tracking_only_valid") is False:
        return {"action": "none", "status": None, "reason": "invalid-tracking-only"}
    # A multi-PR effort whose first PR merged is not deployable: the PRs nobody has
    # opened yet cannot appear in delivery_pr_states, so the states alone read as
    # "everything shipped" and would archive live work. This sits ahead of both
    # terminal paths on purpose — a plan whose first PR was *closed* is no more
    # `wontfix` than one whose first PR merged is `awaiting-deploy`. Name the rows
    # that held it, so a stale row gets fixed instead of silently suppressing every
    # future transition.
    undelivered = list(classification.get("undelivered") or [])
    target_pr_counts = classification.get("target_pr_counts") or []
    expected_pr_count = max(
        (entry["count"] for entry in target_pr_counts),
        default=0,
    )
    if expected_pr_count > len(delivery_pr_states):
        undelivered.extend(
            {"line": entry["line"], "text": entry["text"]}
            for entry in target_pr_counts
            if entry["count"] == expected_pr_count
        )
    if undelivered:
        return {
            "action": "none",
            "status": None,
            "reason": "undelivered-lifecycle-rows",
            "undelivered": undelivered,
        }
    if "MERGED" in delivery_pr_states:
        if jira_state == "not-done":
            return {"action": "none", "status": None, "reason": "jira-not-done"}
        # A merged delivery PR authorizes the lifecycle status write, so an unticked
        # `Merged` row is stale against the same evidence. Absent rather than empty
        # elsewhere: callers compare the whole transition dict.
        rows = classification.get("unticked_canonical_rows") or []
        stale = {"stale_canonical_rows": rows} if rows else {}
        deployed = any(
            evidence["label"] == "Deployed" for evidence in classification["evidence"]
        )
        if deployed and classification["pending_postdeploy_validation"]:
            if classification["status"] == "awaiting-deploy":
                return {
                    "action": "none",
                    "status": None,
                    "reason": "pending-postdeploy-validation",
                    **stale,
                }
            return {
                "action": "update",
                "status": "awaiting-deploy",
                "reason": "pending-postdeploy-validation",
                **stale,
            }
        if deployed and classification["pending_followups"] == 0:
            return {
                "action": "move",
                "status": "completed",
                "reason": "deployed",
                "destination_dir": destination_dir,
                **stale,
            }
        if classification["status"] == "awaiting-deploy":
            return {
                "action": "none",
                "status": None,
                "reason": "already-awaiting-deploy",
                **stale,
            }
        return {
            "action": "update",
            "status": "awaiting-deploy",
            "reason": "merged-awaiting-deploy",
            **stale,
        }
    return {
        "action": "move",
        "status": "wontfix",
        "reason": "all-delivery-prs-closed",
        "destination_dir": destination_dir,
    }


def shell_tokens(command: str) -> list[str] | None:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ""
    try:
        return list(lexer)
    except ValueError:
        return None


def gh_api_methods(args: list[str]) -> list[str]:
    """Every HTTP method a `gh api` call names, in every spelling gh accepts."""
    methods: list[str] = []
    index = 0
    while index < len(args):
        token = args[index]
        if token in {"-X", "--method"}:
            methods.append(args[index + 1] if index + 1 < len(args) else "")
            index += 2
            continue
        if token.startswith("--method="):
            methods.append(token.partition("=")[2])
        elif token.startswith("-X") and not token.startswith("--"):
            methods.append(token[2:])
        index += 1
    return methods


def gh_api_is_read_only(args: list[str]) -> bool:
    # A token starting with `$` is a bare expansion whose value the classifier
    # cannot see: it could expand into a method flag (`-X POST`) or a different
    # endpoint, so `gh api $X` must never certify as a read. Tokens with `$`
    # embedded after literal text (e.g. `repos/$OWNER/$REPO`) keep their
    # literal anchors and stay allowed.
    if any(t.startswith("$") for t in args):
        return False
    if any(GH_BUNDLED_SHORT_RE.match(t) for t in args):
        return False
    flags = {t.partition("=")[0] if t.startswith("--") else t[:2] for t in args}
    if "--input" in flags or any(GH_METHOD_OVERRIDE_RE.search(t) for t in args):
        return False
    endpoints = [t for t in args if not t.startswith("-")]
    if any(t.rstrip("/").rpartition("/")[2].lower() == "graphql" for t in endpoints):
        return False
    methods = gh_api_methods(args)
    if methods:
        return len(methods) == 1 and methods[0].upper() == "GET"
    return not flags & GH_FIELD_FLAGS


def gh_is_read_only(args: list[str]) -> bool:
    # Same bare-expansion rule as `gh_api_is_read_only`: a token starting
    # with `$` (e.g. `gh pr view $N`) could expand into `--web` or another
    # write-shaped argument the classifier cannot see.
    if any(t.startswith("$") for t in args):
        return False
    if args[:1] == ["api"]:
        return gh_api_is_read_only(args[1:])
    if len(args) > 1 and args[0] in {"pr", "run", "release"}:
        return args[1] in {"view", "list", "checks"} and not (
            {"-w", "--web", "--watch"} & set(args)
        )
    return False


def az_is_read_only(args: list[str]) -> bool:
    words: list[str] = []
    for token in args:
        if token.startswith("-"):
            break
        words.append(token)
    return tuple(words) in AZ_READ_ONLY_VERBS


def git_flags_allowed(subcommand: str, args: list[str]) -> bool:
    """Every flag must be on the subcommand's positive list; an unknown flag refuses."""
    spec = GIT_FLAG_SPECS[subcommand]
    index = 0
    while index < len(args):
        arg = args[index]
        index += 1
        if arg == "--":
            return True
        if not arg.startswith("-") or arg == "-":
            continue
        if arg.startswith("--"):
            name, has_value, _ = arg.partition("=")
            if name in spec.long_value:
                index += 0 if has_value else 1
            elif name not in spec.long:
                return False
            continue
        if spec.digits and arg[1:].isdigit():
            continue
        for position, char in enumerate(arg[1:], 1):
            if char in spec.short_value:
                index += 1 if position == len(arg) - 1 else 0
                break
            if char not in spec.short:
                return False
    return True


def git_is_read_only(args: list[str]) -> bool:
    rest = list(args)
    while rest[:1] == ["--no-pager"] or (rest[:1] == ["-C"] and len(rest) > 1):
        rest = rest[1:] if rest[0] == "--no-pager" else rest[2:]
    return (
        bool(rest)
        and rest[0] in GIT_FLAG_SPECS
        and git_flags_allowed(rest[0], rest[1:])
    )


def is_read_only_command(command: str) -> bool:
    """Whether one command is clearly a read, by the allowlist in `effort-drift.md`.

    Anything the lexer cannot parse, any operator outside quotes, and any command
    substitution is refused, so only a single plain invocation can pass.
    """
    if "$(" in command or "`" in command:
        return False
    if any(char < " " or char == "\x7f" for char in command):
        return False
    if ENV_ASSIGNMENT_RE.match(command):
        return False
    tokens = shell_tokens(command)
    if not tokens or any(set(token) <= SHELL_PUNCTUATION for token in tokens):
        return False
    checks = {"gh": gh_is_read_only, "az": az_is_read_only, "git": git_is_read_only}
    check = checks.get(tokens[0])
    return bool(check and check(tokens[1:]))


def without_env_assignments(command: str) -> str:
    while match := ENV_ASSIGNMENT_RE.match(command):
        command = command[match.end() :]
    return command


def command_candidates(label: str) -> list[str]:
    commands: list[str] = []
    for span in BACKTICK_SPAN_RE.findall(label):
        words = without_env_assignments(span.strip()).split()
        if words and words[0] in COMMAND_WORDS:
            commands.append(span.strip())
    return commands


def validation_expectation(label: str) -> str | None:
    """The backtick span after `expect`/`expects`/`expected`, when the row states one."""
    match = EXPECT_RE.search(label)
    return match.group(1).strip() if match else None


def is_heavy_command(command: str) -> bool:
    return bool(HEAVY_COMMAND_RE.match(without_env_assignments(command)))


def classify_validation_row(label: str) -> tuple[str, str | None]:
    """`none` (no command), `heavy`, `run` (clearly read-only) or `not-readonly`."""
    commands = command_candidates(label)
    if not commands:
        return "none", None
    if any(is_heavy_command(command) for command in commands):
        return "heavy", commands[0]
    if any(ENV_ASSIGNMENT_RE.match(command) for command in commands):
        return "not-readonly", commands[0]
    if len(commands) == 1 and is_read_only_command(commands[0]):
        return "run", commands[0]
    return "not-readonly", commands[0]


def is_non_deployed_path(path: str) -> bool:
    return not any(p.search(path) for p in NON_DEPLOYED_DENY_PATTERNS) and any(
        p.search(path) for p in NON_DEPLOYED_PATH_PATTERNS
    )


def table_cells(line: str) -> list[str] | None:
    stripped = line.strip()
    if not stripped.startswith("|"):
        return None
    return [cell.strip() for cell in stripped.strip("|").split("|")]


def clean_cell(cell: str) -> str:
    return re.sub(r"[*_`]", "", cell).strip().lower().rstrip(".")


class PlanRow(NamedTuple):
    id: str
    depends: list[str]
    depends_parsed: bool
    no_blockers: bool


def parse_pr_plan(lines: list[str]) -> list[PlanRow] | None:
    """Rows of the `### PR Plan` table from `pr-plan-readiness.md`, or None.

    A legacy prose plan carries no readiness columns, so it yields None and nothing
    downstream treats it as advanceable.
    """
    for index, line in enumerate(lines):
        header = [clean_cell(cell) for cell in table_cells(line) or []]
        if not {"pr", "depends on", "external blockers"} <= set(header):
            continue
        columns = {
            name: header.index(name)
            for name in ("pr", "depends on", "external blockers")
        }
        rows: list[PlanRow] = []
        for offset in range(index + 1, len(lines)):
            cells = table_cells(lines[offset])
            if cells is None:
                break
            if all(SEPARATOR_CELL_RE.match(cell) for cell in cells):
                continue
            if len(cells) <= max(columns.values()):
                continue
            own = PLAN_ID_RE.search(cells[columns["pr"]])
            if not own:
                continue
            depends = cells[columns["depends on"]]
            rows.append(
                PlanRow(
                    id=f"PR{own.group(1).upper()}",
                    depends=[f"PR{m.upper()}" for m in PLAN_ID_RE.findall(depends)],
                    depends_parsed=clean_cell(depends) == "none"
                    or bool(PLAN_ID_RE.search(depends)),
                    no_blockers=clean_cell(cells[columns["external blockers"]])
                    == "none",
                )
            )
        return rows
    return None


def _action(
    kind: str,
    reason: str,
    command: str | None = None,
    evidence: list[str] | None = None,
    context: str = "",
    **extra: object,
) -> Action:
    return {
        "kind": kind,
        "reason": reason,
        "command": command,
        "evidence": evidence or [],
        "context": context[:240],
        **extra,
    }


def pr_key(ref: PrRef) -> str:
    return f"{ref['owner']}/{ref['repo']}#{ref['number']}"


def plan_attribution(refs: list[PrRef], lines: list[str]) -> dict[str, PrRef] | None:
    """Map plan row id to the delivery PR that opened it, or None when any PR is ambiguous.

    A PR is attributed by every line that cites it, so a bare `prs:` frontmatter entry
    does not hide the plan id on its `PR opened` row. Exactly one distinct id on those
    lines, and no cited line shared with another PR, means attributed.
    """
    cited = {
        pr_key(ref): [int(n) for n in ref.get("cited_lines") or [ref["line"]]]
        for ref in refs
    }
    per_line: dict[int, int] = {}
    for numbers in cited.values():
        for number in numbers:
            per_line[number] = per_line.get(number, 0) + 1
    opened: dict[str, PrRef] = {}
    for ref in refs:
        numbers = cited[pr_key(ref)]
        ids = {
            f"PR{m.upper()}"
            for number in numbers
            for m in PLAN_ID_RE.findall(
                lines[number - 1] if 0 < number <= len(lines) else ""
            )
        }
        if len(ids) != 1 or any(per_line[number] != 1 for number in numbers):
            return None
        opened[ids.pop()] = ref
    return opened


def pending_plan_rows(
    plan: list[PlanRow] | None,
    opened: dict[str, PrRef] | None,
    live_of: Callable[[PrRef], LiveRecord],
) -> str:
    """Why a parsed PR Plan still owes a PR, or an empty string when every row merged."""
    if plan is None:
        return ""
    if opened is None:
        return "a delivery PR names no single plan row"
    owed = [
        row.id
        for row in plan
        if row.id not in opened or live_of(opened[row.id]).get("state") != "MERGED"
    ]
    return f"PR Plan rows without a merged PR: {', '.join(owed)}" if owed else ""


def advance_action(
    classification: Classification,
    live_of: Callable[[PrRef], LiveRecord],
    slug: str,
    blocked: bool,
    plan: list[PlanRow] | None,
    opened: dict[str, PrRef] | None,
) -> Action:
    """Propose the next `/nase:fsd` or `/nase:prep-merge` run; never run it."""
    refs = classification["pr_references"]["delivery"]
    status = classification["status"] or ""
    if blocked or status == "blocked":
        return _action("none", "blocked")
    if status == "merge-ready":
        urls = [
            f"https://github.com/{r['owner']}/{r['repo']}/pull/{r['number']}"
            for r in refs
            if live_of(r).get("state") == "OPEN"
        ]
        if urls:
            return _action(
                "advance",
                "merge-ready-open-pr",
                f"/nase:prep-merge {urls[0]}",
                urls,
                f"{len(urls)} open delivery PR(s), status merge-ready",
            )
    if plan is None:
        if status == "planned" and not refs:
            return _action(
                "advance",
                "planned-unblocked",
                f"/nase:fsd {slug}",
                [],
                "planned, no PR, unblocked",
            )
        return _action("none", "no-plan-table")
    if opened is None:
        return _action(
            "none",
            "plan-prs-unattributed",
            context="a delivery PR names no single plan row",
        )
    startable = [
        row
        for row in plan
        if row.id not in opened
        and row.no_blockers
        and row.depends_parsed
        and all(
            dep in opened and live_of(opened[dep]).get("state") == "MERGED"
            for dep in row.depends
        )
    ]
    if not startable:
        return _action("none", "no-startable-pr")
    ids = [row.id for row in startable]
    return _action(
        "advance",
        "plan-row-startable",
        f"/nase:fsd {slug} {ids[0]}",
        [f"{i}: dependencies merged, no external blockers, not opened" for i in ids],
        f"{len(ids)} PR(s) startable: {', '.join(ids)}",
    )


def jira_is_tracked(text: str) -> bool:
    raw = extract_frontmatter_scalar(text, "jira")[0]
    return raw is not None and normalize_scalar(raw) not in JIRA_ABSENT_VALUES


def close_gate(
    classification: Classification,
    lines: list[str],
    live_of: Callable[[PrRef], LiveRecord],
    jira_state: str,
    jira_unsettled: bool,
    blocked: bool,
    validation_rows: list[tuple[str, str | None]],
    validation_section_heavy: list[str],
    plan: list[PlanRow] | None,
    opened: dict[str, PrRef] | None,
) -> tuple[list[tuple[str, str, bool]], Action | None, list[str]]:
    """Every reason an awaiting-deploy effort cannot auto-close, in precedence order.

    Each failure is `(reason, context, blocks_close)`. A non-blocking failure only
    explains a later ask. Returns the close edit and its evidence when nothing blocks.
    A tracked Jira issue with no live state is unresolved, never read as untracked.
    """
    refs: list[PrRef] = classification["pr_references"]["delivery"]
    failures: list[tuple[str, str, bool]] = []
    states = [
        s
        if (s := live_of(r).get("state")) in {"OPEN", "MERGED", "CLOSED"}
        else "UNREADABLE"
        for r in refs
    ]
    causes = [
        cause
        for cause, hit in (
            (
                "invalid PR reference",
                classification["pr_references"]["validation_errors"],
            ),
            ("no delivery PR", not refs),
            ("delivery PR state unread", "UNREADABLE" in states),
            ("Jira state unreadable", jira_state == "unreadable"),
            ("tracked Jira issue has no live state", jira_unsettled),
            ("unresolved blocker", blocked),
            ("invalid tracking_only", classification["tracking_only_valid"] is False),
        )
        if hit
    ]
    unresolved = bool(causes)
    if unresolved:
        failures.append(("delivery-state-unresolved", "; ".join(causes), True))
    else:
        unmerged = [
            pr_key(r) for r, s in zip(refs, states, strict=True) if s != "MERGED"
        ]
        if unmerged:
            failures.append(
                ("delivery-pr-not-merged", f"not merged: {', '.join(unmerged)}", True)
            )
        elif (
            transition(classification, states, jira_state, blocked)["reason"]
            == "undelivered-lifecycle-rows"
        ):
            rows = classification["undelivered"]
            first = rows[0]["text"] if rows else "target PR count"
            failures.append(
                (
                    "undelivered-row-stale",
                    f"{len(rows) or 1} undelivered row(s), first: {first}",
                    True,
                )
            )
        elif pending := pending_plan_rows(plan, opened, live_of):
            failures.append(("plan-rows-pending", pending, True))
    if jira_state == "not-done":
        failures.append(("jira-not-done", "tracked Jira issue is not Done", True))
    if classification["pending_followups"]:
        failures.append(
            (
                "pending-followups",
                f"{classification['pending_followups']} Follow-up row(s) open",
                True,
            )
        )
    kinds = [kind for kind, _ in validation_rows]
    commands = [cmd for _, cmd in validation_rows if cmd]
    if "heavy" in kinds:
        failures.append(
            (
                "validation-heavy-not-run",
                f"post-deploy row needs a heavy suite: {commands[0]}",
                True,
            )
        )
    if "not-readonly" in kinds:
        failures.append(
            (
                "validation-not-readonly",
                "post-deploy row command is not clearly read-only",
                True,
            )
        )
    if "none" in kinds:
        failures.append(
            ("deployed-needs-ring-evidence", "post-deploy row has no command", True)
        )
    if "run" in kinds:
        failures.append(
            (
                "deployed-needs-ring-evidence",
                "post-deploy checks wait for a ticked Deployed row",
                True,
            )
        )
    evidence: list[str] = []
    if not unresolved and not any(
        r == "delivery-pr-not-merged" for r, _, _ in failures
    ):
        outside: list[str] = []
        for ref in refs:
            info = live_of(ref)
            files = info.get("files")
            if (
                not isinstance(files, list)
                or not files
                or not all(isinstance(f, str) for f in files)
                or info.get("files_truncated")
            ):
                failures.append(
                    (
                        "files-unverified",
                        f"{pr_key(ref)} changed files unread, empty or truncated",
                        True,
                    )
                )
                continue
            outside += [f for f in files if not is_non_deployed_path(f)]
            checks = info.get("merge_checks")
            if checks == "failure":
                failures.append(
                    (
                        "merge-checks-failing",
                        f"{pr_key(ref)} merge commit checks failed",
                        True,
                    )
                )
            elif checks != "success":
                failures.append(
                    (
                        "merge-checks-unknown",
                        f"{pr_key(ref)} merge checks {checks or 'unread'}",
                        True,
                    )
                )
            else:
                evidence.append(
                    f"{pr_key(ref)} merge checks success, {len(files)} files"
                )
        if outside:
            failures.append(
                (
                    "files-outside-tests-ci-docs",
                    f"{len(outside)} file(s) outside tests/CI/docs, e.g. {outside[0]}",
                    True,
                )
            )
    deployed_rows = [
        (number, line)
        for start, end in lifecycle_line_ranges(lines)
        for number, line in enumerate(lines[start - 1 : end - 1], start)
        if (m := CHECKBOX_RE.match(line))
        and m.group(1) == " "
        and canonical_label(strip_emphasis(m.group(2))) == "Deployed"
    ]
    edit: Action | None = None
    if len(deployed_rows) != 1:
        if not any(e["label"] == "Deployed" for e in classification["evidence"]):
            failures.append(
                (
                    "deployed-needs-ring-evidence",
                    f"{len(deployed_rows)} unchecked Deployed rows",
                    True,
                )
            )
    else:
        number, line = deployed_rows[0]
        row = CHECKBOX_RE.match(line)
        label = row.group(2) if row else ""
        if not BARE_DEPLOYED_ROW_RE.match(strip_emphasis(label)):
            failures.append(
                (
                    "deployed-needs-ring-evidence",
                    f"L{number} Deployed row carries prose; read it in full",
                    True,
                )
            )
        elif evidence:
            edit = {
                "line": number,
                "old": line,
                "new": f"{line[: line.index('[')]}[x] Deployed - n/a, tests/CI/docs only ({'; '.join(evidence)})",
            }
    if validation_section_heavy:
        failures.append(
            (
                "validation-heavy-not-run",
                f"Validation section suites not run: {validation_section_heavy[0]}",
                False,
            )
        )
    return failures, edit, evidence


def ask_reason(failures: list[tuple[str, str, bool]]) -> tuple[str, str]:
    """Pick the reason an ask leads with.

    A heavy suite the effort owes outranks the file-evidence reasons, because running it
    is the user's next step. Every other reason keeps its precedence order.
    """
    if not failures:
        return "deployed-needs-ring-evidence", ""
    leading = [f for f in failures if f[0] not in FILE_EVIDENCE_REASONS]
    reason, context, _ = (leading or failures)[0]
    return reason, context


def merge_live_records(live: dict[str, LiveRecord]) -> dict[str, LiveRecord]:
    """Index sweep records by casefolded key; keys that differ only in case merge.

    The record carrying `files` or `merge_checks` wins a field on collision, so a bare
    duplicate cannot hide the evidence the close gate reads.
    """
    index: dict[str, LiveRecord] = {}
    for key in sorted(live):
        folded = key.casefold()
        record = live[key]
        prior = index.get(folded)
        if prior is None:
            index[folded] = record
            continue
        rich, plain = (
            (record, prior)
            if "files" in record or "merge_checks" in record
            else (prior, record)
        )
        index[folded] = {**plain, **rich}
    return index


def next_action(
    classification: Classification,
    text: str,
    live: dict[str, LiveRecord],
    jira_state: str,
    blocked: bool,
    idle_days: int,
    slug: str,
    delivery_pr_states: list[str],
) -> Action:
    """What `/nase:efforts` should do next for one effort, from the same live inputs
    the transition takes plus the sweep's per-PR record. Pure; it never writes.

    `delivery_pr_states` is what the transition was given. A sweep record that
    disagrees with it, or a count that does not match the delivery PRs, is refused:
    the two decisions must not rest on different reads of the same PR."""
    lines = text.splitlines()
    index = merge_live_records(live)

    def live_of(ref: PrRef) -> LiveRecord:
        return index.get(pr_key(ref).casefold(), {})

    refs: list[PrRef] = classification["pr_references"]["delivery"]
    if delivery_pr_states:
        conflicts = (
            [f"{len(delivery_pr_states)} state(s) for {len(refs)} delivery PR(s)"]
            if len(delivery_pr_states) != len(refs)
            else [
                f"{pr_key(ref)} is {flag} by flag, {seen} in the sweep"
                for ref, flag in zip(refs, delivery_pr_states, strict=True)
                if (seen := live_of(ref).get("state")) and seen != flag
            ]
        )
        if conflicts:
            return _action(
                "ask",
                "delivery-state-unresolved",
                None,
                [pr_key(r) for r in refs],
                "; ".join(conflicts),
                blocking=1,
            )
    jira_unsettled = jira_is_tracked(text) and jira_state == "untracked"
    plan = parse_pr_plan(lines)
    opened = plan_attribution(refs, lines) if plan is not None else None
    advance = advance_action(classification, live_of, slug, blocked, plan, opened)
    if classification["stage"] != "awaiting_deploy":
        if advance["kind"] == "advance":
            return advance
        if (
            classification["stage"] in {"planning", "implementing"}
            and not refs
            and idle_days >= STALLED_IDLE_DAYS
        ):
            return _action(
                "ask",
                "stalled",
                f"/nase:design --review {slug}",
                [f"no delivery PR, untouched {idle_days} days"],
                f"status {classification['status']}, no PR, no change in {idle_days} days",
            )
        return advance

    pending_rows = classification["pending_postdeploy_validation"]
    validation_rows = [
        classify_validation_row(str(row["text"])) for row in pending_rows
    ]
    classified = {
        int(row["line"]): result
        for row, result in zip(pending_rows, validation_rows, strict=True)
    }
    section_heavy: list[str] = []
    for start, end in section_line_ranges(lines, VALIDATION_HEADING_RE):
        for number, line in enumerate(lines[start - 1 : end - 1], start):
            m = CHECKBOX_RE.match(line)
            if not m or m.group(1) != " ":
                continue
            kind, command = classified.get(number) or classify_validation_row(
                m.group(2)
            )
            if kind == "heavy" and command:
                section_heavy.append(command)
    deployed = any(e["label"] == "Deployed" for e in classification["evidence"])
    if deployed and not validation_rows and not classification["pending_followups"]:
        return _action(
            "none",
            "deployed-checked",
            context="Deployed is ticked; the transition decides the rest",
        )

    failures, edit, evidence = close_gate(
        classification,
        lines,
        live_of,
        jira_state,
        jira_unsettled,
        blocked,
        validation_rows,
        section_heavy,
        plan,
        opened,
    )
    if not deployed and edit and not any(blocks for _, _, blocks in failures):
        return _action(
            "close",
            "tests-ci-docs-only",
            None,
            evidence,
            "every delivery PR merged with green merge checks and only tests/CI/docs files",
            edit=edit,
        )
    runnable = [
        {
            "line": row["line"],
            "command": command,
            "expect": validation_expectation(str(row["text"])),
        }
        for row, (kind, command) in zip(
            classification["pending_postdeploy_validation"],
            validation_rows,
            strict=True,
        )
        if kind == "run"
    ]
    blocking = len({reason for reason, _, blocks in failures if blocks})
    if runnable and deployed:
        return _action(
            "validate",
            "read-only-validation",
            str(runnable[0]["command"]),
            [f"L{r['line']}: {r['command']}" for r in runnable],
            f"{len(runnable)} read-only post-deploy check(s)",
            rows=runnable,
        )
    if advance["kind"] == "advance":
        return advance
    reason, context = ask_reason(failures)
    if runnable:
        reason = "deployed-needs-ring-evidence"
    return _action(
        "ask",
        reason,
        None,
        [pr_key(r) for r in refs],
        "; ".join(dict.fromkeys(ctx for _, ctx, _ in failures)) or context,
        blocking=blocking,
    )


def effort_idle_days(path: Path) -> int:
    modified = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc)
    return (local_today() - modified.astimezone().date()).days


def load_live(path: Path | None) -> dict[str, LiveRecord]:
    """Per-PR records from a sweep file. A value of the wrong type is dropped, never trusted."""
    if path is None:
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    live = data.get("live", data) if isinstance(data, dict) else {}
    if not isinstance(live, dict):
        return {}
    return {str(key): value for key, value in live.items() if isinstance(value, dict)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--file", required=True, type=Path, help="active effort Markdown file"
    )
    parser.add_argument(
        "--delivery-pr-state",
        action="append",
        default=[],
        choices=("OPEN", "MERGED", "CLOSED", "UNREADABLE"),
        help="live state for one structured delivery PR; repeat for multiple PRs",
    )
    parser.add_argument(
        "--jira-state",
        default=None,
        choices=("untracked", "done", "not-done", "unreadable"),
        help="live state for the tracked Jira issue (default untracked; next_action "
        "treats a missing state on an effort with `jira:` as unresolved)",
    )
    parser.add_argument(
        "--blocked-by-unresolved",
        action="store_true",
        help="prevent lifecycle mutation while any blocker remains unresolved",
    )
    parser.add_argument(
        "--evaluate-transition",
        action="store_true",
        help="include the deterministic lifecycle transition decision",
    )
    parser.add_argument(
        "--archive-year",
        type=int,
        default=None,
        help="year folder for a tracking-only terminal move (default: current year)",
    )
    parser.add_argument(
        "--live-json",
        type=Path,
        default=None,
        help="effort-pr-sweep.py --json-out file; with --evaluate-transition it adds "
        "next_action, which reads per-PR state, files and merge_checks from it",
    )
    args = parser.parse_args()

    try:
        text = args.file.read_text(encoding="utf-8")
        live = load_live(args.live_json) if args.evaluate_transition else {}
    except (OSError, ValueError) as exc:
        print(f"ERROR: cannot read input: {exc}", file=sys.stderr)
        return 2

    result = classify(text)
    if args.evaluate_transition:
        jira_state = args.jira_state or "untracked"
        result["transition"] = transition(
            result,
            args.delivery_pr_state,
            jira_state,
            args.blocked_by_unresolved,
            args.archive_year,
        )
        result["next_action"] = next_action(
            result,
            text,
            live,
            jira_state,
            args.blocked_by_unresolved,
            effort_idle_days(args.file),
            args.file.stem,
            args.delivery_pr_state,
        )
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
