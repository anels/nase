#!/usr/bin/env bash
# Enforce skill-authoring doctrine across .claude/commands/nase/ + workspace/skills/.
#
# FAILS on:
#   D1. curl-with-PAT for ADO endpoints (must use az CLI per feedback_ado-az-cli-only.md)
#   D2. mkdir line in init.md missing any workspace/kb/* subdir whose stub-write step follows
#   D3. files claiming "at HEAD" in a verifier role but greping the working tree without
#       `git show HEAD:` (regression guard for doc-pr-head-ground-scan.md)
#   D4. skill files missing a language preflight / language-config reference
#   D5. Codex MCP caller files missing the canonical prerequisite / clean-skip gate
#   D6. restore archive flow missing path traversal / symlink hardening
#   D7. kb-merge external import flow missing canonical path / symlink hardening
#   D8. kb-merge generated skill wrappers missing frontmatter sanitization
#   D9. core skill files missing architecture `pattern:` frontmatter
#   D10. durable workspace write skills missing workspace-write-guard.md
#   D11. auto-write modes allowed to skip drift checks
#   D12. /nase:today treats tech-digest as a proactive action instead of optional
#   D13. workspace/tmp artifact paths embed raw branch names that may contain slashes
#   D14. generated workspace wrapper descriptions exceed the session-start metadata cap
#   D15. critical KB-consuming workflows contain an explicit KB lookup marker
#   D16. workspace skill source descriptions exceed the wrapper metadata cap
#   D17. command frontmatter descriptions contain CJK trigger terms
#
# WARNS (does not fail) on:
#   W1. mutation-keyword skills (Slack/Jira/Confluence/ADO/GitHub PR writes) missing reference
#       to .claude/docs/external-mutation-policy.md
#
# Exit codes: 0 = no failures (warnings OK), N = N failure types tripped.
#
# Run from repo root:  bash tests/check-skill-doctrine.sh

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

# Skills under review
SKILL_DIRS=(.claude/commands/nase workspace/skills)

failed=0
warnings=0

red()    { printf '\033[31m%s\033[0m' "$1"; }
yellow() { printf '\033[33m%s\033[0m' "$1"; }
green()  { printf '\033[32m%s\033[0m' "$1"; }

section() { printf '\n--- %s ---\n' "$1"; }

