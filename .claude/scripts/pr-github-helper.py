#!/usr/bin/env python3
"""Read-only GitHub PR helper for nase PR workflows."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
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


def load_json(path: str) -> Any:
    if path == "-":
        return json.load(sys.stdin)
    with Path(path).open(encoding="utf-8") as handle:
        return json.load(handle)


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
        return 0
    except UsageError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except subprocess.CalledProcessError as exc:
        return exc.returncode


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
