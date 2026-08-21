#!/usr/bin/env python3
"""Classify one active effort file with the shared lifecycle contract."""
from __future__ import annotations

import argparse
import datetime
import json
import re
import sys
from pathlib import Path

from frontmatter_scalar import canonical_bool, extract_frontmatter_scalar, normalize_scalar


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
FULL_PR_RE = re.compile(r"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)")
QUALIFIED_PR_RE = re.compile(r"(?<![A-Za-z0-9_.-/])([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([1-9][0-9]*)\b")
BARE_PR_RE = re.compile(r"(?<![\w#])#([1-9]\d*)\b")
MARKDOWN_PR_LINK_RE = re.compile(
    r"\[([^]]+)\]\(\s*https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*[^)]*\)"
)
DELIVERY_PR_KEY_RE = re.compile(r"(?i)^(pr|prs|phase_[\w-]*_pr)\s*:")
BLOCKED_BY_KEY_RE = re.compile(r"(?i)^blocked-by\s*:")
FRONTMATTER_LIST_ITEM_RE = re.compile(r"^\s*-\s+\S")
REPO_KEY_RE = re.compile(r"(?i)^repo\s*:\s*(.+?)\s*$")
REPO_FULL_NAME_RE = re.compile(r"^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$")
TARGET_PR_COUNT_RE = re.compile(
    r"(?i)(?:\*\*)?Target PR count(?:\*\*)?\s*:\s*(\d+)\b"
)
LIFECYCLE_HEADING_RE = re.compile(r"^(#{2,6})\s+Lifecycle\s*$", re.IGNORECASE)
HEADING_RE = re.compile(r"^(#{1,6})\s+\S")

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


def lifecycle_line_ranges(lines: list[str]) -> list[tuple[int, int]]:
    """1-indexed [start, end) spans of every `## Lifecycle` section."""
    ranges: list[tuple[int, int]] = []
    for index, line in enumerate(lines, 1):
        match = LIFECYCLE_HEADING_RE.match(line)
        if not match:
            continue
        start = index + 1
        lifecycle_level = len(match.group(1))
        end = len(lines) + 1
        for next_index in range(start, len(lines) + 1):
            heading = HEADING_RE.match(lines[next_index - 1])
            if heading and len(heading.group(1)) <= lifecycle_level:
                end = next_index
                break
        ranges.append((start, end))
    return ranges


def strip_emphasis(label: str) -> str:
    return label.lstrip("*_ ").strip()


def deemphasize(line: str) -> str:
    """Drop Markdown emphasis markers so word-boundary matches survive `**not** PR`."""
    return re.sub(r"[*_`]+", " ", line)


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
    return match.groups() if match else None


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
        refs.append({"owner": owner, "repo": repo, "number": int(number),
                     "source": source, "line": line_number})
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
        refs.append({"owner": owner, "repo": repo, "number": int(number),
                     "source": source, "line": line_number})
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
            {"number": int(match.group(1)), "line": line_number,
             "reason": "outside-lifecycle"}
            for match in bare_matches
        )
        return refs
    if denied:
        discarded.extend(
            {"number": int(match.group(1)), "line": line_number, "reason": "denied-in-row"}
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
                entry[1] > match.start() if entry[0] == line_number else entry[0] > line_number,
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
        refs.append({"owner": repo_context[0], "repo": repo_context[1],
                     "number": number, "source": source, "line": line_number})
    return refs


def dedupe_references(refs: list[dict[str, object]]) -> list[dict[str, object]]:
    """Collapse the three citation forms onto one entry per `{owner}/{repo}#{n}`."""
    seen: dict[tuple[object, object, object], dict[str, object]] = {}
    for ref in refs:
        key = (str(ref["owner"]).casefold(), str(ref["repo"]).casefold(), ref["number"])
        if key not in seen:
            seen[key] = ref
    return sorted(
        seen.values(),
        key=lambda ref: (str(ref["owner"]).casefold(), str(ref["repo"]).casefold(), int(str(ref["number"]))),
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
    if len(repo_values) == 1 and "/" in repo_values[0] and not REPO_FULL_NAME_RE.fullmatch(repo_values[0]):
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
    if key_counts.get("prs") == 1 and "prs" not in inline_values and "delivery" not in list_entries:
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
        in_lifecycle = any(start <= line_number < end for start, end in lifecycle_ranges)
        delivery.extend(
            collect_pr_references(
                line_number, line, "lifecycle:PR opened", in_lifecycle,
                explicit, fallback_repo, discarded
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


def classify(text: str) -> dict[str, object]:
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
            if canonical in {"PR opened", "Merged"} and OUTSTANDING_CLAUSE_RE.search(label):
                undelivered.append({"line": line_number, "text": label})
        if not is_checked and label.lower().startswith("follow-up:"):
            pending_followups += 1
        in_lifecycle = any(
            start <= line_number < end for start, end in lifecycle_ranges
        )
        if not is_checked and in_lifecycle and not label.lower().startswith("follow-up:"):
            plain_label = strip_emphasis(label)
            if canonical_label(plain_label) == "Merged":
                if OUTSTANDING_CLAUSE_RE.search(label) or PARTIAL_MERGED_RE.search(label):
                    undelivered.append({"line": line_number, "text": label})
                else:
                    stale_merged_candidates.append(
                        {"label": "Merged", "line": line_number, "text": label,
                         "bare_label": plain_label.lower() == "merged"}
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
        "target_pr_counts": target_pr_counts,
        "tracking_only": tracking_only,
        "tracking_only_valid": tracking_only_valid,
    }


def terminal_destination_dir(classification: dict[str, object], archive_year: int) -> str:
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
    classification: dict[str, object],
    delivery_pr_states: list[str],
    jira_state: str,
    blocked_by_unresolved: bool,
    archive_year: int | None = None,
) -> dict[str, object]:
    destination_dir = terminal_destination_dir(
        classification,
        archive_year if archive_year is not None else datetime.date.today().year,
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", required=True, type=Path, help="active effort Markdown file")
    parser.add_argument(
        "--delivery-pr-state",
        action="append",
        default=[],
        choices=("OPEN", "MERGED", "CLOSED", "UNREADABLE"),
        help="live state for one structured delivery PR; repeat for multiple PRs",
    )
    parser.add_argument(
        "--jira-state",
        default="untracked",
        choices=("untracked", "done", "not-done", "unreadable"),
        help="live state for the tracked Jira issue",
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
    args = parser.parse_args()

    try:
        text = args.file.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"ERROR: cannot read {args.file}: {exc}", file=sys.stderr)
        return 2

    result = classify(text)
    if args.evaluate_transition:
        result["transition"] = transition(
            result,
            args.delivery_pr_state,
            args.jira_state,
            args.blocked_by_unresolved,
            args.archive_year,
        )
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