skill_scan_text() {
  awk '
    /^```/ { in_code = !in_code; next }
    in_code { next }
    /^### Recommended profiles$/ { in_example_section = 1; next }
    /^### / && in_example_section { in_example_section = 0 }
    in_example_section { next }
    { print }
  ' "$1"
}

# ---------- D1: curl-with-PAT regression -----------------------------------
section "D1: no curl with ADO PAT"
# Pattern: curl ... -u ":$SOMETHING_PAT" OR curl ... -u ":$ADO_PAT" / $AZURE_DEVOPS_PAT etc.
# Join shell-continuation lines first so the common:
#   curl ... \
#     -u ":$ADO_PAT"
# form is caught too.
d1_hits=$(find "${SKILL_DIRS[@]}" -maxdepth 2 -name '*.md' -type f 2>/dev/null \
  | grep -v 'check-skill-doctrine.sh' \
  | while IFS= read -r f; do
      awk '
        {
          if (logical == "") start = FNR
          line = $0
          continued = (line ~ /\\[[:space:]]*$/)
          sub(/[[:space:]]*\\[[:space:]]*$/, "", line)
          logical = logical " " line
          if (!continued) {
            if (logical ~ /curl.*-u[[:space:]]*["\047]?:\$[A-Z_]*PAT/) {
              gsub(/^[[:space:]]+|[[:space:]]+$/, "", logical)
              printf "%s:%d:%s\n", FILENAME, start, logical
            }
            logical = ""
          }
        }
      ' "$f"
    done || true)
if [[ -n "$d1_hits" ]]; then
  red "FAIL"; printf ': curl-with-PAT found — use az CLI / az rest instead\n'
  printf '%s\n' "$d1_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': no curl-with-PAT\n'
fi

# ---------- D2: init.md mkdir covers every kb subdir we later write to -----
section "D2: init.md mkdir covers all kb stub-write targets"
INIT_MD=".claude/commands/nase/init.md"
if [[ ! -f "$INIT_MD" ]]; then
  red "FAIL"; printf ': %s missing — bootstrap skill vanished\n' "$INIT_MD"
  failed=$((failed+1))
else
  # Find every `workspace/kb/<subdir>[/<sub>]/<file>.md` that init.md attempts to create as a stub
  stub_subdirs=$(grep -oE 'workspace/kb/[a-z-]+(/[a-z-]+)?/[A-Za-z0-9._-]+\.md' "$INIT_MD" \
    | sed -E 's|/[A-Za-z0-9._-]+\.md$||' | sort -u)
  mkdir_line=$(grep -E '^[[:space:]]*mkdir -p' "$INIT_MD" | head -1 || true)
  d2_missing=""
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    case " $mkdir_line " in
      *" $d "*) ;;
      *)        d2_missing+="$d"$'\n' ;;
    esac
  done <<< "$stub_subdirs"
  if [[ -n "$d2_missing" ]]; then
    red "FAIL"; printf ': init.md mkdir missing these kb subdirs (stub-write would fail on first run):\n'
    printf '%s' "$d2_missing"
    failed=$((failed+1))
  else
    green "PASS"; printf ': all kb stub subdirs covered\n'
  fi
fi

# ---------- D3: "at HEAD" claims but greps working tree --------------------
section "D3: HEAD-claim skills actually grep HEAD"
d3_hits=""
# Skip auto-generated wrappers under .claude/commands/nase/workspace/ — they only
# reference the source file under workspace/skills/, which is what we actually check.
for f in $(grep -rlE 'at HEAD|verify.*HEAD|grep.*HEAD' "${SKILL_DIRS[@]}" 2>/dev/null \
  | grep -v 'check-skill-doctrine.sh' \
  | grep -v '\.claude/commands/nase/workspace/' || true); do
  # Only files that make a HEAD verification claim
  grep -qE 'at HEAD|verify.*HEAD' "$f" 2>/dev/null || continue
  # Files using `git show HEAD:` / `git grep ... HEAD` are compliant
  grep -qE 'git show HEAD:|git -C [^ ]* grep [^|]* HEAD|git grep [^|]* HEAD' "$f" 2>/dev/null && continue
  # Opt-out: skill declares a clean-tree precondition
  grep -qE 'PR branch must be checked out|working tree.*clean|assume.*checked out clean' "$f" 2>/dev/null && continue
  d3_hits+="  $f"$'\n'
done
if [[ -n "$d3_hits" ]]; then
  red "FAIL"; printf ': files claim "at HEAD" but neither use git show HEAD: nor declare a clean-tree precondition:\n'
  printf '%s' "$d3_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': HEAD-claim skills consistent\n'
fi

# ---------- W1: mutation skills reference policy doc -----------------------
section "W1: mutation skills reference external-mutation-policy.md"
# Keywords that indicate the skill performs an external mutation
MUTATION_RE='(updateConfluencePage|createConfluencePage|transitionJiraIssue|createJiraIssue|editJiraIssue|slack_send_message($|[^_])|gh pr create|gh pr edit|gh pr ready|--add-reviewer|pulls/\{pr_number\}/comments|resolveReviewThread|az pipelines run [^a-z]|az pipelines runs cancel|az pipelines runs update|az rest --method (post|put|patch|delete))'
w1_hits=""
while IFS= read -r f; do
  case "$f" in
    *check-skill-doctrine.sh|*external-mutation-policy.md|*workspace/skills/docs/*) continue ;;
  esac
  skill_scan_text "$f" | grep -qE "$MUTATION_RE" || continue
  if ! grep -q 'external-mutation-policy.md' "$f" 2>/dev/null; then
    w1_hits+="  $f"$'\n'
  fi
done < <(find "${SKILL_DIRS[@]}" -maxdepth 2 -name '*.md' -type f 2>/dev/null)
if [[ -n "$w1_hits" ]]; then
  yellow "WARN"; printf ': mutation-capable skills missing reference to external-mutation-policy.md:\n'
  printf '%s' "$w1_hits"
  warnings=$((warnings+1))
else
  green "PASS"; printf ': all mutation skills reference policy doc\n'
fi

# ---------- D4: all skills have language preflight ------------------------
section "D4: all skills declare language preflight"
d4_hits=""
while IFS= read -r f; do
  case "$f" in
    *workspace/skills/docs/*) continue ;;             # shared docs under skills/docs/ are not skills
    *.claude/commands/nase/workspace/*) continue ;;   # auto-generated wrappers; source lives under workspace/skills/
  esac
  if ! grep -qE 'language-config\.md|Language preflight|## Language|Read.*workspace/config\.md.*Language|conversation:' "$f" 2>/dev/null; then
    d4_hits+="  $f"$'\n'
  fi
done < <(find "${SKILL_DIRS[@]}" -maxdepth 2 -name '*.md' -type f 2>/dev/null)
if [[ -n "$d4_hits" ]]; then
  red "FAIL"; printf ': skill files without language preflight or language-config.md reference:\n'
  printf '%s' "$d4_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': all skills declare language handling\n'
fi

# ---------- D5: Codex MCP stays optional ----------------------------------
section "D5: Codex MCP callers have clean-skip gate"
d5_hits=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if ! grep -qF '.claude/docs/codex-review.md → Prerequisite' "$f" 2>/dev/null \
    || ! grep -qi 'skip cleanly' "$f" 2>/dev/null; then
    d5_hits+="  $f"$'\n'
  fi
done < <(
  grep -rlE 'Codex MCP|mcp__codex__|codex-reply|codex-review\.md' \
    .claude/commands/nase .claude/docs workspace/skills 2>/dev/null \
    | grep -v 'check-skill-doctrine.sh' \
    | grep -v '^\.claude/docs/reference\.md$' \
    | grep -v '^\.claude/docs/codex-review\.md$' || true
)
if [[ -n "$d5_hits" ]]; then
  red "FAIL"; printf ': Codex MCP callers missing prerequisite reference or clean-skip wording:\n'
  printf '%s' "$d5_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': Codex MCP callers degrade cleanly when unavailable\n'
fi

# ---------- D6: restore archive extraction is hardened ---------------------
section "D6: restore archive extraction is path-safe"
RESTORE_MD=".claude/commands/nase/restore.md"
d6_hits=""
for needle in \
  "selected backup is outside backup-target" \
  "parent-traversal paths" \
  "backup payload contains symlinks"; do
  if ! grep -qF "$needle" "$RESTORE_MD" 2>/dev/null; then
    d6_hits+="  missing: $needle"$'\n'
  fi
done
if [[ -n "$d6_hits" ]]; then
  red "FAIL"; printf ': restore.md lacks archive path hardening:\n'
  printf '%s' "$d6_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': restore archive member checks present\n'
fi

# ---------- D7: external KB import cannot write outside workspace ----------
section "D7: kb-merge import paths are bounded"
KB_MERGE_MD=".claude/commands/nase/kb-merge.md"
d7_hits=""
for needle in \
  "Import Path Hardening" \
  "canonical path is inside" \
  "Skip symlinks entirely" \
  "Never use an imported path string directly as a write target" \
  "Skipped (unsafe path)"; do
  if ! grep -qF "$needle" "$KB_MERGE_MD" 2>/dev/null; then
    d7_hits+="  missing: $needle"$'\n'
  fi
done
if [[ -n "$d7_hits" ]]; then
  red "FAIL"; printf ': kb-merge.md lacks external import path hardening:\n'
  printf '%s' "$d7_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': kb-merge import path hardening present\n'
fi

# ---------- D8: imported skill wrappers cannot inject frontmatter -----------
section "D8: kb-merge wrapper frontmatter is sanitized"
d8_hits=""
for needle in \
  "YAML double-quoted strings" \
  "Strip control characters" \
  "Never copy imported frontmatter blocks wholesale"; do
  if ! grep -qF "$needle" "$KB_MERGE_MD" 2>/dev/null; then
    d8_hits+="  missing: $needle"$'\n'
  fi
done
if [[ -n "$d8_hits" ]]; then
  red "FAIL"; printf ': kb-merge.md lacks generated-wrapper frontmatter sanitization:\n'
  printf '%s' "$d8_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': kb-merge wrapper frontmatter sanitization present\n'
fi

# ---------- D9: core skills declare architecture pattern -------------------
section "D9: core skills declare architecture pattern"
d9_hits=$(python3 - <<'PY'
from pathlib import Path
import re

allowed = {"pipeline", "fan-out", "expert-pool", "producer-reviewer", "supervisor", "utility"}
hits = []

for path in sorted(Path(".claude/commands/nase").glob("*.md")):
    if path.parent.name == "workspace":
        continue
    text = path.read_text(encoding="utf-8")
    match = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not match:
        hits.append(f"  {path}: missing frontmatter")
        continue
    fields = {}
    for line in match.group(1).splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        fields[key.strip()] = value.strip().strip('"').strip("'")
    pattern = fields.get("pattern")
    if not pattern:
        hits.append(f"  {path}: missing pattern")
    elif pattern not in allowed:
        hits.append(f"  {path}: invalid pattern '{pattern}'")

print("\n".join(hits))
PY
)
if [[ -n "$d9_hits" ]]; then
  red "FAIL"; printf ': core skill files missing valid pattern frontmatter:\n'
  printf '%s\n' "$d9_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': all core skills declare architecture pattern\n'
fi

# ---------- D10: durable workspace writes use shared guard -----------------
section "D10: durable workspace writes use workspace-write-guard"
d10_hits=$(python3 - <<'PY'
from pathlib import Path
import re

durable_path = re.compile(r"workspace/(?:kb/|tasks/|skills/|efforts/|context\.md|communication-style\.md)")
write_verb = re.compile(
    r"\b(write|append|create|update|save|persist|prepend|overwrite|replace|move|delete|remove|promote|mark|register|check off|add to|sync)\b",
    re.I,
)
read_only = re.compile(
    r"\b(read|scan|search|list|surface|show|report|flag|follow-up|will later|never writes?|read-only|do not write|does not write|without writing)\b",
    re.I,
)
exempt = {
    "init.md",      # bootstrap creates the first workspace skeleton
    "restore.md",   # restore owns archive safety and replaces workspace by design
}

hits = []
for path in sorted(Path(".claude/commands/nase").glob("*.md")):
    if path.name in exempt or path.parent.name == "workspace":
        continue
    text = path.read_text(encoding="utf-8")
    if "workspace-write-guard.md" in text:
        continue

    in_code = False
    fence = chr(96) * 3
    for lineno, line in enumerate(text.splitlines(), 1):
        if line.startswith(fence):
            in_code = not in_code
            continue
        if in_code:
            continue
        if durable_path.search(line) and write_verb.search(line) and not read_only.search(line):
            hits.append(f"  {path}:{lineno}: {line.strip()}")
            break

print("\n".join(hits))
PY
)
if [[ -n "$d10_hits" ]]; then
  red "FAIL"; printf ': durable workspace write skills missing workspace-write-guard.md:\n'
  printf '%s\n' "$d10_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': durable workspace write skills use shared guard\n'
fi

# ---------- D11: auto-write modes cannot skip drift checks -----------------
section "D11: auto-write modes preserve drift checks"
d11_hits=$(python3 - <<'PY'
from pathlib import Path

required = "Auto-write modes only skip human confirmation; they never skip final drift checks."
targets = {
    ".claude/commands/nase/kb-gap-detect.md": "--auto",
    ".claude/commands/nase/extract-skills.md": "--auto-accept",
    ".claude/commands/nase/wrap-up.md": "automatic KB update",
}

hits = []
for filename, marker in targets.items():
    path = Path(filename)
    text = path.read_text(encoding="utf-8")
    if marker not in text:
        hits.append(f"  {path}: missing auto-write marker {marker!r}")
    elif required not in text:
        hits.append(f"  {path}: missing exact auto-write drift-check rule")
    elif "workspace-write-guard.py apply" not in text and path.name != "extract-skills.md":
        hits.append(f"  {path}: missing helper apply reference")

print("\n".join(hits))
PY
)
if [[ -n "$d11_hits" ]]; then
  red "FAIL"; printf ': auto-write paths must preserve final drift checks:\n'
  printf '%s\n' "$d11_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': auto-write modes preserve drift checks\n'
fi

# ---------- D12: today does not push optional tech-digest ------------------
section "D12: /nase:today keeps tech-digest optional"
d12_hits=$(python3 - <<'PY'
from pathlib import Path
import re

path = Path(".claude/commands/nase/today.md")
text = path.read_text(encoding="utf-8")
root_guidance = Path("CLAUDE.md").read_text(encoding="utf-8")

hits = []
try:
    step4c = text.split("### 4c. Need Attention scan + action menu", 1)[1]
    step4c = step4c.split("### 4d. Closing block", 1)[0]
except IndexError:
    hits.append(f"  {path}: missing Step 4c or Step 4d anchor")
else:
    if re.search(r"tech[- ]digest", step4c, re.IGNORECASE):
        hits.append(f"  {path}: Step 4c mentions tech-digest; keep it out of Need Attention/action menu")

expected_optional_note = chr(96) + "/nase:tech-digest" + chr(96) + " is optional"
if expected_optional_note not in text:
    hits.append(f"  {path}: missing explicit optional tech-digest note")

if re.search(r"First session of the day:\s*`/nase:tech-digest`", root_guidance):
    hits.append("  CLAUDE.md: first-session guidance pushes tech-digest instead of /nase:today")

print("\n".join(hits))
PY
)
if [[ -n "$d12_hits" ]]; then
  red "FAIL"; printf ': /nase:today should not push optional tech-digest:\n'
  printf '%s\n' "$d12_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': /nase:today keeps tech-digest optional\n'
fi

# ---------- D13: temp artifact filenames must use path-safe slugs ----------
section "D13: branch-derived workspace/tmp artifacts use slugs"
d13_hits=$(python3 - <<'PY'
from pathlib import Path
import re

paths = [
    Path(".claude/commands/nase/fsd.md"),
    Path(".claude/docs/fsd-phase-decomposition.md"),
    Path("workspace/skills/deploy-alpha.md"),
]
unsafe = re.compile(r"workspace/tmp/[^\n`]*\{(?:branch_name|branch)\}")
hits = []
for path in paths:
    if not path.exists():
        continue
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if unsafe.search(line):
            hits.append(f"  {path}:{lineno}: {line.strip()}")

