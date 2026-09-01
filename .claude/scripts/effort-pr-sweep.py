#!/usr/bin/env python3
"""Batch-read live PR state for active efforts and audit the delivery set for blind spots.

`effort-state.py` builds its delivery set from `pr:`/`prs:` frontmatter plus lifecycle rows
whose label is *canonically* `PR opened`. A row labelled `PR2 opened`, `PR-3b`, `W8 PR opened`
or `PR 2 — ` cites a real delivery PR and is invisible to it, so an effort with six delivery
PRs can classify as a one-PR effort and transition on one-sixth of the evidence.

This script does three things, one pass of `gh pr view` per PR:

1. `live`      - state / reviewDecision / mergedAt / mergeCommit / failing + pending checks.
2. `invisible` - PRs cited by a checked lifecycle row that never reach the delivery set,
                 each with the row's label and a hint at why it might be *correctly* excluded.
3. `reverts`   - merge commits later named by a revert commit, where a local clone is known.

Only (1) is mechanical. (2) is a prompt for judgment, not a repair list: cherry-picks,
withdrawn PRs, sibling-effort dependencies, spikes and phase-summary rows all cite PRs that
the delivery set should not carry, and relabelling them would fire wrong transitions. The
hints exist so the caller classifies rather than bulk-edits.

Exit status is 0 whenever the sweep itself ran. Unreadable PRs are reported as data.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[1]

PR_URL_RE = re.compile(r"github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)")
PR_QUALIFIED_RE = re.compile(r"\b([\w.-]+)/([\w.-]+)#(\d+)\b")
ROW_RE = re.compile(r"^- \[(x| )\]\s*(.*)$")
CANONICAL_RE = re.compile(
    r"^\**\s*(PR opened|Merged|Deployed|Review passed|Implementation started)\b", re.IGNORECASE
)
SUBPROCESS_TIMEOUT = 60
GH_FIELDS = "number,state,reviewDecision,mergedAt,mergeCommit,statusCheckRollup,title,baseRefName"

# Why a cited PR may be *correctly* absent from the delivery set. Order matters: the first
# match wins, and `likely-delivery` is the fallthrough that actually needs a human decision.
EXCLUSION_HINTS = (
    # `Follow-up:` is also the Drift Auto-Sync exempt prefix, so it is a real class here
    # rather than a guess - check it before the looser text patterns below.
    ("likely-follow-up", re.compile(r"^\**\s*follow[- ]up\b", re.IGNORECASE)),
    ("likely-cherry-pick", re.compile(r"cherry[- ]pick|🍒|backport", re.IGNORECASE)),
    ("likely-withdrawn", re.compile(r"withdrawn|abandoned|superseded|closed without|not merged",
                                    re.IGNORECASE)),
    ("likely-sibling-dependency", re.compile(r"sibling|downstream|upstream|blocked on|"
                                             r"prerequisite|step 0", re.IGNORECASE)),
    ("likely-spike", re.compile(r"\bspike\b", re.IGNORECASE)),
    ("likely-phase-summary", re.compile(
        r"^\**\s*(phase|step|closing wave)\s|\b(phase\s*\d|wave\s*\d|sub-effort)\b",
        re.IGNORECASE)),
)


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    """Run a command, reporting a hang or a missing binary as a failed result.

    Every caller already branches on `returncode`, and the sweep's contract is that one bad
    read is data. Letting `TimeoutExpired` propagate would end the whole run on a single slow
    `gh` call and lose the audit for every other effort.
    """
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=SUBPROCESS_TIMEOUT)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", f"timed out after {SUBPROCESS_TIMEOUT}s")
    except OSError as exc:
        return subprocess.CompletedProcess(cmd, 127, "", str(exc))


def local_paths() -> dict[str, str]:
    """Map `RepoName` -> absolute path from `.local-paths`, for the revert check."""
    out: dict[str, str] = {}
    path = REPO_ROOT / ".local-paths"
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        if value.startswith("/"):
            out[key.strip()] = value.strip()
    return out


def classify_state(payload: dict) -> dict:
    checks = payload.get("statusCheckRollup") or []
    failing = [c.get("name") or c.get("context") for c in checks
               if c.get("conclusion") in {"FAILURE", "CANCELLED", "TIMED_OUT"}
               or c.get("state") == "FAILURE"]
    pending = [c.get("name") or c.get("context") for c in checks
               if c.get("status") in {"IN_PROGRESS", "QUEUED"} or c.get("state") == "PENDING"]
    merge_commit = (payload.get("mergeCommit") or {}).get("oid")
    return {
        "state": payload.get("state"),
        "reviewDecision": payload.get("reviewDecision"),
        "mergedAt": payload.get("mergedAt"),
        "mergeCommit": merge_commit,
        "baseRefName": payload.get("baseRefName"),
        "title": (payload.get("title") or "")[:90],
        "checks": len(checks),
        "failing": [f for f in failing if f][:6],
        "pending": [p for p in pending if p][:6],
    }


def read_pr(ref: tuple[str, str, int]) -> tuple[str, dict]:
    owner, repo, number = ref
    key = f"{owner}/{repo}#{number}"
    proc = run(["gh", "pr", "view", str(number), "--repo", f"{owner}/{repo}",
                "--json", GH_FIELDS])
    if proc.returncode != 0:
        return key, {"state": "UNREADABLE", "error": proc.stderr.strip()[:200]}
    try:
        return key, classify_state(json.loads(proc.stdout))
    except json.JSONDecodeError as exc:
        return key, {"state": "UNREADABLE", "error": f"bad json: {exc}"}


def effort_state(path: Path) -> dict | None:
    proc = run(["python3", str(SCRIPT_DIR / "effort-state.py"), "--file", str(path)])
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None


def cited_prs(text: str, known_owners: frozenset[str]) -> set[tuple[str, str, int]]:
    """Every PR a row names by URL or `owner/repo#n`.

    Bare `#n` is deliberately not resolved here - `effort-state.py` owns that rule, including
    the row-level denials, and re-deriving it would reintroduce the false positives the
    lifecycle doc warns about.

    The qualified form is filtered to owners that appear in a real PR URL somewhere in the
    corpus. Effort prose is full of `owner/repo#n` lookalikes - `Grill C3/SC#5`, `round 2/SC#5`
    - and without that filter they surface as phantom invisible PRs, which is worse than
    missing one: it teaches the reader to skim the list.
    """
    found = {(m[0], m[1], int(m[2])) for m in PR_URL_RE.findall(text)}
    found |= {(m[0], m[1], int(m[2])) for m in PR_QUALIFIED_RE.findall(text)
              if m[0] in known_owners}
    return found


def hint_for(label: str) -> str:
    for name, pattern in EXCLUSION_HINTS:
        if pattern.search(label):
            return name
    return "likely-delivery"


def audit_effort(path: Path, known_owners: frozenset[str]) -> dict:
    state = effort_state(path)
    if state is None:
        return {"effort": path.stem, "error": "effort-state.py failed"}

    refs = state.get("pr_references") or {}
    # Membership is by owner/repo/number, not number alone: sibling repos share numbers
    # (`platform#2003` and `platform-monitoring#2003`), and a number-only test would report
    # the second one as delivered by the first. A delivery entry that carries no repo
    # context falls back to its number, which is all the classifier knew about it.
    delivery_refs: set[tuple[str, str, int]] = set()
    unqualified_delivery: set[int] = set()
    all_refs: set[tuple[str, str, int]] = set()
    for entry in refs.get("delivery", []):
        number = int(entry["number"])
        owner, repo = entry.get("owner"), entry.get("repo")
        if owner and repo:
            delivery_refs.add((str(owner).casefold(), str(repo).casefold(), number))
            all_refs.add((owner, repo, number))
        else:
            unqualified_delivery.add(number)
    delivery = sorted({n for _, _, n in delivery_refs} | unqualified_delivery)

    invisible = []

    for idx, line in enumerate(path.read_text().splitlines(), 1):
        match = ROW_RE.match(line)
        if not match:
            continue
        checked, body = match.group(1) == "x", match.group(2)
        found = cited_prs(body, known_owners)
        all_refs |= found
        if not checked:
            continue
        missing = {
            r for r in found
            if (r[0].casefold(), r[1].casefold(), r[2]) not in delivery_refs
            and r[2] not in unqualified_delivery
        }
        if missing and not CANONICAL_RE.match(body):
            for owner, repo, number in sorted(missing):
                invisible.append({
                    "line": idx,
                    "pr": f"{owner}/{repo}#{number}",
                    "label": body[:70],
                    "hint": hint_for(body),
                })

    return {
        "effort": path.stem,
        "status": state.get("status"),
        "stage": state.get("stage"),
        "delivery": delivery,
        "invisible": invisible,
        "refs": sorted(all_refs),
    }


def find_reverts(live: dict[str, dict], paths: dict[str, str]) -> list[dict]:
    """A revert leaves the original merge commit an ancestor forever, so containment stays
    true after the content is gone. Surface any commit whose subject reverts a PR number."""
    out = []
    for key, payload in live.items():
        sha = payload.get("mergeCommit")
        if payload.get("state") != "MERGED" or not sha:
            continue
        owner_repo, _, number = key.partition("#")
        repo_path = paths.get(owner_repo.split("/")[1])
        if not repo_path:
            continue
        proc = run(["git", "-C", repo_path, "log", "--all", "-i",
                    f"--grep=revert.*#{number}\\b", "-3", "--format=%H %s"])
        if proc.returncode != 0 or not proc.stdout.strip():
            continue
        for row in proc.stdout.strip().splitlines():
            rev_sha, _, subject = row.partition(" ")
            if rev_sha.startswith(sha[:8]):
                continue
            out.append({"pr": key, "merge_commit": sha[:12],
                        "revert_commit": rev_sha[:12], "subject": subject[:110]})
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--efforts-dir", default="workspace/efforts")
    ap.add_argument("--file", help="audit a single effort file instead of the whole directory")
    ap.add_argument("--no-live", action="store_true",
                    help="skip gh reads; label audit only (offline, fast)")
    ap.add_argument("--check-reverts", action="store_true",
                    help="look for revert commits naming each merged PR (needs a local clone)")
    ap.add_argument("--format", choices=["human", "json"], default="human")
    args = ap.parse_args()

    if args.file:
        files = [Path(args.file)]
    else:
        base = Path(args.efforts_dir)
        if not base.is_absolute():
            base = REPO_ROOT / base
        files = sorted(base.glob("*.md"))
    if not files:
        print("no active effort files found", file=sys.stderr)
        return 0

    known_owners = frozenset(
        m[0] for path in files for m in PR_URL_RE.findall(path.read_text())
    )

    with ThreadPoolExecutor(max_workers=8) as pool:
        audits = list(pool.map(lambda p: audit_effort(p, known_owners), files))

    all_refs: set[tuple[str, str, int]] = set()
    for a in audits:
        all_refs.update(a.get("refs", []))

    live: dict[str, dict] = {}
    if not args.no_live and all_refs:
        with ThreadPoolExecutor(max_workers=10) as pool:
            for key, payload in pool.map(read_pr, sorted(all_refs)):
                live[key] = payload

    reverts: list[dict] = []
    if args.check_reverts and live:
        reverts = find_reverts(live, local_paths())

    result = {"efforts": audits, "live": live, "reverts": reverts}

    if args.format == "json":
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0

    flagged = [a for a in audits if a.get("invisible")]
    print(f"== effort-pr-sweep: {len(audits)} efforts, {len(all_refs)} unique PRs, "
          f"{len(flagged)} with an invisible PR ==\n")

    if live:
        unreadable = [k for k, v in live.items() if v.get("state") == "UNREADABLE"]
        open_prs = sorted(k for k, v in live.items() if v.get("state") == "OPEN")
        print(f"live: {len(live)} read, {len(open_prs)} OPEN, {len(unreadable)} unreadable")
        for key in open_prs:
            v = live[key]
            extra = f" fail={len(v['failing'])} pend={len(v['pending'])}" if v.get("checks") else ""
            print(f"    OPEN  {key:44} rev={v.get('reviewDecision') or '-'}{extra}")
        for key in unreadable:
            print(f"    UNREADABLE  {key}  {live[key].get('error', '')[:80]}")
        print()

    if reverts:
        print("REVERTED - the merge commit is still an ancestor, the content is not:")
        for r in reverts:
            print(f"    {r['pr']}  merge {r['merge_commit']}  reverted by {r['revert_commit']}")
            print(f"        {r['subject']}")
        print("    Verify by content: grep a symbol the PR ADDED at the ring commit.\n")

    if flagged:
        print("invisible to the delivery set - classify each, do not bulk-relabel:")
        for a in flagged:
            print(f"  {a['effort']}   delivery={a['delivery']}")
            for item in a["invisible"]:
                print(f"    L{item['line']:<5} {item['pr']:34} [{item['hint']}]")
                print(f"          label: {item['label']}")
        print("\n    `likely-delivery` is the actionable class: give the row the canonical")
        print("    `PR opened` label and keep its own number in the body, e.g.")
        print("    `- [x] PR opened — **PR-2** — <url>`. The other hints are usually correct")
        print("    exclusions - relabelling them can fire a transition on evidence that is")
        print("    not this effort's delivery.")
    else:
        print("no invisible delivery PRs")

    return 0


if __name__ == "__main__":
    sys.exit(main())
