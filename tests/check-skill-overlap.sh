#!/usr/bin/env bash
#
# check-skill-overlap.sh - Flag nase skills whose trigger surface (frontmatter
# `description:`) substantially overlaps another skill's.
#
# Why: CLAUDE.md requires new skills to justify why they are not "overlapping
# trigger clones" of an existing skill, and prefers deterministic enforcement
# over prompt-only rules. The model routes `/nase:*` invocations off the
# `description` field, so two skills with colliding trigger phrasing misroute.
# This adds an advisory CI signal by comparing descriptions
# pairwise with k=2 word-shingle Jaccard similarity.
#
# What it compares: the `description:` frontmatter of core commands
# (.claude/commands/nase/*.md) plus workspace skill sources
# (workspace/skills/*.md). The generated mirror .claude/commands/nase/workspace/*
# is excluded because it is a byte copy of workspace/skills/* and would self-match 100%.
#
# Usage:
#   bash tests/check-skill-overlap.sh              # audit: every skill vs every other
#   bash tests/check-skill-overlap.sh FILE [FILE…] # check changed files vs the corpus
#
# Exit status:
#   0  scan completed; overlaps are advisory warnings
#   2  python3 missing
#
# Tunables (env):
#   SKILL_OVERLAP_WARN  default 12  - at/above this %, surfaced for human review
#
# Calibration (2026-07-20, 54 skills): the closest legitimate pair is
# effort-rollup vs efforts at 9.1% (k=2); every other pair scores <=6.5%. WARN
# at 12% surfaces anything above the established norm. This lexical heuristic
# cannot prove semantic equivalence; the authoring contract's human review stays authoritative.

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: python3 is required for the skill-overlap check." >&2
  exit 2
}

SKILL_OVERLAP_WARN="${SKILL_OVERLAP_WARN:-12}" \
ROOT="$ROOT" \
python3 - "$@" <<'PYEOF'
import glob
import os
import re
import sys

ROOT = os.environ["ROOT"]
WARN = float(os.environ["SKILL_OVERLAP_WARN"])
K = 2

sys.path.insert(0, os.path.join(ROOT, "tests", "lib"))
from frontmatter import description_from_frontmatter

# Boilerplate trigger scaffolding shared verbatim across unrelated descriptions
# ("Use X for a, b; not for c"). Neutralize so structure, not content, is scored.
NEUTRAL = re.compile(
    r'\b(use|for|the|a|an|of|to|and|or|with|via|from|on|in|not|only|when|before|'
    r'after|nase|workspace|skill|skills|run)\b')


def get_desc(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return description_from_frontmatter(fh.read()) or None
    except OSError:
        return None


def tokens(text):
    text = NEUTRAL.sub(' ', text.lower())
    text = re.sub(r'[^a-z0-9 ]', ' ', text)
    return text.split()


def shingles(words):
    if len(words) < K:
        return set(words)
    return set(' '.join(words[i:i + K]) for i in range(len(words) - K + 1))


def jaccard(a, b):
    return len(a & b) / len(a | b) if a and b else 0.0


def rel(p):
    try:
        return os.path.relpath(p, ROOT)
    except ValueError:
        return p


# --- Build the corpus: description shingles keyed by absolute path ----------
corpus_files = sorted(
    glob.glob(os.path.join(ROOT, ".claude/commands/nase/*.md"))
    + glob.glob(os.path.join(ROOT, "workspace/skills/*.md"))
)
corpus = {}
for f in corpus_files:
    d = get_desc(f)
    if d:
        corpus[os.path.abspath(f)] = shingles(tokens(d))

if len(corpus) < 2:
    print("Fewer than 2 skills with a description; nothing to compare.")
    sys.exit(0)

# --- Candidates: given files, else every skill (audit) ----------------------
args = sys.argv[1:]
if args:
    candidates = []
    for a in args:
        p = os.path.abspath(a if os.path.isabs(a) else os.path.join(os.getcwd(), a))
        if not os.path.isfile(p):
            print(f"  skip (not found): {a}")
            continue
        desc = get_desc(p)
        if desc is None:
            print(f"  skip (no description frontmatter): {rel(p)}")
            continue
        corpus.setdefault(p, shingles(tokens(desc)))
        candidates.append(p)
    if not candidates:
        print("No skill files with a description to check.")
        sys.exit(0)
    pairs = [(c, o) for c in candidates for o in corpus if o != c]
else:
    keys = sorted(corpus)
    pairs = [(keys[i], keys[j]) for i in range(len(keys)) for j in range(i + 1, len(keys))]

# --- Score, keeping the single worst match per unordered pair ---------------
seen = set()
scored = []
for a, b in pairs:
    key = tuple(sorted((a, b)))
    if key in seen:
        continue
    seen.add(key)
    scored.append((jaccard(corpus[a], corpus[b]) * 100, rel(a), rel(b)))
scored.sort(reverse=True)

warns = [s for s in scored if s[0] >= WARN]

print(f"Compared {len(corpus)} skills; advisory WARN >= {WARN:.0f}%. Top matches:")
for pct, a, b in scored[:8]:
    tag = "WARN" if pct >= WARN else "ok  "
    print(f"  [{tag}] {pct:5.1f}%  {os.path.basename(a)}  <>  {os.path.basename(b)}")

if warns:
    print()
    print(f"WARNING: {len(warns)} skill pair(s) share notable trigger phrasing:")
    for pct, a, b in warns:
        print(f"  - {a}  ~{pct:.0f}% like  {b}")
    print()
    print("Review these pairs against CLAUDE.md's anti-overlap rule. This lexical")
    print("signal is advisory and does not replace semantic review.")
print("\nPASSED")
sys.exit(0)
PYEOF