print("\n".join(hits))
PY
)
if [[ -n "$d13_hits" ]]; then
  red "FAIL"; printf ': branch names can contain /; use a slug for workspace/tmp file names:\n'
  printf '%s\n' "$d13_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': branch-derived workspace/tmp artifacts use path-safe slugs\n'
fi

# ---------- D14: generated wrappers stay within metadata cap ---------------
section "D14: generated workspace wrapper descriptions are capped"
d14_hits=$(python3 - <<'PY'
from pathlib import Path
import re

hits = []
for path in sorted(Path(".claude/commands/nase/workspace").glob("*.md")):
    text = path.read_text(encoding="utf-8")
    match = re.search(r'^description: "(.*)"$', text, re.M)
    if not match:
        continue
    desc_len = len(match.group(1))
    if desc_len > 240:
        hits.append(f"  {path}: description length {desc_len} > 240")

print("\n".join(hits))
PY
)
if [[ -n "$d14_hits" ]]; then
  red "FAIL"; printf ': generated wrappers should match session-start compact description cap:\n'
  printf '%s\n' "$d14_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': generated wrapper descriptions are capped\n'
fi

# ---------- D15: critical workflows preserve KB lookup markers -------------
section "D15: critical KB workflows preserve lookup markers"
d15_hits=$(python3 - <<'PY'
from pathlib import Path

markers = (
    "repo-resolution.md",
    "kb-domain-resolve.sh",
    "nase-context-kb-researcher",
    "workspace/kb/.domain-map.md",
    "mentions:<path>",
)
targets = [
    ".claude/commands/nase/design.md",
    ".claude/commands/nase/fsd.md",
    ".claude/commands/nase/discuss-pr.md",
    ".claude/commands/nase/address-comments.md",
    ".claude/commands/nase/request-review.md",
    ".claude/commands/nase/tech-debt-audit.md",
    ".claude/commands/nase/today.md",
    "workspace/skills/investigate-sre-jira.md",
    "workspace/skills/handle-support-question.md",
    "workspace/skills/deploy-alpha.md",
    "workspace/skills/security-pr-review.md",
]

hits = []
for filename in targets:
    path = Path(filename)
    if not path.exists():
        continue
    text = path.read_text(encoding="utf-8")
    if not any(marker in text for marker in markers):
        hits.append(f"  {path}: missing one of {', '.join(markers)}")

print("\n".join(hits))
PY
)
if [[ -n "$d15_hits" ]]; then
  red "FAIL"; printf ': critical KB-consuming workflows need explicit lookup markers:\n'
  printf '%s\n' "$d15_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': critical KB workflows keep explicit lookup markers\n'
