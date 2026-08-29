#!/usr/bin/env python3
"""Lint an outbound English draft for LLM register and broken surface mechanics.

Two classes of finding, deliberately separated:

`gate`   Mechanical defects with a concrete failure and near-zero false-positive
         rate - a Slack embed link that renders wrong, a review comment with no
         file anchor, a bot-reply courtesy opener. These fail the run.

`marker` Register, vocabulary, and template signals. No single one is decisive;
         co-occurrence is what a reader registers. These are counted by tier and
         judged against a threshold, never individually.

Patterns a regex cannot see - symmetric section arcs, build-up/reveal paragraph
templates, whether the draft says anything - stay with the model's own pass.

This counts patterns. It is not evidence of authorship, in either direction, and
must never be used as one. See `.claude/docs/plain-writing-guard.md` Part 5.

Marker vocabulary decays once it is published. Rules dated 2026-08-28; re-measure
against current corpora by 2027-02 rather than treating the list as permanent.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from typing import Callable

SURFACES = (
    "slack-dm",
    "slack-channel",
    "github-pr-body",
    "github-review-comment",
    "github-review-reply",
    "jira-ticket",
    "confluence-doc",
    "announcement",
)
SLACK = ("slack-dm", "slack-channel")
REVIEW = ("github-review-comment", "github-review-reply")
LONG_FORM = ("github-pr-body", "jira-ticket", "confluence-doc", "announcement")

TIERS = ("T1", "T2", "T3", "TEMPLATE", "SYNTAX")

# Built from code points so this file does not carry the character it flags.
EM_DASH = chr(0x2014)
EN_DASH = chr(0x2013)
EMOJI_RANGES = (
    f"{chr(0x1F300)}-{chr(0x1FAFF)}"
    f"{chr(0x2600)}-{chr(0x27BF)}"
    f"{chr(0x1F1E6)}-{chr(0x1F1FF)}"
)
BULLET = r"[-*•]"

VERDICTS = (
    (0, "clean on mechanical markers; the shape checks in Part 1 and Part 6 still apply"),
    (2, "acceptable; fix if cheap"),
    (5, "read it again - co-occurrence is what readers notice"),
    (10**9, "rewrite rather than patch; patched model prose keeps its shape"),
)


@dataclass
class Finding:
    line: int
    col: int
    kind: str
    rule: str
    tier: str
    matched: str
    message: str
    fix: str

    def as_dict(self) -> dict[str, object]:
        return {
            "line": self.line,
            "col": self.col,
            "kind": self.kind,
            "rule": self.rule,
            "tier": self.tier,
            "matched": self.matched,
            "message": self.message,
            "fix": self.fix,
        }


@dataclass
class Rule:
    rule_id: str
    kind: str
    tier: str
    surfaces: tuple[str, ...]
    message: str
    fix: str
    pattern: re.Pattern[str] | None = None
    checker: Callable[["Document", "Rule"], list[Finding]] | None = None


@dataclass
class Document:
    text: str
    masked: str
    surface: str
    line_starts: list[int] = field(default_factory=list)

    def position(self, offset: int) -> tuple[int, int]:
        lo, hi = 0, len(self.line_starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if self.line_starts[mid] <= offset:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1, offset - self.line_starts[lo] + 1

    def finding(self, rule: Rule, offset: int, matched: str) -> Finding:
        line, col = self.position(offset)
        return Finding(line, col, rule.kind, rule.rule_id, rule.tier, matched, rule.message, rule.fix)


# --- masking ---------------------------------------------------------------
# Fenced blocks, inline code, and URLs become spaces of equal length, so a pasted
# log or an identifier never trips a prose rule while offsets stay exact.
# Quoted prose from someone else is NOT masked - read the hits before acting.

_MASK_PATTERNS = (
    re.compile(r"^(```|~~~).*?^\1", re.DOTALL | re.MULTILINE),
    re.compile(r"`[^`\n]+`"),
    re.compile(r"<?https?://[^\s>|]+>?"),
)


def mask(text: str) -> str:
    masked = text
    for pattern in _MASK_PATTERNS:
        masked = pattern.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), masked)
    return masked


def build_document(text: str, surface: str) -> Document:
    starts = [0]
    for idx, ch in enumerate(text):
        if ch == "\n":
            starts.append(idx + 1)
    return Document(text=text, masked=mask(text), surface=surface, line_starts=starts)


# --- helpers ---------------------------------------------------------------


def _words(chunk: str) -> list[str]:
    return re.findall(r"[A-Za-z][A-Za-z'-]*", chunk)


def _paragraphs(doc: Document) -> list[tuple[int, str]]:
    """Blocks with their true offsets. A blank-line separator can be longer than
    two characters, so the offset has to come from the match, not from the block
    length, or every reported line number after the first drifts."""
    out: list[tuple[int, str]] = []
    pos = 0
    for separator in re.finditer(r"\n[ \t]*\n", doc.masked):
        out.append((pos, doc.masked[pos : separator.start()]))
        pos = separator.end()
    out.append((pos, doc.masked[pos:]))
    return out


def _sentence_lengths(doc: Document) -> list[int]:
    protected = re.sub(r"(\d)\.(\d)", r"\1@\2", doc.masked)
    lengths = []
    for piece in re.split(r"[.!?](?:\s|$)", protected):
        count = len(_words(piece))
        if count:
            lengths.append(count)
    return lengths


# --- computed checks -------------------------------------------------------


def check_nominalization(doc: Document, rule: Rule) -> list[Finding]:
    findings: list[Finding] = []
    for offset, para in _paragraphs(doc):
        words = _words(para)
        if len(words) < 60:
            continue
        hits = [w for w in words if re.search(r"\w{4,}(ment|tion|sion|ance|ence)$", w, re.I)]
        ratio = len(hits) / len(words)
        if ratio > 0.12:
            findings.append(doc.finding(rule, offset, f"{len(hits)}/{len(words)} words ({ratio:.0%})"))
    return findings


def check_no_short_sentence(doc: Document, rule: Rule) -> list[Finding]:
    lengths = _sentence_lengths(doc)
    if len(lengths) < 3 or any(n <= 8 for n in lengths):
        return []
    return [doc.finding(rule, 0, f"{len(lengths)} sentences, shortest is {min(lengths)} words")]


def check_uniform_sentence_length(doc: Document, rule: Rule) -> list[Finding]:
    lengths = _sentence_lengths(doc)
    if len(lengths) < 3 or max(lengths) - min(lengths) >= 8:
        return []
    if max(lengths) < 12:
        # A run of uniformly short sentences is terse writing, not model cadence.
        return []
    return [doc.finding(rule, 0, f"sentence lengths {min(lengths)}-{max(lengths)} words")]


_TRIAD = re.compile(r"\b([a-z]{4,}), ([a-z]{4,}),? and ([a-z]{4,})\b")


def check_triad(doc: Document, rule: Rule) -> list[Finding]:
    return [doc.finding(rule, m.start(), m.group(0)) for m in _TRIAD.finditer(doc.masked)]


_CONCRETE = (
    re.compile(r"\d"),
    re.compile(r"`"),
    re.compile(r"[A-Za-z]+[./][A-Za-z]"),
    re.compile(r"\b[a-z]+_[a-z]+\b"),
    re.compile(r"\b[a-z]+[A-Z][a-zA-Z]*\b"),
)
_MIDSENTENCE_CAPITAL = re.compile(r"(?<![.!?]\s)(?<!^)(?<!\n)\b[A-Z][a-zA-Z]{2,}\b")


def check_specificity(doc: Document, rule: Rule) -> list[Finding]:
    findings: list[Finding] = []
    for offset, para in _paragraphs(doc):
        stripped = para.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if len(_words(para)) < 25:
            continue
        raw = doc.text[offset : offset + len(para)]
        if any(p.search(raw) for p in _CONCRETE) or _MIDSENTENCE_CAPITAL.search(raw):
            continue
        findings.append(doc.finding(rule, offset, "paragraph with no name, number, path or id"))
    return findings


def check_review_anchor(doc: Document, rule: Rule) -> list[Finding]:
    if re.search(r"[\w./-]+\.\w{1,5}:\d+", doc.text):
        return []
    if re.search(
        r"[\w./-]+\.(cs|ts|tsx|js|jsx|py|sh|go|java|rb|rs|kt|yml|yaml|json|sql|md|ps1|bicep|tf)\b",
        doc.text,
    ):
        return []
    return [doc.finding(rule, 0, "(no file anchor anywhere in the comment)")]


_JIRA_SECTIONS = ("Context", "Scope", "Acceptance", "References")


def check_jira_sections(doc: Document, rule: Rule) -> list[Finding]:
    missing = [
        name for name in _JIRA_SECTIONS if not re.search(rf"^#{{1,4}}\s*{name}\b", doc.text, re.I | re.M)
    ]
    if not missing:
        return []
    return [doc.finding(rule, 0, f"missing: {', '.join(missing)}")]


def check_long_paragraph(doc: Document, rule: Rule) -> list[Finding]:
    findings: list[Finding] = []
    run: list[int] = []
    offsets: list[int] = []
    cursor = 0
    for idx, raw in enumerate(doc.masked.split("\n"), start=1):
        line = raw.strip()
        if line and not re.match(rf"^({BULLET}|\d+\.|#|\||>)", line):
            run.append(idx)
            offsets.append(cursor)
        else:
            if len(run) > 7:
                findings.append(doc.finding(rule, offsets[0], f"{len(run)} lines"))
            run, offsets = [], []
        cursor += len(raw) + 1
    if len(run) > 7:
        findings.append(doc.finding(rule, offsets[0], f"{len(run)} lines"))
    return findings


def check_trailing_url(doc: Document, rule: Rule) -> list[Finding]:
    """Flag a bare URL at end of line only when the *immediately* following line
    is non-empty. `slack-draft-style.md` Formatting Mechanics treats a blank line
    after the URL as a valid boundary that survives the draft conversion."""
    lines = doc.text.split("\n")
    findings: list[Finding] = []
    offset = 0
    for idx, line in enumerate(lines):
        following = lines[idx + 1] if idx + 1 < len(lines) else ""
        if re.search(r"https?://\S+\s*$", line) and following.strip():
            findings.append(doc.finding(rule, offset, line.strip()[-60:]))
        offset += len(line) + 1
    return findings


# --- vocabulary ------------------------------------------------------------

TIER1 = (
    (r"delv(e|es|ed|ing)", "look at / dig into"),
    (r"deep dive", "look at"),
    (r"underscor(e|es|ed|ing)", "show / confirm"),
    (r"showcas(e|es|ed|ing)", "show"),
    (r"boasts", "has"),
    (r"garner(s|ed|ing)?", "get"),
    (r"intricate|intricacies", "say what makes it complex"),
    (r"surpass(es|ed|ing)?", "beat / exceed"),
    (r"realm", "drop"),
    (r"groundbreaking", "drop, or give the number"),
    (r"advancements", "changes / releases"),
    (r"align(s)? with", "match"),
    (r"emphasizing", "drop"),
    (r"crucial", "say why it matters"),
    (r"pivotal", "key"),
    (r"seamless(ly)?", "drop, or say what no longer breaks"),
    (r"nuanced", "state the distinction itself"),
    (r"leveraging", "using"),
    (r"meticulous(ly)?", "drop"),
    (r"tapestr(y|ies)", "drop the metaphor"),
    (r"testament", "state the fact it is evidence of"),
    (r"palpable", "drop"),
    (r"camaraderie", "drop"),
    (r"amidst", "among / during"),
    (r"foster(s|ed|ing)?", "support / cause"),
    (r"bolster(s|ed|ing)?", "strengthen"),
    (r"interplay", "name the two things and how they interact"),
    (r"landscape", "drop when figurative"),
    (r"vibrant", "drop, or name the concrete property"),
    (r"enduring", "drop"),
    (r"holistic", "drop"),
    (r"transformative", "say what changed"),
)

TIER2 = (
    (r"leverag(e|es|ed)", "use / build on"),
    (r"utiliz(e|es|ed|ing)", "use"),
    (r"commenc(e|es|ed|ing)", "start"),
    (r"unpack(s|ed|ing)?", "explain"),
    (r"in order to", "to"),
    (r"allows? you to", "lets you"),
    (r"please note", "delete"),
    (r"easily|simply", "delete - it is not easy for everyone"),
)

TIER3 = (
    (r"absolutely|completely|totally|really|quite|very", "delete"),
    (r"robust", "name the property (retries? bounded latency?)"),
    (r"valuable", "say what it is worth"),
    (r"enhanc(e|es|ed|ing)", "improve, and say by how much"),
    (r"highlight(s|ed|ing)?", "show"),
)

TEMPLATES = (
    (r"\bin conclusion\b", "delete; the point is already made"),
    (r"\boverall,", "delete"),
    (r"\bi hope this helps\b", "delete"),
    (r"\blet me know if you have any questions\b", "delete"),
    (r"\bhappy to help\b", "delete"),
    (r"\bgreat question\b", "delete"),
    (r"\bit'?s worth noting( that)?\b|\bit is important to note\b", "verify the claim, then state it directly"),
    (r"\bgenerally speaking\b", "delete"),
    (r"\bnot just\b[^.!?\n]{0,80}?\bbut\b", "keep only the second half"),
    (r"\bnot only\b[^.!?\n]{0,80}?\bbut\b", "keep only the second half"),
    (r"\bit'?s not\b[^.!?\n]{0,80}?,\s*it'?s\b", "assert the point directly"),
    (r"\bno \w+, no \w+, just\b", "assert the point directly"),
    (r"\bplays a (crucial|pivotal|key) role\b", "say what it does"),
    (r"\bstands as a testament\b", "state the fact"),
    (r"\bgame[- ]chang(er|ing)\b", "say what changed"),
    (r"\bexperts (argue|agree|say)\b|\bindustry reports suggest\b|\bit is widely recognized\b",
     "name the source or drop the sentence"),
    (r"^\s*(Certainly|Moreover|Additionally|Furthermore|In essence|Ultimately)\b[,:]?", "delete the opener"),
)


def _vocab_rules() -> list[Rule]:
    rules: list[Rule] = []
    for tier, table, label in (
        ("T1", TIER1, "corpus-measured excess vocabulary"),
        ("T2", TIER2, "house-style ban"),
        ("T3", TIER3, "empty intensifier"),
    ):
        for stem, fix in table:
            rules.append(
                Rule(f"REG-{tier}", "marker", tier, SURFACES, label, fix, re.compile(rf"\b(?:{stem})\b", re.I))
            )
    for stem, fix in TEMPLATES:
        flags = re.I | re.M if stem.startswith("^") else re.I
        rules.append(Rule("TPL", "marker", "TEMPLATE", SURFACES, "templated shape", fix, re.compile(stem, flags)))
    return rules


# --- rule table ------------------------------------------------------------

RULES: list[Rule] = _vocab_rules() + [
    Rule(
        "SYN-ING",
        "marker",
        "SYNTAX",
        SURFACES,
        "trailing participial clause (~5x the human rate, Cohen's d=1.38)",
        "make it a full sentence, or delete it",
        re.compile(
            r",\s+(highlighting|underscoring|emphasizing|showcasing|resonating with|fostering|"
            r"bolstering|exemplifying|ensuring|reflecting|contributing to|paving the way|enabling|"
            r"allowing)\b",
            re.I,
        ),
    ),
    Rule(
        "SYN-NOM",
        "marker",
        "SYNTAX",
        LONG_FORM,
        "nominalization density (~2x the human rate, Cohen's d=1.23)",
        "turn the -tion/-ment nouns back into verbs",
        checker=check_nominalization,
    ),
    Rule(
        "SYN-THAT",
        "marker",
        "SYNTAX",
        SURFACES,
        "that-clause as subject (~2.6x the human rate)",
        "rewrite as `X happened, which suggests ...`",
        re.compile(r"(?:^|(?<=[.!?]\s))\s*That the \w+", re.M),
    ),
    Rule(
        "SYN-SHORT",
        "marker",
        "SYNTAX",
        SURFACES,
        "no short sentence; model output rarely has one, human writing usually does",
        "add a sentence of eight words or fewer",
        checker=check_no_short_sentence,
    ),
    Rule(
        "SYN-UNIFORM",
        "marker",
        "SYNTAX",
        SURFACES,
        "uniform sentence length",
        "break the run with a short sentence, or merge two",
        checker=check_uniform_sentence_length,
    ),
    Rule(
        "TPL-TRIAD",
        "marker",
        "TEMPLATE",
        SURFACES,
        "three-item cadence",
        "cut to two, or add a fourth that carries new information",
        checker=check_triad,
    ),
    Rule(
        "TPL-AGENCY",
        "marker",
        "TEMPLATE",
        SURFACES,
        "false agency (human verb on an inanimate subject)",
        "name the actor, or address the reader as `you`",
        re.compile(
            r"\bthe (data|market|culture|conversation|decision|system|code|architecture|industry|"
            r"landscape) (tells|rewards|shifts|moves|decides|wants|knows|emerges|demands|suggests)\b",
            re.I,
        ),
    ),
    Rule(
        "SPEC",
        "marker",
        "SYNTAX",
        SURFACES,
        "paragraph carries no concrete referent - the one cue trained readers still use",
        "add a name, number, path or id, or delete the paragraph",
        checker=check_specificity,
    ),
    # --- gates: mechanical, concrete failure, near-zero false positives ---
    Rule(
        "FMT-DASH",
        "gate",
        "",
        SURFACES,
        "em/en dash (house ban; not evidence of authorship in either direction)",
        "use a plain dash, comma, period, colon or parentheses",
        re.compile(f"[{EM_DASH}{EN_DASH}]"),
    ),
    Rule(
        "FMT-BOLDDEF",
        "gate",
        "",
        SURFACES,
        "bold-term definition list",
        "write it as a sentence, or use a real table",
        re.compile(rf"^\s*{BULLET}\s*\*\*[^*\n]+\*\*\s*:", re.M),
    ),
    Rule(
        "FMT-EMOJI",
        "gate",
        "",
        SURFACES,
        "emoji-led bullet",
        "delete the emoji; lead with the noun",
        re.compile(rf"^\s*{BULLET}\s*(:[a-z0-9_+-]+:|[{EMOJI_RANGES}])", re.M),
    ),
    Rule(
        "SLK-EMBED",
        "gate",
        "",
        SLACK,
        "Slack link embed",
        "paste the bare URL",
        re.compile(r"<https?://[^>\s]+\|[^>]*>"),
    ),
    Rule(
        "SLK-TRAILURL",
        "gate",
        "",
        SLACK,
        "bare URL ends a line that has content after it; Slack autolink swallows the next line",
        "move the URL into the middle of the sentence",
        checker=check_trailing_url,
    ),
    Rule(
        "SLK-BULLET",
        "gate",
        "",
        SLACK,
        "literal bullet character; it is plain text and never renders as a list",
        "write `- item`, per slack-draft-style.md Formatting Mechanics",
        re.compile(r"^\s*•", re.M),
    ),
    Rule(
        "REV-ANCHOR",
        "gate",
        "",
        ("github-review-comment",),
        "no file anchor; file-level comments go unaddressed 87.0% of the time against 51.9% hunk-level",
        "anchor the comment to `path:line`",
        checker=check_review_anchor,
    ),
    Rule(
        "REV-VAGUE",
        "gate",
        "",
        REVIEW,
        "non-actionable suggestion",
        "name the concrete change you want",
        re.compile(
            r"\b(consider improving|test(ing)? (this )?thoroughly|make sure to|it would be good to|"
            r"it might be worth|as appropriate|where appropriate|consider adding more)\b",
            re.I,
        ),
    ),
    Rule(
        "REV-YOU",
        "gate",
        "",
        REVIEW,
        "second-person interrogation; comment on the code, never the developer",
        "state the problem the code has",
        re.compile(r"\bwhy (did|do|would) you\b", re.I),
    ),
    Rule(
        "REV-COURTESY",
        "gate",
        "",
        REVIEW,
        "courtesy opener; drop it when replying to a bot reviewer, which cannot read tone",
        "open on the finding",
        re.compile(
            r"^\s*(Good catch|Nice catch|Great catch|Good job|Nice work|"
            r"Thanks for (bringing this up|catching|flagging))\b",
            re.I | re.M,
        ),
    ),
    Rule(
        "JIR-SECTIONS",
        "gate",
        "",
        ("jira-ticket",),
        "missing ticket section",
        "add Context / Scope / Acceptance / References so the ticket works without chat history",
        checker=check_jira_sections,
    ),
    Rule(
        "CFL-PARA",
        "marker",
        "SYNTAX",
        ("confluence-doc", "announcement"),
        "paragraph longer than seven lines",
        "split it; three to seven lines is the target",
        checker=check_long_paragraph,
    ),
]


def lint(text: str, surface: str) -> list[Finding]:
    doc = build_document(text, surface)
    findings: list[Finding] = []
    for rule in RULES:
        if surface not in rule.surfaces:
            continue
        if rule.checker is not None:
            findings.extend(rule.checker(doc, rule))
            continue
        assert rule.pattern is not None
        for match in rule.pattern.finditer(doc.masked):
            findings.append(doc.finding(rule, match.start(), doc.text[match.start() : match.end()].strip()))
    findings.sort(key=lambda f: (f.kind != "gate", f.line, f.col, f.rule))
    return findings


def verdict_for(total: int) -> str:
    for ceiling, text in VERDICTS:
        if total <= ceiling:
            return text
    return VERDICTS[-1][1]


def summarize(findings: list[Finding]) -> dict[str, object]:
    gates = [f for f in findings if f.kind == "gate"]
    markers = [f for f in findings if f.kind == "marker"]
    by_tier = {tier: sum(1 for f in markers if f.tier == tier) for tier in TIERS}
    return {
        "gates": len(gates),
        "markers": len(markers),
        "by_tier": by_tier,
        "verdict": verdict_for(len(markers)),
    }


def render_human(findings: list[Finding], surface: str, threshold: int) -> str:
    summary = summarize(findings)
    out = [f"== prose-lint: {surface} =="]
    gates = [f for f in findings if f.kind == "gate"]
    markers = [f for f in findings if f.kind == "marker"]

    out.append("")
    out.append(f"Gates (must fix): {len(gates)}")
    for f in gates:
        out.append(f"  {f.line}:{f.col} {f.rule}  {f.matched}")
        out.append(f"      {f.message}")
        out.append(f"      fix: {f.fix}")

    out.append("")
    out.append(f"Markers (counted, not individually decisive): {len(markers)}")
    for tier in TIERS:
        rows = [f for f in markers if f.tier == tier]
        if not rows:
            continue
        out.append(f"  {tier}: {len(rows)}")
        for f in rows:
            out.append(f"      {f.line}:{f.col} {f.matched}  -> {f.fix}")

    out.append("")
    out.append(f"Markers: {summary['verdict']}")
    if gates:
        out.append(f"Result: FAIL - {len(gates)} gate finding(s) must be fixed.")
    elif len(markers) > threshold:
        out.append(f"Result: FAIL - {len(markers)} markers, threshold is {threshold}.")
    else:
        out.append(f"Result: PASS - {len(markers)} markers, threshold is {threshold}.")
    out.append("")
    out.append("This counts patterns. It is not evidence of authorship, in either direction.")
    return "\n".join(out)


def list_rules() -> str:
    seen: dict[str, Rule] = {}
    for rule in RULES:
        seen.setdefault(rule.rule_id, rule)
    rows = ["rule\tkind\ttier\tsurfaces\tmessage"]
    for rule_id, rule in sorted(seen.items()):
        scope = "*" if rule.surfaces == SURFACES else ",".join(rule.surfaces)
        rows.append(f"{rule_id}\t{rule.kind}\t{rule.tier or '-'}\t{scope}\t{rule.message}")
    return "\n".join(rows)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Lint an outbound draft.")
    parser.add_argument("--surface", choices=SURFACES)
    parser.add_argument("--file", help="path to the draft, or - for stdin")
    parser.add_argument("--format", choices=("human", "json"), default="human")
    parser.add_argument("--threshold", type=int, default=5, help="marker count above which the run fails")
    parser.add_argument("--list-rules", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.list_rules:
        print(list_rules())
        return 0
    if not args.surface or not args.file:
        print("prose-lint: --surface and --file are required", file=sys.stderr)
        return 2
    if args.file == "-":
        text = sys.stdin.read()
    else:
        try:
            with open(args.file, encoding="utf-8") as handle:
                text = handle.read()
        except OSError as exc:
            print(f"prose-lint: cannot read {args.file}: {exc}", file=sys.stderr)
            return 2

    findings = lint(text, args.surface)
    summary = summarize(findings)
    if args.format == "json":
        print(
            json.dumps(
                {
                    "surface": args.surface,
                    "summary": summary,
                    "findings": [f.as_dict() for f in findings],
                },
                indent=2,
            )
        )
    else:
        print(render_human(findings, args.surface, args.threshold))
    return 1 if summary["gates"] or summary["markers"] > args.threshold else 0


if __name__ == "__main__":
    sys.exit(main())
