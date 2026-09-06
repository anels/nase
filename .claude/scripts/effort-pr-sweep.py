#!/usr/bin/env python3
"""Batch-read live PR state for effort docs and audit the delivery set for blind spots.

`effort-state.py` builds its delivery set from `pr:`/`prs:` frontmatter plus lifecycle rows
whose label is *canonically* `PR opened`. A row labelled `PR2 opened`, `PR-3b`, `W8 PR opened`
or `PR 2 — ` cites a real delivery PR and is invisible to it, so an effort with six delivery
PRs can classify as a one-PR effort and transition on one-sixth of the evidence.

The default pass reads the active efforts and emits four things, one `gh pr view` per PR:

1. `live`            - state / reviewDecision / mergedAt / mergeCommit / failing + pending
                       checks.
2. `invisible`       - PRs cited by a checked lifecycle row that never reach the delivery
                       set, each with the row's label and a hint at why it might be
                       *correctly* excluded.
3. `reverts`         - merge commits later named by a revert commit, where a local clone is
                       known.
4. `delivery_owners` - which effort's delivery set already claims each cited PR.

Only (1) and (4) are mechanical. (2) is a prompt for judgment, not a repair list:
cherry-picks, withdrawn PRs, sibling-effort dependencies, spikes and phase-summary rows all
cite PRs that the delivery set should not carry, and relabelling them would fire wrong
transitions. The hints exist so the caller classifies rather than bulk-edits.

`--closed` audits the terminal docs in `done/` and `archive/*/` instead, and emits
`findings` alone: defects in a record nothing else re-reads, per
`.claude/docs/effort-doc-audit.md -> Part 2`. The row scan does not run there - it asks
whether a doc would transition on evidence that is not its own, and a terminal doc has no
transition left to fire.

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
    # The name lists below are capped for display. Carry the true counts too, so a
    # PR with 14 failing checks does not report `fail=6`.
    named_failing = [f for f in failing if f]
    named_pending = [p for p in pending if p]
    return {
        "state": payload.get("state"),
        "reviewDecision": payload.get("reviewDecision"),
        "mergedAt": payload.get("mergedAt"),
        "mergeCommit": merge_commit,
        "baseRefName": payload.get("baseRefName"),
        "title": (payload.get("title") or "")[:90],
        "checks": len(checks),
        "failing": named_failing[:6],
        "pending": named_pending[:6],
        "failingCount": len(named_failing),
        "pendingCount": len(named_pending),
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


def corpus_files(efforts_dir: Path) -> list[Path]:
    """Every effort doc, active and terminal.

    Ownership has to be resolved against the whole corpus, not the active set: a PR whose
    own effort already closed still belongs to that effort, and an active doc that cites it
    is citing someone else's delivery.
    """
    return sorted(
        {*efforts_dir.glob("*.md"), *efforts_dir.glob("done/*.md"),
         *efforts_dir.glob("archive/*/*.md")}
    )


def corpus_states(files: list[Path]) -> dict[Path, dict | None]:
    """`effort-state.py` output for every doc, read once.

    The helper is one subprocess per doc, and both the ownership map and the audit need
    the same output. Reading it twice made `--closed` spawn 405 interpreters to classify
    189 documents.
    """
    with ThreadPoolExecutor(max_workers=8) as pool:
        return dict(pool.map(lambda p: (p, effort_state(p)), files))


def delivery_owners(states: dict[Path, dict | None]) -> dict[tuple[str, str, int], list[str]]:
    """Map each PR to the effort(s) whose structured *delivery* set carries it.

    This turns the sweep's hardest judgment call into a lookup. A row can cite a PR for
    many reasons, and the text hints below only guess from prose - but if another effort's
    delivery set already claims that PR, the citation here is context by construction, and
    relabelling the row would fire this effort's transition on another effort's evidence.
    Measured on this workspace: two `done/` efforts' delivery PRs read as a third effort's
    unrecorded delivery until the map was consulted.

    Delivery sets come from `effort-state.py`, never a local re-derivation - the bare-`#n`
    and row-denial rules live there, and a second implementation would drift from them.
    """
    owners: dict[tuple[str, str, int], list[str]] = {}
    for path, state in states.items():
        if state is None:
            continue
        slug = path.stem
        for entry in (state.get("pr_references") or {}).get("delivery", []):
            owner, repo = entry.get("owner"), entry.get("repo")
            if not owner or not repo:
                continue
            key = (str(owner).casefold(), str(repo).casefold(), int(entry["number"]))
            owners.setdefault(key, []).append(slug)
    return owners


def audit_effort(path: Path, known_owners: frozenset[str],
                 owners: dict[tuple[str, str, int], list[str]],
                 scan_rows: bool, state: dict | None) -> dict:
    if state is None:
        return {"effort": path.stem, "error": "effort-state.py failed"}

    refs = state.get("pr_references") or {}
    # Membership is by owner/repo/number, not number alone: sibling repos share numbers
    # (`platform#2003` and `platform-monitoring#2003`), and a number-only test would report
    # the second one as delivered by the first. A delivery entry that carries no repo
    # context falls back to its number, which is all the classifier knew about it.
    delivery_refs: set[tuple[str, str, int]] = set()
    delivery_cased: set[tuple[str, str, int]] = set()
    unqualified_delivery: set[int] = set()
    all_refs: set[tuple[str, str, int]] = set()
    for entry in refs.get("delivery", []):
        number = int(entry["number"])
        owner, repo = entry.get("owner"), entry.get("repo")
        if owner and repo:
            owner, repo = str(owner), str(repo)
            delivery_refs.add((owner.casefold(), repo.casefold(), number))
            # Kept in the doc's own casing as well: the casefolded form is for membership
            # tests, but `.local-paths` keys and `gh` lookups want the real repo name.
            delivery_cased.add((owner, repo, number))
            all_refs.add((owner, repo, number))
        else:
            unqualified_delivery.add(number)
    delivery = sorted({n for _, _, n in delivery_refs} | unqualified_delivery)

    invisible = []

    # The row scan answers "would this doc transition on evidence that is not its own",
    # which is only a question while the effort can still transition. A terminal doc has
    # no transition left to fire, so `--closed` turns the scan off: on this corpus it
    # produced 100 rows no caller of that pass acts on, and most of its payload.
    for idx, line in (enumerate(path.read_text().splitlines(), 1) if scan_rows else ()):
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
            text_hint = hint_for(body)
            for owner, repo, number in sorted(missing):
                entry = {
                    "line": idx,
                    "pr": f"{owner}/{repo}#{number}",
                    "label": body[:70],
                    "hint": text_hint,
                }
                # Another effort's structured delivery set is a fact about the corpus;
                # the text hints are a guess from this row's prose. When they disagree the
                # fact wins, and it demotes the one hint the caller is told to auto-repair.
                claimed = [
                    slug for slug in owners.get(
                        (owner.casefold(), repo.casefold(), number), [])
                    if slug != path.stem
                ]
                if claimed:
                    entry["hint"] = "sibling-delivery"
                    entry["text_hint"] = text_hint
                    entry["owned_by"] = claimed
                invisible.append(entry)

    structure = state.get("structure") or {}
    return {
        "effort": path.stem,
        "path": str(path),
        "status": state.get("status"),
        "stage": state.get("stage"),
        "delivery": delivery,
        "delivery_refs": sorted(delivery_cased),
        "structure": structure,
        "invisible": invisible,
        "refs": sorted(all_refs),
    }


def closed_findings(audits: list[dict], live: dict[str, dict], reverts: list[dict],
                    revert_scan_ran: bool, unscanned_repos: set[str]) -> list[dict]:
    """Defects in terminal effort docs, which nothing else re-reads.

    `/nase:efforts` counts `done/` and `archive/` without opening them, so a terminal doc
    is written once and never audited again. Two defects survive there indefinitely:

    `partial-delivery-unrecorded` - `status: wontfix` means "closed without shipping", and
    `/nase:effort-rollup` excludes those from the delivery record entirely. An effort whose
    code merged and deployed but whose *verdict* was dropped is filed the same way, so real
    shipped work disappears from the impact report. Recording `partial_delivery: true` keeps
    the status honest about the effort while letting the rollup count the PRs that landed.

    `no-lifecycle-section` - offline-provable, so `effort-state.py` already found it; it is
    surfaced here because this is the only pass that reads terminal docs at all.

    A merged PR is not shipped code. Two of the eight efforts this check first flagged on
    this workspace had their delivery PRs reverted on the forward line, and recording
    `partial_delivery` there would have inflated the rollup with work that was rolled back -
    the same ancestry blind spot, one layer up. So reverted PRs are split out, and when no
    local clone was available to look, the finding says the revert scan could not run rather
    than presenting merge state as delivery.
    """
    reverted = {r["pr"] for r in reverts}
    unscanned = {name.casefold() for name in unscanned_repos}
    findings: list[dict] = []
    for audit in audits:
        structure = audit.get("structure") or {}
        for defect in structure.get("defects", []):
            findings.append({"effort": audit["effort"], "path": audit.get("path"),
                             "defect": defect, "standing": [], "reverted": []})
        if audit.get("status") != "wontfix" or structure.get("partial_delivery") is True:
            continue
        merged = [
            (repo, f"{owner}/{repo}#{number}")
            for owner, repo, number in audit.get("delivery_refs", [])
            if live.get(f"{owner}/{repo}#{number}", {}).get("state") == "MERGED"
        ]
        if not merged:
            continue
        rolled_back = [pr for _, pr in merged if pr in reverted]
        standing = [(repo, pr) for repo, pr in merged if pr not in reverted]
        if not standing:
            # Every merge was reverted: `wontfix` is the honest label and there is nothing
            # to record. Reported so the next reader does not re-derive the same question.
            defect = "reverted-delivery-no-repair"
        elif not revert_scan_ran or any(repo.casefold() in unscanned for repo, _ in standing):
            defect = "partial-delivery-unverified-revert-scan"
        else:
            defect = "partial-delivery-unrecorded"
        findings.append({"effort": audit["effort"], "path": audit.get("path"),
                         "defect": defect, "standing": [pr for _, pr in standing],
                         "reverted": rolled_back})
    return findings


def find_reverts(live: dict[str, dict], paths: dict[str, str],
                 unscanned: set[str]) -> list[dict]:
    """A revert leaves the original merge commit an ancestor forever, so containment stays
    true after the content is gone. Surface any commit whose subject reverts a PR number.

    Repo names resolve case-insensitively. `.local-paths` stores GitHub's casing
    (`Platform=`) while PR keys reach here in whatever case the citing doc used, and an
    exact-match lookup turns that mismatch into a silent clean result - the scan reports no
    reverts because it never ran. Repos with no local clone are collected in `unscanned` so
    the caller can say the check did not cover them instead of implying it passed.
    """
    lookup = {name.casefold(): path for name, path in paths.items()}
    out = []
    for key, payload in live.items():
        sha = payload.get("mergeCommit")
        if payload.get("state") != "MERGED" or not sha:
            continue
        owner_repo, _, number = key.partition("#")
        repo_name = owner_repo.split("/")[-1]
        repo_path = lookup.get(repo_name.casefold())
        if not repo_path:
            unscanned.add(repo_name)
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


def print_closed_defects(findings: list[dict], revert_scan_ran: bool,
                         unscanned_repos: set[str]) -> None:
    if not findings:
        print("no terminal-doc defects\n")
        return
    print("terminal-doc defects:")
    for f in findings:
        print(f"    {f['defect']:38} {f['effort']}")
        if f["standing"]:
            print(f"        standing: {', '.join(f['standing'])}")
        if f["reverted"]:
            print(f"        reverted: {', '.join(f['reverted'])}")
    if not revert_scan_ran:
        print("\n    NOTE: the revert scan did not run (no local clone resolved), so a")
        print("    merged PR here is not proof the content is in the build.")
    elif unscanned_repos:
        print(f"\n    NOTE: no local clone for {', '.join(sorted(unscanned_repos))} -")
        print("    their PRs could not be revert-checked and read as unverified.")
    print("\n    partial-delivery-unrecorded: the effort is filed `wontfix` (closed")
    print("    without shipping) but those delivery PRs merged and stand, so")
    print("    /nase:effort-rollup drops real shipped work from the delivery record.")
    print("    Add `partial_delivery: true` and list the standing PRs; leave `status`")
    print("    alone unless deploy validation actually passed.")
    print("    reverted-delivery-no-repair: every merge was reverted. `wontfix` is")
    print("    correct and there is nothing to record - reported so the next reader")
    print("    does not re-derive it from merge state alone.")
    print("    partial-delivery-unverified-revert-scan: the merges stand as far as")
    print("    `gh` can tell, but no clone was available to look for a revert. Grep a")
    print("    symbol the PR ADDED at the ring commit before recording delivery.")
    print("    no-lifecycle-section: the doc carries no canonical rows, so no evidence")
    print("    can ever contradict its frontmatter. Add a `## Lifecycle` block.\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--efforts-dir", default="workspace/efforts")
    ap.add_argument("--file", help="audit a single effort file instead of the whole directory")
    ap.add_argument("--no-live", action="store_true",
                    help="skip gh reads; label audit only (offline, fast)")
    ap.add_argument("--check-reverts", action="store_true",
                    help="look for revert commits naming each merged PR (needs a local clone)")
    ap.add_argument("--closed", action="store_true",
                    help="audit terminal docs (done/ + archive/) instead of active efforts")
    ap.add_argument("--format", choices=["human", "json"], default="human")
    args = ap.parse_args()

    base = Path(args.efforts_dir)
    if not base.is_absolute():
        base = REPO_ROOT / base

    if args.file:
        files = [Path(args.file)]
    elif args.closed:
        files = sorted({*base.glob("done/*.md"), *base.glob("archive/*/*.md")})
    else:
        files = sorted(base.glob("*.md"))
    if not files:
        print("no effort files found", file=sys.stderr)
        return 0

    # Ownership spans the whole corpus even when the audit does not: a closed effort still
    # owns its delivery PRs, and an active doc citing one is citing someone else's work.
    states = corpus_states(corpus_files(base))
    owners = delivery_owners(states)

    # Both of these serve the row scan and the ownership map, and `--closed` emits
    # neither, so they stay unread there rather than sweeping 189 docs for nothing.
    known_owners: frozenset[str] = frozenset()
    cited_anywhere: set[tuple[str, str, int]] = set()
    if not args.closed:
        texts = [path.read_text() for path in files]
        known_owners = frozenset(m[0] for text in texts for m in PR_URL_RE.findall(text))
        # Every PR the audited docs name anywhere, prose included. The emitted ownership
        # map is narrowed to these: a caller can only attribute a citation it can see, and
        # shipping the whole corpus map costs ~4k tokens per run of every caller that
        # reads this output.
        cited_anywhere = {
            (owner.casefold(), repo.casefold(), number)
            for text in texts
            for owner, repo, number in cited_prs(text, known_owners)
        }

    # `--file` can name a doc outside the efforts directory, which the corpus read never
    # covered, so that one falls back to its own read.
    with ThreadPoolExecutor(max_workers=8) as pool:
        audits = list(pool.map(
            lambda p: audit_effort(p, known_owners, owners, not args.closed,
                                   states[p] if p in states else effort_state(p)),
            files))

    all_refs: set[tuple[str, str, int]] = set()
    for a in audits:
        # The closed audit only asks whether the *delivery* PRs merged. Reading every PR
        # cited anywhere across 189 terminal docs would be an order of magnitude more `gh`
        # calls for state no finding consults.
        all_refs.update(a.get("delivery_refs", []) if args.closed else a.get("refs", []))

    live: dict[str, dict] = {}
    if not args.no_live and all_refs:
        with ThreadPoolExecutor(max_workers=10) as pool:
            for key, payload in pool.map(read_pr, sorted(all_refs)):
                live[key] = payload

    # `--closed` implies revert checking: its whole output is "this merged, record it as
    # delivered", and a reverted merge would turn that into a false delivery claim.
    paths = local_paths() if (args.check_reverts or args.closed) else {}
    reverts: list[dict] = []
    unscanned_repos: set[str] = set()
    revert_scan_ran = bool(paths) and bool(live)
    if revert_scan_ran:
        reverts = find_reverts(live, paths, unscanned_repos)

    findings = (closed_findings(audits, live, reverts, revert_scan_ran, unscanned_repos)
                if args.closed else [])

    if args.closed:
        # `effort-doc-audit.md -> Part 2` acts on `findings` alone. The active-mode payload
        # is 189 audits plus every delivery PR's live record - ~200KB the caller reads to
        # use 400 bytes of it, and each finding already carries its own PR lists.
        result = {
            "findings": findings,
            "reverts": reverts,
            "counts": {"terminal_docs": len(audits), "delivery_prs": len(all_refs),
                       "defects": len(findings)},
        }
    else:
        # `delivery_owners` is emitted as a lookup, not just as row annotations. The row
        # scan only sees checkbox lines, but a caller attributing a PR usually read it out
        # of prose - a Context paragraph, a validation note, a grill observation. Those
        # citations are the ones that get mistaken for delivery.
        result = {
            "efforts": audits,
            "live": live,
            "reverts": reverts,
            "delivery_owners": {
                f"{o}/{r}#{n}": slugs
                for (o, r, n), slugs in sorted(owners.items())
                if (o, r, n) in cited_anywhere
            },
        }

    if args.format == "json":
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0

    flagged = [a for a in audits if a.get("invisible")]
    if args.closed:
        print(f"== effort-pr-sweep --closed: {len(audits)} terminal docs, "
              f"{len(all_refs)} delivery PRs, {len(findings)} defects ==\n")
        print_closed_defects(findings, revert_scan_ran, unscanned_repos)
    else:
        print(f"== effort-pr-sweep: {len(audits)} efforts, {len(all_refs)} unique PRs, "
              f"{len(flagged)} with an invisible PR ==\n")

    if live:
        unreadable = [k for k, v in live.items() if v.get("state") == "UNREADABLE"]
        open_prs = sorted(k for k, v in live.items() if v.get("state") == "OPEN")
        print(f"live: {len(live)} read, {len(open_prs)} OPEN, {len(unreadable)} unreadable")
        for key in open_prs:
            v = live[key]
            extra = (
                f" fail={v.get('failingCount', len(v['failing']))}"
                f" pend={v.get('pendingCount', len(v['pending']))}"
                if v.get("checks")
                else ""
            )
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

    # The row scan does not run under `--closed`, so there is no invisible set to report
    # and no "none found" line to mistake for a clean audit of one.
    if args.closed:
        return 0

    if flagged:
        print("invisible to the delivery set - classify each, do not bulk-relabel:")
        for a in flagged:
            print(f"  {a['effort']}   delivery={a['delivery']}")
            for item in a["invisible"]:
                print(f"    L{item['line']:<5} {item['pr']:34} [{item['hint']}]")
                print(f"          label: {item['label']}")
                if item.get("owned_by"):
                    print(f"          owned by: {', '.join(item['owned_by'])}"
                          f"   (text hint was {item.get('text_hint')})")
        print("\n    `likely-delivery` is the actionable class: give the row the canonical")
        print("    `PR opened` label and keep its own number in the body, e.g.")
        print("    `- [x] PR opened — **PR-2** — <url>`. The other hints are usually correct")
        print("    exclusions - relabelling them can fire a transition on evidence that is")
        print("    not this effort's delivery.")
        print("    `sibling-delivery` is never actionable: another effort's delivery set")
        print("    already claims that PR, so this row cites it as context. Relabelling it")
        print("    would transition this effort on another effort's evidence.")
    else:
        print("no invisible delivery PRs")

    return 0


if __name__ == "__main__":
    sys.exit(main())