fi

# ---------- D16: workspace skill source descriptions fit wrapper cap -------
section "D16: workspace skill source descriptions fit wrapper cap"
d16_hits=$(python3 - <<'PY'
from pathlib import Path
import re


def unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        return value[1:-1].replace(r"\"", '"').replace(r"\\", "\\")
    if len(value) >= 2 and value[0] == value[-1] == "'":
        return value[1:-1]
    return value


def description_from_frontmatter(text: str) -> str:
    match = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not match:
        return ""

    lines = match.group(1).splitlines()
    desc_lines: list[str] = []
    capture_block = False
    for raw in lines:
        if capture_block:
            if re.match(r"^[A-Za-z0-9_-]+:\s*", raw):
                break
            desc_lines.append(raw.strip())
            continue

        if raw.startswith("description:"):
            value = raw.split(":", 1)[1].strip()
            if value in {"|", ">", "|-", ">-", "|+", ">+"}:
                capture_block = True
                continue
            desc_lines = [unquote(value)]
            break

    return re.sub(r"\s+", " ", " ".join(line for line in desc_lines if line)).strip()


hits = []
for path in sorted(Path("workspace/skills").glob("*.md")):
    desc = description_from_frontmatter(path.read_text(encoding="utf-8", errors="replace"))
    if len(desc) > 240:
        hits.append(f"  {path}: description length {len(desc)} > 240")

print("\n".join(hits))
PY
)
if [[ -n "$d16_hits" ]]; then
  red "FAIL"; printf ': workspace skill source descriptions should fit the generated wrapper cap:\n'
  printf '%s\n' "$d16_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': workspace skill source descriptions fit wrapper cap\n'
