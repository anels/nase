#!/usr/bin/env python3
"""Read-only GitHub PR helper for nase PR workflows."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from json import JSONDecodeError
from pathlib import Path
from typing import Any


LIGHT_FIELDS = (
    "number",
    "title",
    "url",
    "body",
    "state",
    "isDraft",
    "headRefOid",
    "additions",
    "deletions",
    "changedFiles",
    "files",
    "baseRefName",
)

FULL_FIELDS = (
    "number",
    "title",
    "url",
    "body",
    "createdAt",
    "headRefOid",
    "headRefName",
    "baseRefName",
    "commits",
    "additions",
    "deletions",
    "changedFiles",
    "files",
    "state",
    "reviewDecision",
    "isDraft",
)

THREADS_QUERY = """
query($owner: String!, $repo: String!, $number: Int!, $threadCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      headRefName
      baseRefName
      headRepository {
        owner { login }
        name
        nameWithOwner
      }
      reviewThreads(first: 100, after: $threadCursor) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          id
          isResolved
          path
          line
          diffSide
          startLine
          originalLine
          originalStartLine
          subjectType
          comments(first: 100) {
            pageInfo {
              hasNextPage
              endCursor
            }
            nodes {
              id
              databaseId
              body
              author { login }
              createdAt
            }
          }
        }
      }
    }
  }
}
""".strip()

THREAD_COMMENTS_QUERY = """
query($threadId: ID!, $commentCursor: String) {
  node(id: $threadId) {
    ... on PullRequestReviewThread {
      comments(first: 100, after: $commentCursor) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          id
          databaseId
          body
          author { login }
          createdAt
        }
      }
    }
  }
}
""".strip()


class UsageError(ValueError):
    """Input did not identify a single GitHub PR."""


def parse_repo(repo: str) -> tuple[str, str]:
    match = re.fullmatch(r"([^/\s#?]+)/([^/\s#?]+)", repo.strip())
    if not match:
        raise UsageError(f"invalid repo '{repo}', expected owner/repo")
    return match.group(1), match.group(2)


def parse_pr_ref(ref: str, repo_hint: str | None = None) -> dict[str, Any]:
    text = ref.strip()

    patterns = (
        r"https?://github\.com/([^/\s#?]+)/([^/\s#?]+)/pull/([0-9]+)(?:[/?#].*)?",
        r"github\.com/([^/\s#?]+)/([^/\s#?]+)/pull/([0-9]+)(?:[/?#].*)?",
        r"([^/\s#?]+)/([^/\s#?]+)/pull/([0-9]+)",
        r"([^/\s#?]+)/([^/\s#?]+)#([0-9]+)",
    )
    for pattern in patterns:
        match = re.fullmatch(pattern, text)
        if match:
            owner, repo, number = match.groups()
            return normalized_pr(owner, repo, int(number))

    if re.fullmatch(r"[0-9]+", text):
        if not repo_hint:
            raise UsageError("number-only PR references require --repo owner/repo")
        owner, repo = parse_repo(repo_hint)
        return normalized_pr(owner, repo, int(text))

    raise UsageError(f"could not parse GitHub PR reference: {ref!r}")


def normalized_pr(owner: str, repo: str, number: int) -> dict[str, Any]:
    return {
        "owner": owner,
        "repo": repo,
        "repo_full_name": f"{owner}/{repo}",
        "number": number,
        "url": f"https://github.com/{owner}/{repo}/pull/{number}",
    }


def gh_metadata_args(pr: dict[str, Any], variant: str) -> list[str]:
    fields = LIGHT_FIELDS if variant == "light" else FULL_FIELDS
    return [
        "gh",
        "pr",
        "view",
        str(pr["number"]),
        "--repo",
        pr["repo_full_name"],
        "--json",
        ",".join(fields),
    ]


def gh_review_comments_args(pr: dict[str, Any]) -> list[str]:
    return ["gh", "api", f"repos/{pr['repo_full_name']}/pulls/{pr['number']}/comments", "--paginate"]


def gh_reviews_args(pr: dict[str, Any]) -> list[str]:
    return ["gh", "api", f"repos/{pr['repo_full_name']}/pulls/{pr['number']}/reviews", "--paginate"]


def gh_threads_args(pr: dict[str, Any], thread_cursor: str | None = None) -> list[str]:
    args = [
        "gh",
        "api",
        "graphql",
        "-F",
        f"owner={pr['owner']}",
        "-F",
        f"repo={pr['repo']}",
        "-F",
        f"number={pr['number']}",
    ]
    if thread_cursor:
        args.extend(["-F", f"threadCursor={thread_cursor}"])
    args.extend(["-f", f"query={THREADS_QUERY}"])
    return args


def gh_thread_comments_args(thread_id: str, comment_cursor: str | None = None) -> list[str]:
    args = ["gh", "api", "graphql", "-F", f"threadId={thread_id}"]
    if comment_cursor:
        args.extend(["-F", f"commentCursor={comment_cursor}"])
    args.extend(["-f", f"query={THREAD_COMMENTS_QUERY}"])
    return args


def command_plan(pr: dict[str, Any], variant: str) -> dict[str, Any]:
    return {
        "pr": pr,
        "metadata": gh_metadata_args(pr, variant),
        "diff_full": ["gh", "pr", "diff", str(pr["number"]), "--repo", pr["repo_full_name"]],
        "diff_stat": ["gh", "pr", "diff", str(pr["number"]), "--repo", pr["repo_full_name"], "--stat"],
        "review_comments": gh_review_comments_args(pr),
        "reviews": gh_reviews_args(pr),
        "review_threads": gh_threads_args(pr),
    }


def run_gh(args: list[str]) -> str:
    completed = subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE)
    return completed.stdout


def run_git(repo: Path, *args: str, check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def load_json(path: str) -> Any:
    if path == "-":
        return json.load(sys.stdin)
    with Path(path).open(encoding="utf-8") as handle:
        return json.load(handle)


def parse_json_documents(raw: str) -> list[Any]:
    decoder = json.JSONDecoder()
    docs: list[Any] = []
    idx = 0
    while idx < len(raw):
        while idx < len(raw) and raw[idx].isspace():
            idx += 1
        if idx >= len(raw):
            break
        doc, idx = decoder.raw_decode(raw, idx)
        docs.append(doc)
    return docs


def flatten_json_items(raw: str) -> list[Any]:
    items: list[Any] = []
    for doc in parse_json_documents(raw):
        if isinstance(doc, list):
            items.extend(doc)
        elif isinstance(doc, dict):
            items.append(doc)
    return items


def trunc(value: Any, limit: int) -> str:
    text = "" if value is None else str(value)
    text = re.sub(r"\s+", " ", text).strip()
    if limit > 0 and len(text) > limit:
        return text[: max(0, limit - 3)].rstrip() + "..."
    return text


def comments_connection_nodes(thread: dict[str, Any]) -> list[dict[str, Any]]:
    comments = thread.get("comments") or {}
    return list(comments.get("nodes") or [])


def login_from(value: dict[str, Any], *paths: str) -> str | None:
    for path in paths:
        cur: Any = value
        for part in path.split("."):
            if not isinstance(cur, dict):
                cur = None
                break
            cur = cur.get(part)
        if cur:
            return str(cur)
    return None


def first_value(value: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        item = value.get(key)
        if item:
            return item
    return None


def summarize_comment(value: dict[str, Any], max_body_chars: int) -> dict[str, Any]:
    return {
        "id": value.get("id"),
        "databaseId": value.get("databaseId"),
        "author": login_from(value, "author.login", "user.login"),
        "createdAt": first_value(value, "createdAt", "created_at", "submitted_at"),
        "path": value.get("path"),
        "line": first_value(value, "line", "original_line", "originalLine"),
        "inReplyToId": value.get("in_reply_to_id"),
        "body": trunc(value.get("body"), max_body_chars),
    }


def summarize_review(value: dict[str, Any], max_body_chars: int) -> dict[str, Any]:
    return {
        "id": value.get("id"),
        "state": value.get("state"),
        "author": login_from(value, "author.login", "user.login"),
        "submittedAt": first_value(value, "submittedAt", "submitted_at"),
        "body": trunc(value.get("body"), max_body_chars),
    }


def summarize_thread(thread: dict[str, Any], max_body_chars: int) -> dict[str, Any]:
    comments = comments_connection_nodes(thread)
    first = comments[0] if comments else {}
    last = comments[-1] if comments else {}
    return {
        "id": thread.get("id"),
        "isResolved": bool(thread.get("isResolved")),
        "path": thread.get("path"),
        "line": first_value(thread, "line", "originalLine"),
        "startLine": first_value(thread, "startLine", "originalStartLine"),
        "diffSide": thread.get("diffSide"),
        "subjectType": thread.get("subjectType"),
        "commentCount": len(comments),
        "firstComment": summarize_comment(first, max_body_chars) if first else None,
        "lastComment": summarize_comment(last, max_body_chars) if last else None,
    }


def changed_file_paths(metadata: dict[str, Any]) -> list[str]:
    files = metadata.get("files") or []
    paths: list[str] = []
    if isinstance(files, list):
        for item in files:
            if isinstance(item, dict):
                path = item.get("path") or item.get("filename")
            else:
                path = str(item)
            if path:
                paths.append(str(path))
    return paths


def kb_mentions_for_paths(paths: list[str], max_paths: int) -> list[dict[str, Any]]:
    if max_paths <= 0:
        return []
    root = Path(__file__).resolve().parents[2]
    script = root / ".claude" / "scripts" / "kb-search.sh"
    if not script.is_file():
        return []
    mentions: list[dict[str, Any]] = []
    for path in paths[:max_paths]:
        result = subprocess.run(
            ["bash", str(script), f"mentions:{path}", "--max-entry-lines", "8"],
            cwd=root,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        text = result.stdout.strip()
        if result.returncode == 0 and text:
            mentions.append({"path": path, "hits": trunc(text, 1200)})
    return mentions


def line_excerpt(text: str, line_no: int | None, context_lines: int) -> dict[str, Any]:
    lines = text.splitlines()
    if not lines:
        return {"available": True, "start": 0, "end": 0, "content": ""}
    if not line_no or line_no < 1:
        line_no = 1
    start = max(1, line_no - context_lines)
    end = min(len(lines), line_no + context_lines)
    content = "\n".join(f"{idx}: {lines[idx - 1]}" for idx in range(start, end + 1))
    return {"available": True, "start": start, "end": end, "content": content}


def file_at_ref(repo: Path, ref: str, path: str) -> tuple[bool, str]:
    result = run_git(repo, "show", f"{ref}:{path}")
    return result.returncode == 0, result.stdout


def diff_for_file(repo: Path, base_ref: str, head_ref: str, path: str) -> str:
    result = run_git(repo, "diff", "--no-ext-diff", f"{base_ref}..{head_ref}", "--", path)
    return result.stdout if result.returncode == 0 else ""


def thread_dossier(
    repo: Path,
    base_ref: str,
    head_ref: str,
    thread: dict[str, Any],
    context_lines: int,
    max_body_chars: int,
) -> dict[str, Any]:
    path = str(thread.get("path") or "")
    line_no = first_value(thread, "line", "originalLine")
    try:
        line_int = int(line_no) if line_no else None
    except (TypeError, ValueError):
        line_int = None

    head_ok, head_text = file_at_ref(repo, head_ref, path) if path else (False, "")
    base_ok, base_text = file_at_ref(repo, base_ref, path) if path else (False, "")
    diff = diff_for_file(repo, base_ref, head_ref, path) if path else ""

    return {
        **summarize_thread(thread, max_body_chars),
        "comments": [summarize_comment(item, max_body_chars) for item in comments_connection_nodes(thread)],
        "headRef": head_ref,
        "baseRef": base_ref,
        "headExcerpt": line_excerpt(head_text, line_int, context_lines) if head_ok else {"available": False},
        "baseExcerpt": line_excerpt(base_text, line_int, context_lines) if base_ok else {"available": False},
        "diffAvailable": bool(diff.strip()),
        "kbMentions": kb_mentions_for_paths([path], 1) if path else [],
    }


def review_context(pr: dict[str, Any], max_body_chars: int, max_kb_paths: int) -> dict[str, Any]:
    metadata = json.loads(run_gh(gh_metadata_args(pr, "light")))
    paths = changed_file_paths(metadata)
    comments = flatten_json_items(run_gh(gh_review_comments_args(pr)))
    reviews = flatten_json_items(run_gh(gh_reviews_args(pr)))
    diff_stat = run_gh(["gh", "pr", "diff", str(pr["number"]), "--repo", pr["repo_full_name"], "--stat"])
    return {
        "pr": pr,
        "metadata": metadata,
        "sizeGate": size_gate(metadata, 1500, 1500),
        "changedFiles": paths,
        "diffStat": diff_stat.strip(),
        "reviewComments": [summarize_comment(item, max_body_chars) for item in comments],
        "reviews": [summarize_review(item, max_body_chars) for item in reviews],
        "kbMentions": kb_mentions_for_paths(paths, max_kb_paths),
    }


def comment_dossiers(
    pr: dict[str, Any],
    local_repo: Path,
    unresolved_only: bool,
    context_lines: int,
    max_body_chars: int,
) -> dict[str, Any]:
    response = unresolved_threads_from_response(fetch_review_threads(pr), unresolved_only)
    base_ref = f"origin/{response['baseRefName']}"
    head_ref = f"origin/{response['headRefName']}"
    return {
        "pr": pr,
        "baseRefName": response["baseRefName"],
        "headRefName": response["headRefName"],
        "headRepository": response["headRepository"],
        "threads": [
            thread_dossier(local_repo, base_ref, head_ref, thread, context_lines, max_body_chars)
            for thread in response["threads"]
        ],
    }


BOT_LOGINS = {
    "copilot-pull-request-reviewer[bot]",
    "copilot-pull-request-reviewer",
    "github-actions[bot]",
    "codex-bot",
    "claude",
    "claude[bot]",
    # epixa severity bot: re-posts declined findings as new threads per push, and
    # its login has no [bot]/-bot suffix, so the suffix rule below misses it.
    "uipathepixa",
}


def is_bot_login(login: str | None) -> bool:
    if not login:
        return False
    lowered = login.lower()
    return lowered in BOT_LOGINS or lowered.endswith("[bot]") or lowered.endswith("-bot")


def bot_decline_candidates(threads: list[dict[str, Any]], max_body_chars: int) -> list[dict[str, Any]]:
    candidates: list[dict[str, Any]] = []
    for thread in threads:
        if thread.get("isResolved"):
            continue
        comments = comments_connection_nodes(thread)
        if len(comments) < 2:
            continue
        first_author = login_from(comments[0], "author.login", "user.login")
        last_author = login_from(comments[-1], "author.login", "user.login")
        if is_bot_login(first_author) and not is_bot_login(last_author):
            candidates.append(summarize_thread(thread, max_body_chars))
    return candidates


def read_abort_state(
    state_dir: Path,
    pr: dict[str, Any],
    current_branch_sha: str | None = None,
    current_base_sha: str | None = None,
) -> dict[str, Any]:
    path = state_dir / f"prep-merge-{pr['owner']}-{pr['repo']}-{pr['number']}-abort.json"
    if not path.is_file():
        return {"path": str(path), "exists": False}
    try:
        content = json.loads(path.read_text(encoding="utf-8"))
        branch_matches = content.get("branch_sha") == current_branch_sha
        base_matches = content.get("base_sha") == current_base_sha
        return {
            "path": str(path),
            "exists": True,
            "content": content,
            "matchesCurrent": bool(branch_matches and base_matches),
        }
    except (OSError, JSONDecodeError) as exc:
        return {"path": str(path), "exists": True, "error": str(exc)}


def adjacent_same_file_overlap(repo: Path, base_branch: str, pr_branch: str, opened_at: str | None) -> dict[str, Any]:
    if not opened_at:
        return {"scanRan": False, "reason": "PR opened time unavailable", "files": []}
    file_result = run_git(repo, "diff", f"origin/{base_branch}..origin/{pr_branch}", "--name-only")
    if file_result.returncode != 0:
        return {"scanRan": False, "reason": file_result.stderr.strip(), "files": []}

    overlaps: list[dict[str, Any]] = []
    for path in [line for line in file_result.stdout.splitlines() if line.strip()]:
        log = run_git(repo, "log", f"origin/{base_branch}", f"--since={opened_at}", "--oneline", "--", path)
        if log.returncode == 0 and log.stdout.strip():
            overlaps.append({"path": path, "commits": log.stdout.splitlines()})
    return {"scanRan": True, "files": overlaps}


def prep_state(pr: dict[str, Any], local_repo: Path, state_dir: Path, max_body_chars: int) -> dict[str, Any]:
    metadata = json.loads(run_gh(gh_metadata_args(pr, "full")))
    response = unresolved_threads_from_response(fetch_review_threads(pr), unresolved_only=False)
    threads = response["threads"]
    unresolved = [thread for thread in threads if not thread.get("isResolved")]
    remote_ref = f"origin/{metadata.get('headRefName')}"
    remote_head = run_git(local_repo, "rev-parse", remote_ref)
    remote_sha = remote_head.stdout.strip() if remote_head.returncode == 0 else None
    base_head = run_git(local_repo, "rev-parse", f"origin/{metadata.get('baseRefName')}")
    base_sha = base_head.stdout.strip() if base_head.returncode == 0 else None

    return {
        "pr": pr,
        "metadata": metadata,
        "baseRefName": response.get("baseRefName"),
        "headRefName": response.get("headRefName"),
        "headRepository": response.get("headRepository"),
        "remoteHead": {
            "ref": remote_ref,
            "sha": remote_sha,
            "matchesMetadata": bool(remote_sha and remote_sha == metadata.get("headRefOid")),
            "error": remote_head.stderr.strip() if remote_head.returncode else None,
        },
        "reviewThreads": {
            "total": len(threads),
            "unresolved": [summarize_thread(thread, max_body_chars) for thread in unresolved],
            "botDeclineCandidates": bot_decline_candidates(threads, max_body_chars),
        },
        "priorAbort": read_abort_state(state_dir, pr, remote_sha, base_sha),
        "adjacentSameFileOverlap": adjacent_same_file_overlap(
            local_repo,
            str(metadata.get("baseRefName") or response.get("baseRefName") or ""),
            str(metadata.get("headRefName") or response.get("headRefName") or ""),
            metadata.get("createdAt"),
        ),
    }


def size_gate(metadata: dict[str, Any], warn_threshold: int, stat_threshold: int) -> dict[str, Any]:
    additions = int(metadata.get("additions") or 0)
    deletions = int(metadata.get("deletions") or 0)
    total = additions + deletions
    result = {
        "additions": additions,
        "deletions": deletions,
        "total_lines": total,
        "review_warning": total > warn_threshold,
        "diff_mode": "stat" if total > stat_threshold else "full",
        "warn_threshold": warn_threshold,
        "stat_threshold": stat_threshold,
    }
    if result["review_warning"]:
        result["warning"] = (
            f"This PR is {total} lines; single-pass review reliability drops significantly."
        )
    return result


def unresolved_threads_from_response(response: dict[str, Any], unresolved_only: bool) -> dict[str, Any]:
    pull_request = response["data"]["repository"]["pullRequest"]
    nodes = pull_request.get("reviewThreads", {}).get("nodes") or []
    if unresolved_only:
        nodes = [node for node in nodes if not node.get("isResolved")]
    return {
        "headRefName": pull_request.get("headRefName"),
        "baseRefName": pull_request.get("baseRefName"),
        "headRepository": pull_request.get("headRepository"),
        "threads": nodes,
    }


def _connection_page_info(connection: dict[str, Any]) -> dict[str, Any]:
    page_info = connection.get("pageInfo") or {}
    return {
        "hasNextPage": bool(page_info.get("hasNextPage")),
        "endCursor": page_info.get("endCursor"),
    }


def _fetch_remaining_comments(thread: dict[str, Any]) -> dict[str, Any]:
    comments = thread.get("comments") or {}
    page_info = _connection_page_info(comments)
    nodes = list(comments.get("nodes") or [])
    cursor = page_info["endCursor"]

    while page_info["hasNextPage"]:
        if not cursor:
            raise RuntimeError(f"thread {thread.get('id')} comments page is missing endCursor")
        raw = run_gh(gh_thread_comments_args(str(thread["id"]), str(cursor)))
        response = json.loads(raw)
        node = response.get("data", {}).get("node")
        if not isinstance(node, dict):
            raise RuntimeError(f"could not fetch comments for thread {thread.get('id')}")
        page = node.get("comments") or {}
        nodes.extend(page.get("nodes") or [])
        page_info = _connection_page_info(page)
        cursor = page_info["endCursor"]

    merged_thread = dict(thread)
    merged_thread["comments"] = {
        "nodes": nodes,
        "pageInfo": {
            "hasNextPage": False,
            "endCursor": cursor,
        },
    }
    return merged_thread


def fetch_review_threads(pr: dict[str, Any]) -> dict[str, Any]:
    """Fetch every review thread and every comment page for a PR."""
    merged_pull_request: dict[str, Any] | None = None
    all_threads: list[dict[str, Any]] = []
    cursor: str | None = None

    while True:
        raw = run_gh(gh_threads_args(pr, cursor))
        response = json.loads(raw)
        pull_request = response["data"]["repository"]["pullRequest"]
        threads_connection = pull_request.get("reviewThreads") or {}

        if merged_pull_request is None:
            merged_pull_request = {
                key: value for key, value in pull_request.items() if key != "reviewThreads"
            }

        for thread in threads_connection.get("nodes") or []:
            all_threads.append(_fetch_remaining_comments(thread))

        page_info = _connection_page_info(threads_connection)
        if not page_info["hasNextPage"]:
            break
        if not page_info["endCursor"]:
            raise RuntimeError("reviewThreads page is missing endCursor")
        cursor = str(page_info["endCursor"])

    assert merged_pull_request is not None
    merged_pull_request["reviewThreads"] = {
        "nodes": all_threads,
        "pageInfo": {
            "hasNextPage": False,
            "endCursor": cursor,
        },
    }
    return {"data": {"repository": {"pullRequest": merged_pull_request}}}


def emit_json(value: Any) -> None:
    print(json.dumps(value, indent=2, sort_keys=True))


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    parse = sub.add_parser("parse", help="Parse a GitHub PR reference")
    parse.add_argument("ref")
    parse.add_argument("--repo", help="owner/repo, required for number-only refs")

    commands = sub.add_parser("commands", help="Print the read-only gh command plan")
    commands.add_argument("ref")
    commands.add_argument("--repo", help="owner/repo, required for number-only refs")
    commands.add_argument("--variant", choices=("light", "full"), default="light")

    metadata = sub.add_parser("metadata", help="Fetch PR metadata via gh pr view")
    metadata.add_argument("ref")
    metadata.add_argument("--repo", help="owner/repo, required for number-only refs")
    metadata.add_argument("--variant", choices=("light", "full"), default="light")

    threads = sub.add_parser("review-threads", help="Fetch PR review threads via gh api graphql")
    threads.add_argument("ref")
    threads.add_argument("--repo", help="owner/repo, required for number-only refs")
    threads.add_argument("--unresolved-only", action="store_true")

    gate = sub.add_parser("size-gate", help="Classify diff fetch mode from PR metadata JSON")
    gate.add_argument("--metadata", required=True, help="Path to metadata JSON, or - for stdin")
    gate.add_argument("--warn-threshold", type=int, default=1500)
    gate.add_argument("--stat-threshold", type=int, default=1500)

    review = sub.add_parser("review-context", help="Fetch compact read-only context for PR review")
    review.add_argument("ref")
    review.add_argument("--repo", help="owner/repo, required for number-only refs")
    review.add_argument("--max-body-chars", type=int, default=400)
    review.add_argument("--max-kb-paths", type=int, default=10)

    dossiers = sub.add_parser("comment-dossiers", help="Build compact unresolved review-thread dossiers")
    dossiers.add_argument("ref")
    dossiers.add_argument("--repo", help="owner/repo, required for number-only refs")
    dossiers.add_argument("--local-repo", required=True)
    dossiers.add_argument("--unresolved-only", action="store_true")
    dossiers.add_argument("--context-lines", type=int, default=4)
    dossiers.add_argument("--max-body-chars", type=int, default=400)

    prep = sub.add_parser("prep-state", help="Fetch compact state for prep-merge")
    prep.add_argument("ref")
    prep.add_argument("--repo", help="owner/repo, required for number-only refs")
    prep.add_argument("--local-repo", required=True)
    prep.add_argument("--state-dir", default="workspace/tmp")
    prep.add_argument("--max-body-chars", type=int, default=300)

    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        if args.command == "size-gate":
            emit_json(size_gate(load_json(args.metadata), args.warn_threshold, args.stat_threshold))
            return 0

        pr = parse_pr_ref(args.ref, getattr(args, "repo", None))
        if args.command == "parse":
            emit_json(pr)
        elif args.command == "commands":
            emit_json(command_plan(pr, args.variant))
        elif args.command == "metadata":
            sys.stdout.write(run_gh(gh_metadata_args(pr, args.variant)))
        elif args.command == "review-threads":
            emit_json(unresolved_threads_from_response(fetch_review_threads(pr), args.unresolved_only))
        elif args.command == "review-context":
            emit_json(review_context(pr, args.max_body_chars, args.max_kb_paths))
        elif args.command == "comment-dossiers":
            emit_json(
                comment_dossiers(
                    pr,
                    Path(args.local_repo).resolve(),
                    args.unresolved_only,
                    args.context_lines,
                    args.max_body_chars,
                )
            )
        elif args.command == "prep-state":
            state_dir = Path(args.state_dir)
            if not state_dir.is_absolute():
                state_dir = Path.cwd() / state_dir
            emit_json(prep_state(pr, Path(args.local_repo).resolve(), state_dir, args.max_body_chars))
        return 0
    except UsageError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except subprocess.CalledProcessError as exc:
        return exc.returncode


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
