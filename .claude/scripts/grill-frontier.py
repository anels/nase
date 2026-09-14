#!/usr/bin/env python3
"""Resolve the grill branch graph: validate it, apply the cap, compute the frontier.

`/nase:design --grill` maintains a dependency graph of open decisions and, per round,
has to answer four questions about it: are the `depends_on` ids real and acyclic; which
15 branches survive the cap without orphaning a prerequisite; which unresolved branches
have all prerequisites resolved (the frontier); and which branches a deferral drags out
with it. `design-grill-mode.md` specifies all four in prose and asks for them again after
every persona fold-in and every round - cycle detection, transitive closure, a
dependency-closed cap, and a running budget, re-executed by hand each time with nothing
checking the result.

Input is the branch list as JSON on stdin; output is the round's decision as JSON.

    {"branches": [{"id": "b1", "depends_on": [], "load_bearing": true}, ...],
     "resolved": ["b1"], "deferred": ["b7"],
     "cap": 15, "budget_total": 25, "budget_spent": 3}

Only `id` is required per branch; every other field is carried through untouched so the
caller can keep topic/persona/why-it-matters on the same objects.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

DEFAULT_CAP = 15
DEFAULT_BUDGET = 25


class GraphError(Exception):
    """The branch graph cannot be interpreted; the caller must fix it, not guess."""


def _branch_id(branch: Any, index: int) -> str:
    if not isinstance(branch, dict):
        raise GraphError(f"branches[{index}] must be an object")
    raw = branch.get("id")
    if not isinstance(raw, str) or not raw.strip():
        raise GraphError(f"branches[{index}] has no usable id")
    return raw.strip()


def _depends_on(branch: dict[str, Any], branch_id: str) -> list[str]:
    raw = branch.get("depends_on", [])
    if raw is None:
        return []
    if not isinstance(raw, list):
        raise GraphError(f"{branch_id}.depends_on must be a list")
    out = []
    for item in raw:
        if not isinstance(item, str) or not item.strip():
            raise GraphError(f"{branch_id}.depends_on contains a non-id entry")
        out.append(item.strip())
    return out


def parse_graph(payload: dict[str, Any]) -> dict[str, dict[str, Any]]:
    raw = payload.get("branches")
    if not isinstance(raw, list):
        raise GraphError("branches must be a list")
    graph: dict[str, dict[str, Any]] = {}
    for index, branch in enumerate(raw):
        branch_id = _branch_id(branch, index)
        if branch_id in graph:
            raise GraphError(f"duplicate branch id: {branch_id}")
        graph[branch_id] = dict(branch, id=branch_id)
    for branch_id, branch in graph.items():
        deps = _depends_on(branch, branch_id)
        if branch_id in deps:
            raise GraphError(f"{branch_id} depends on itself")
        missing = [dep for dep in deps if dep not in graph]
        if missing:
            raise GraphError(f"{branch_id} depends on unknown id(s): {', '.join(sorted(missing))}")
        branch["depends_on"] = deps
    return graph


def find_cycle(graph: dict[str, dict[str, Any]]) -> list[str] | None:
    """One concrete cycle, so the error names the branches to fix."""
    done: set[str] = set()
    stack: list[str] = []

    def walk(node: str) -> list[str] | None:
        stack.append(node)
        for dep in graph[node]["depends_on"]:
            if dep in stack:
                return [*stack[stack.index(dep) :], dep]
            if dep not in done:
                found = walk(dep)
                if found:
                    return found
        stack.pop()
        done.add(node)
        return None

    for node in graph:
        if node not in done:
            found = walk(node)
            if found:
                return found
    return None


def prerequisite_closure(
    graph: dict[str, dict[str, Any]], node: str, resolved: set[str]
) -> set[str]:
    """`node` plus every still-open branch it transitively depends on.

    A resolved prerequisite is not a decision the round has to carry, so the walk
    stops there - otherwise the cap spends room re-admitting settled branches and
    they reappear on the frontier.
    """
    seen: set[str] = set()
    pending = [node]
    while pending:
        current = pending.pop()
        if current in seen or current in resolved:
            continue
        seen.add(current)
        pending.extend(graph[current]["depends_on"])
    return seen


def dependents_closure(graph: dict[str, dict[str, Any]], nodes: set[str]) -> set[str]:
    """Every branch that transitively depends on any of `nodes`, excluding them."""
    reverse: dict[str, list[str]] = {node: [] for node in graph}
    for node, branch in graph.items():
        for dep in branch["depends_on"]:
            reverse[dep].append(node)
    seen: set[str] = set()
    pending = list(nodes)
    while pending:
        current = pending.pop()
        for dependent in reverse.get(current, []):
            if dependent not in seen:
                seen.add(dependent)
                pending.append(dependent)
    return seen - nodes


def apply_cap(
    graph: dict[str, dict[str, Any]],
    candidates: list[str],
    cap: int,
    resolved: set[str],
) -> tuple[list[str], list[str]]:
    """Keep at most `cap` branches, never orphaning a kept branch's prerequisites.

    Candidates arrive in priority order. A branch is admitted only when its whole
    prerequisite chain fits in the remaining room - taking a branch without its
    prerequisites would leave a decision that can never reach the frontier.
    """
    kept: set[str] = set()
    ordered: list[str] = []
    for node in candidates:
        if node in kept:
            continue
        closure = prerequisite_closure(graph, node, resolved)
        addition = closure - kept
        if len(kept) + len(addition) > cap:
            continue
        kept |= addition
        for member in sorted(addition, key=lambda item: (item not in candidates, item)):
            if member not in ordered:
                ordered.append(member)
    dropped = [node for node in candidates if node not in kept]
    # A dropped branch drags its dependents out with it; treating the missing
    # decision as settled is the failure this prevents.
    for dependent in dependents_closure(graph, set(dropped)):
        if dependent in kept:
            kept.discard(dependent)
            if dependent in ordered:
                ordered.remove(dependent)
            dropped.append(dependent)
    return ordered, dropped


def compute(payload: dict[str, Any]) -> dict[str, Any]:
    graph = parse_graph(payload)
    cycle = find_cycle(graph)
    if cycle:
        raise GraphError("dependency cycle: " + " -> ".join(cycle))

    resolved = {str(item) for item in payload.get("resolved") or []}
    deferred = {str(item) for item in payload.get("deferred") or []}
    unknown = (resolved | deferred) - set(graph)
    if unknown:
        raise GraphError(f"resolved/deferred names unknown id(s): {', '.join(sorted(unknown))}")

    cap = int(payload.get("cap") or DEFAULT_CAP)
    budget_total = int(payload.get("budget_total") or DEFAULT_BUDGET)
    budget_spent = int(payload.get("budget_spent") or 0)

    # A deferral is not a settled decision, so everything downstream of it leaves the
    # tree too and lands in `open_after_grill`.
    out_of_tree = deferred | (dependents_closure(graph, deferred) - resolved)
    open_after_grill = sorted(out_of_tree)

    candidates = [node for node in graph if node not in resolved and node not in out_of_tree]
    # Load-bearing first, then declaration order, per the doc's prioritisation.
    candidates.sort(
        key=lambda node: (not bool(graph[node].get("load_bearing")), list(graph).index(node))
    )
    kept, cap_dropped = apply_cap(graph, candidates, cap, resolved)

    frontier = [
        node for node in kept if all(dep in resolved for dep in graph[node]["depends_on"])
    ]
    blocked = [node for node in kept if node not in frontier]

    budget_remaining = max(0, budget_total - budget_spent)
    return {
        "frontier": [graph[node] for node in frontier],
        "frontier_ids": frontier,
        "blocked_ids": blocked,
        "kept_ids": sorted(kept),
        "cap_dropped_ids": sorted(set(cap_dropped)),
        "open_after_grill_ids": open_after_grill,
        "budget_remaining": budget_remaining,
        "ask_allowance": min(len(frontier), budget_remaining),
        "terminated": not frontier and not blocked,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--file",
        help="JSON input file; reads stdin when omitted",
    )
    args = parser.parse_args(argv)
    try:
        raw = Path(args.file).read_text(encoding="utf-8") if args.file else sys.stdin.read()
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            raise GraphError("input must be a JSON object")
        print(json.dumps(compute(payload), ensure_ascii=False, indent=2))
    except (GraphError, json.JSONDecodeError, OSError) as exc:
        print(f"grill-frontier: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