fi

# ---------- D17: command descriptions stay ASCII for routing ---------------
section "D17: command descriptions avoid CJK trigger terms"
d17_hits=$(python3 - <<'PY'
from pathlib import Path
import re


def unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        return value[1:-1].replace(r"\"", '"').replace(r"\\", "\\")
    if len(value) >= 2 and value[0] == value[-1] == "'":
        return value[1:-1]
    return value


def description_from_frontmatter(text: str) -> str:
    match = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not match:
        return ""

    lines = match.group(1).splitlines()
    desc_lines: list[str] = []
    capture_block = False
    for raw in lines:
        if capture_block:
            if re.match(r"^[A-Za-z0-9_-]+:\s*", raw):
                break
            desc_lines.append(raw.strip())
            continue

        if raw.startswith("description:"):
            value = raw.split(":", 1)[1].strip()
            if value in {"|", ">", "|-", ">-", "|+", ">+"}:
                capture_block = True
                continue
            desc_lines = [unquote(value)]
            break

    return re.sub(r"\s+", " ", " ".join(line for line in desc_lines if line)).strip()


hits = []
for path in sorted(Path(".claude/commands/nase").glob("*.md")):
    desc = description_from_frontmatter(path.read_text(encoding="utf-8", errors="replace"))
    if re.search(r"[\u3040-\u30ff\u3400-\u9fff]", desc):
        hits.append(f"  {path}: description contains CJK text")

print("\n".join(hits))
PY
)
if [[ -n "$d17_hits" ]]; then
  red "FAIL"; printf ': command frontmatter descriptions should stay ASCII-only routing metadata:\n'
  printf '%s\n' "$d17_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': command descriptions avoid CJK trigger terms\n'
fi

# ---------- Result ---------------------------------------------------------
printf '\n'
if [[ $failed -eq 0 ]]; then
  if [[ $warnings -eq 0 ]]; then
    green "All doctrine gates passed."; printf '\n'
  else
    yellow "Doctrine: 0 failures, $warnings warning category/-ies — review above."; printf '\n'
  fi
  exit 0
fi

red "$failed doctrine gate(s) failed."; printf '\n'
exit "$failed"
