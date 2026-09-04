#!/usr/bin/env bash
# Enforce skill-authoring doctrine across .claude/commands/nase/ + workspace/skills/.
#
# FAILS on:
#   D1. curl-with-PAT for ADO endpoints (must use az CLI per feedback_ado-az-cli-only.md)
#   D2. mkdir line in init.md missing any workspace/kb/* subdir whose stub-write step follows
#   D3. files claiming "at HEAD" in a verifier role but greping the working tree without
#       `git show HEAD:` (regression guard for doc-pr-head-ground-scan.md)
#   D4. skill files missing a language preflight / language-config reference
#   D5. verification-gate callers that still frame the gate as conditional on an
#       external provider, which would make a mandatory gate optional again
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
#   D18. core command frontmatter misses bounded Claude-native metadata
#   D19. allowed-tools is described as a security boundary
#   D20. review skills lose diff-first investigation or trace-shape checks
#   D21. discuss-pr loses outgoing-comment quality or review-state gates
#   D22. KB writers regress to append-only refreshes, heartbeat facts, or placeholders
#   D23. fsd/address-comments/simplify lose the code-comment default or the gate that scores it
#   D24. a pipeline skill's phase number disagrees between its heading, its document's
#        Contents list, and the cross-references that route to it
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

# ---------- D5: the verification gate stays mandatory ----------------------
section "D5: gate owners declare the gate unconditional"
# The gate used to route through an external MCP provider, so the old doctrine
# required every caller to degrade cleanly when that provider was absent. The
# gate now runs one local read-only verifier, which is always available, so the
# opposite failure is the live one: a doc that reframes the check as conditional
# turns a mandatory outward-facing gate back into an optional one.
#
# "Is this prose conditional?" is not decidable by grep - a search for "optional"
# flags unrelated text, and an absence-of-residue check passes any newly written
# conditional wording. So each gate owner is named here and must carry an
# explicit unconditional marker: a positive token the author has to delete before
# the gate can become optional again, which a reviewer will see in the diff.
declare -a D5_OWNERS=(
  ".claude/docs/pr-review-verification.md"
  ".claude/docs/address-comments-delivery.md"
  ".claude/docs/fsd-delivery-gates.md"
)
D5_MARKER='no availability branch|gate is unconditional|always runs'
d5_hits=""
for f in "${D5_OWNERS[@]}"; do
  if [[ ! -f "$f" ]]; then
    d5_hits+="  $f: missing"$'\n'
  elif ! grep -qE "$D5_MARKER" "$f" 2>/dev/null; then
    d5_hits+="  $f: no unconditional marker"$'\n'
  fi
done
# Second, cheaper assertion: the provider is gone, so its wording must not
# reappear anywhere. This is a rename-residue lint, not an optionality check.
# Only Codex-identifying tokens belong here. A generic "MCP is unavailable"
# would flag the Atlassian and Slack MCPs, which are legitimately optional.
D5_RESIDUE='Codex MCP|mcp__codex__|codex-reply'
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  d5_hits+="  $f: provider residue"$'\n'
done < <(
  grep -rlE "$D5_RESIDUE" .claude/commands/nase .claude/docs workspace/skills 2>/dev/null \
    | grep -v 'check-skill-doctrine.sh' || true
)
if [[ -n "$d5_hits" ]]; then
  red "FAIL"; printf ': verification-gate doctrine broke:\n'
  printf '%s' "$d5_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': gate owners declare the gate unconditional, no provider residue\n'
fi

# ---------- D6: restore archive extraction is hardened ---------------------
section "D6: restore archive extraction is path-safe"
RESTORE_MD=".claude/commands/nase/restore.md"
RESTORE_HELPER=".claude/scripts/restore-workspace.py"
d6_hits=""
for needle in \
  "restore-workspace.py\" resolve-backup" \
  "restore-workspace.py\" inspect" \
  "restore-workspace.py\" apply" \
  "restore-workspace.py\" recover" \
  'Do not copy, delete, or extract directly into `workspace/`'; do
  if ! grep -qF "$needle" "$RESTORE_MD" 2>/dev/null; then
    d6_hits+="  missing: $needle"$'\n'
  fi
done
for needle in \
  "selected backup is outside backup-target" \
  "nase-backup-*.zip or nase-backup-*.7z" \
  "7z listing has no member metadata separator" \
  "archive contains parent traversal" \
  "Unicode/case collision" \
  "candidate contains a link or special file" \
  "foreign workspace" \
  'journal["state"] = "new_promoted"'; do
  if ! grep -qF "$needle" "$RESTORE_HELPER" 2>/dev/null; then
    d6_hits+="  helper missing: $needle"$'\n'
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
guard_doc = Path(".claude/docs/workspace-write-guard.md").read_text(encoding="utf-8")
if "--expected-staged-sha256" not in guard_doc:
    hits.append("  .claude/docs/workspace-write-guard.md: missing staged SHA binding")
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
    Path(".claude/docs/fsd-intake-and-setup.md"),
    Path(".claude/docs/fsd-phase-decomposition.md"),
    Path("workspace/skills/deploy-alpha.md"),
]
unsafe = re.compile(r"workspace/tmp/[^\n\x60]*\{(?:branch_name|branch)\}")
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
import sys

sys.path.insert(0, "tests/lib")
from frontmatter import description_from_frontmatter


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
import sys

sys.path.insert(0, "tests/lib")
from frontmatter import description_from_frontmatter


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

# ---------- D18: Claude-native command metadata stays bounded --------------
section "D18: command frontmatter has bounded Claude-native metadata"
d18_hits=$(python3 - <<'PY'
from pathlib import Path
import re
import sys

sys.path.insert(0, "tests/lib")
from frontmatter import unquote

allowed = {
    "name",
    "description",
    "argument-hint",
    "when_to_use",
    "pattern",
    "category",
    "sub-patterns",
    "order",
    "model",
    "effort",
    "context",
    "agent",
}

hits = []
for path in sorted(Path(".claude/commands/nase").glob("*.md")):
    text = path.read_text(encoding="utf-8", errors="replace")
    match = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not match:
        hits.append(f"  {path}: missing frontmatter")
        continue
    fields = {}
    for raw in match.group(1).splitlines():
        if not raw.strip() or raw.startswith(" ") or raw.startswith("#"):
            continue
        if ":" not in raw:
            hits.append(f"  {path}: malformed frontmatter line {raw!r}")
            continue
        key, value = raw.split(":", 1)
        key = key.strip()
        fields[key] = unquote(value, json_double=True)
        if key not in allowed:
            hits.append(f"  {path}: unsupported frontmatter key {key!r}")
    for required in ("argument-hint",):
        if not fields.get(required):
            hits.append(f"  {path}: missing {required}")
    when_to_use = fields.get("when_to_use") or fields.get("description", "")
    if not when_to_use:
        hits.append(f"  {path}: missing when_to_use fallback")
    if len(fields.get("argument-hint", "")) > 80:
        hits.append(f"  {path}: argument-hint length > 80")
    if len(when_to_use) > 360:
        hits.append(f"  {path}: when_to_use length > 360")

print("\n".join(hits))
PY
)
if [[ -n "$d18_hits" ]]; then
  red "FAIL"; printf ': command frontmatter Claude-native metadata invalid:\n'
  printf '%s\n' "$d18_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': command frontmatter Claude-native metadata is bounded\n'
fi

# ---------- D19: allowed-tools is not documented as a blocker --------------
section "D19: allowed-tools is not treated as a security boundary"
d19_hits=$(python3 - <<'PY'
from pathlib import Path
import re

bad = re.compile(r"allowed-tools.{0,120}\b(restrict|block|prevent|deny|security boundary|only allow|sandbox)\b", re.I)
safe = re.compile(r"not (?:a )?restriction|not .*security boundary|pre-approves|does not block", re.I)
hits = []
for root in (Path(".claude/commands/nase"), Path(".claude/docs"), Path("docs"), Path("workspace/skills")):
    if not root.exists():
        continue
    for path in sorted(root.rglob("*.md")):
        for lineno, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if "allowed-tools" not in line:
                continue
            if bad.search(line) and not safe.search(line):
                hits.append(f"  {path}:{lineno}: {line.strip()}")

print("\n".join(hits))
PY
)
if [[ -n "$d19_hits" ]]; then
  red "FAIL"; printf ': allowed-tools pre-approves tools; do not describe it as a blocking boundary:\n'
  printf '%s\n' "$d19_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': allowed-tools wording does not claim blocking security\n'
fi

# ---------- D20: review skills wire the diff-first directive + trace-shape self-check ----------
section "D20: review skills wire diff-first investigation + trace-shape self-check"
d20_hits=$(python3 - <<'PY'
from pathlib import Path

# Assert the behavior-changing wiring, not just a doc citation: a future edit that
# keeps the §11 reference but deletes the inline directive or the self-check call
# site must fail this gate. Tokens below are what the wiring actually inserts.
required = {
    ".claude/docs/pr-review-verification.md": [
        "## 11. Diff-First Investigation",
        "## 12. Trace-Shape Self-Check",
    ],
    ".claude/docs/discuss-pr-analysis.md": [
        "§11",                                       # §11 block reference
        "diff-first investigation directive, inline",     # inline directive @ Step 5b spawn
        "trace-shape self-check",                         # self-check call site(s)
        "§12",                                       # §12 self-check reference
    ],
    ".claude/docs/discuss-pr-output.md": [
        "inline diff-first directive",                    # inline directive @ optional deep-dive spawn
        "trace-shape self-check",
        "§12",
    ],
    ".claude/docs/address-comments-analysis.md": [
        "§11",                                       # §11 block reference
        "diff-first",                                     # diff-first dossier investigation
        "Trace-shape self-check",                         # self-check call site
        "§12",
    ],
    ".claude/commands/nase/discuss-pr.md": [
        "discuss-pr-analysis.md",
        "discuss-pr-output.md",
    ],
    ".claude/commands/nase/address-comments.md": [
        "address-comments-analysis.md",
        "address-comments-delivery.md",
    ],
}

hits = []
for filename, tokens in required.items():
    path = Path(filename)
    if not path.exists():
        hits.append(f"  {path}: missing (expected to exist)")
        continue
    text = path.read_text(encoding="utf-8")
    for token in tokens:
        if token not in text:
            hits.append(f"  {path}: missing required wiring token: {token!r}")

print("\n".join(hits))
PY
)
if [[ -n "$d20_hits" ]]; then
  red "FAIL"; printf ': review skills must inline the diff-first directive at both Explore spawn sites + name a trace-shape self-check call site (not just cite the doc):\n'
  printf '%s\n' "$d20_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': diff-first directive + trace-shape self-check wired into discuss-pr and address-comments\n'
fi

# ---------- D21: discuss-pr comment quality and review-state gates ----------
section "D21: discuss-pr comment quality + review-state gates"
d21_hits=$(python3 - <<'PY'
from pathlib import Path

required = {
    ".claude/commands/nase/discuss-pr.md": [
        "private outgoing-comment research gate",
        "confidence",
        "severity",
        "kind",
        "disposition",
        "Nits are always non-blocking",
    ],
    ".claude/docs/discuss-pr-analysis.md": [
        "Build the private outgoing-comment record",
        "High confidence does not raise severity",
        "Only `issue` may be blocking",
        "Binding behavior wins over style guidance",
        "repo authority and relevant local patterns win over general guidance",
        "personal preference never produces a comment",
        "not already caught by an available formatter/linter",
        "question (needs-answer)",
        "General best-practice sources",
        "focus on bugs only",
        "safe_defer: no",
        "must_not_merge_reason",
        "Collapse the same root cause or repeated nit pattern",
    ],
    ".claude/docs/discuss-pr-output.md": [
        "nit (non-blocking):",
        "question (needs-answer):",
        "Keep the private record private",
        "Required-check failures alone",
        "must_not_merge_reason",
        "Never recommend or submit `APPROVE`",
        "Build the options from eligible states only",
        "Recompute state eligibility",
        "`REQUEST_CHANGES` is the only submission state",
    ],
}

hits = []
for filename, tokens in required.items():
    path = Path(filename)
    if not path.exists():
        hits.append(f"  {path}: missing")
        continue
    text = path.read_text(encoding="utf-8")
    for token in tokens:
        if token not in text:
            hits.append(f"  {path}: missing required comment-quality token: {token!r}")

print("\n".join(hits))
PY
)
if [[ -n "$d21_hits" ]]; then
  red "FAIL"; printf ': discuss-pr must preserve researched comments, explicit nits, and exceptional request-changes behavior:\n'
  printf '%s\n' "$d21_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': discuss-pr comment-quality and review-state gates are wired\n'
fi

# ---------- D22: KB writers reconcile current state without noise ----------
section "D22: KB writers reconcile current state without noise"
d22_hits=$(python3 - <<'PY'
from pathlib import Path

required = {
    ".claude/commands/nase/onboard.md": [
        "keep every KB target file byte-identical",
        "Reconcile current-state sections in place",
        "Do not add dated refresh blocks",
    ],
    ".claude/commands/nase/kb-update.md": [
        "Current-state fact",
        "Never write placeholders",
        "write nothing",
        "Verification triad",
        "Do not add frontmatter solely for KB metadata",
    ],
    ".claude/commands/nase/kb-gap-detect.md": [
        "verification triad",
        "current-state reconciliation",
        "admitted drafts",
    ],
    ".claude/commands/nase/kb-merge.md": [
        "verification triad",
        "staged proposal",
    ],
    ".claude/docs/fsd-delivery-gates.md": [
        "invoke `/nase:learn`",
        "verification triad",
    ],
    ".claude/docs/kb-write-routing.md": [
        "Shared admission contract",
        "Reconcile current state in place",
        "Apply KB content before its domain-map metadata update",
    ],
    "CLAUDE.md": [
        "Shared admission contract",
        "verified durable discoveries",
    ],
    "workspace/skills/docs/sre-alert-recovery.md": [
        "invoke `/nase:kb-update`",
        "current-state alert pattern",
    ],
    "workspace/skills/alert-rule-quality-checker.md": [
        "invoke `/nase:kb-update`",
    ],
    "workspace/skills/runbook-from-incident.md": [
        "invoke `/nase:kb-update`",
    ],
    ".claude/commands/nase/doctor.md": [
        "kb-hygiene-scan.py --workspace-scan",
    ],
    ".claude/commands/nase/kb-review.md": [
        "--kb-only",
    ],
    ".claude/docs/kb-staleness.md": [
        "domain metadata",
        "Access staleness",
    ],
    "workspace/skills/deploy-alpha.md": [
        "current pipeline source",
    ],
    "workspace/skills/confluence-doc-internalize.md": [
        "current repo contract is authoritative",
    ],
    "workspace/skills/repo-docs-with-ascii.md": [
        "verified against the current repo",
    ],
    ".claude/docs/azure-pipeline-kb-extract.md": [
        "only when verified",
        "omit the metadata comment",
    ],
}

hits = []
for filename, tokens in required.items():
    path = Path(filename)
    if not path.exists():
        if filename.startswith("workspace/"):
            continue
        hits.append(f"  {path}: missing")
        continue
    text = path.read_text(encoding="utf-8")
    for token in tokens:
        if token not in text:
            hits.append(f"  {path}: missing required no-noise token: {token!r}")

for filename in (
    ".claude/docs/azure-pipeline-kb-extract.md",
    ".claude/docs/kb-template.md",
):
    path = Path(filename)
    if "FILL_IN" in path.read_text(encoding="utf-8"):
        hits.append(f"  {path}: KB-writing guidance must not emit FILL_IN")

for filename, forbidden in {
    ".claude/docs/kb-template.md": ["## Cross-Validation Notes", "## Knowledge Hygiene"],
    ".claude/commands/nase/kb-update.md": ["If no frontmatter exists"],
    ".claude/commands/nase/kb-gap-detect.md": [
        "**Source:** detected by /nase:kb-gap-detect",
        "**Tags:** gap-detected",
    ],
    "workspace/kb/.domain-map.md": ["last-loaded:"],
}.items():
    path = Path(filename)
    if not path.exists():
        if filename.startswith("workspace/"):
            continue
        hits.append(f"  {path}: missing")
        continue
    text = path.read_text(encoding="utf-8")
    for token in forbidden:
        if token in text:
            hits.append(f"  {path}: stale KB maintenance contract remains: {token!r}")

print("\n".join(hits))
PY
)
if [[ -n "$d22_hits" ]]; then
  red "FAIL"; printf ': KB writers must update current state in place and omit placeholders/heartbeats:\n'
  printf '%s\n' "$d22_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': KB writers preserve no-op identity and write only verified durable facts\n'
fi

# ---------- D23: code-writing workflows wire the code comment policy ----------
section "D23: code-writing skills wire the code comment policy"
d23_hits=$(python3 - <<'PY'
from pathlib import Path

# Assert the wiring, not just the citation: a future edit that keeps the
# `code-comment-policy.md` path but drops the write-time default or the gate
# that scores it must fail here.
required = {
    ".claude/docs/code-comment-policy.md": [
        "Deletion test",
        "What never earns a comment",
        "Repos that mandate documentation",
        "When a reviewer asks for a comment",
    ],
    ".claude/docs/fsd-implementation-loop.md": [
        ".claude/docs/code-comment-policy.md",
        "Default to none",
        "comment_quality",
    ],
    ".claude/docs/fsd-delivery-gates.md": [
        ".claude/docs/code-comment-policy.md",
        "necessity and concision",
    ],
    ".claude/docs/address-comments-delivery.md": [
        ".claude/docs/code-comment-policy.md",
        "Default to none",
    ],
    ".claude/docs/pr-review-verification.md": [
        ".claude/docs/code-comment-policy.md",
    ],
    ".claude/docs/review-modes.md": [
        "restates the code or narrates the change",
    ],
    ".claude/commands/nase/simplify.md": [
        ".claude/docs/code-comment-policy.md",
        "Unearned comments",
        # The cleanup pass deletes comments, so the mandated-doc carve-out is the
        # guard that keeps it from stripping a repo's required public-API docs.
        "never strip a doc comment the repo mandates",
    ],
}

hits = []
for filename, tokens in required.items():
    path = Path(filename)
    if not path.exists():
        hits.append(f"  {path}: missing")
        continue
    text = path.read_text(encoding="utf-8")
    for token in tokens:
        if token not in text:
            hits.append(f"  {path}: missing required comment-policy token: {token!r}")

print("\n".join(hits))
PY
)
if [[ -n "$d23_hits" ]]; then
  red "FAIL"; printf ': code-writing workflows must default to no comment and keep the policy gated:\n'
  printf '%s\n' "$d23_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': fsd, address-comments, and simplify write against the code comment policy\n'
fi

# ---------- D24: pipeline phase numbering stays internally consistent ------
section "D24: pipeline skills' phase numbers agree across heading, Contents, and cross-refs"
d24_hits=$(python3 - <<'PY'
import re
from pathlib import Path

# fsd and address-comments each spread their phases over an entrypoint plus two or three
# phase documents, so one phase number lives in three places: the heading that owns it,
# its document's Contents list, and every cross-reference that routes to it. Nothing else
# compares those, and the drift reads as ordinary prose - a `## Phase 8.5` absent from its
# Contents list, or a `Phase 6.5` reference surviving the phase being folded away. Both
# shipped before this gate existed.
SKILLS = {
    "fsd": (
        ".claude/commands/nase/fsd.md",
        (
            ".claude/docs/fsd-intake-and-setup.md",
            ".claude/docs/fsd-implementation-loop.md",
            ".claude/docs/fsd-delivery-gates.md",
        ),
    ),
    "address-comments": (
        ".claude/commands/nase/address-comments.md",
        (
            ".claude/docs/address-comments-analysis.md",
            ".claude/docs/address-comments-delivery.md",
        ),
    ),
}

# A phase label is numeric with an optional decimal and an optional letter suffix (8b, 8c).
LABEL = r"[0-9]+(?:\.[0-9]+)?[a-z]?"
HEADING = re.compile(rf"^#{{2,3}} Phase ({LABEL})\b")
TOC_ENTRY = re.compile(rf"^[-*] \[?Phase ({LABEL})")
REFERENCE = re.compile(rf"\bPhase ({LABEL})\b")

hits = []


def contents_labels(lines):
    """Phase labels listed in the document's own `## Contents` block."""
    labels, inside = [], False
    for line in lines:
        if line.strip() == "## Contents":
            inside = True
            continue
        if inside and line.startswith("## "):
            break
        if inside:
            match = TOC_ENTRY.match(line)
            if match:
                labels.append(match.group(1))
    return labels


for skill, (entrypoint, phase_docs) in SKILLS.items():
    files = (entrypoint, *phase_docs)
    texts = {}
    for name in files:
        path = Path(name)
        if not path.exists():
            hits.append(f"  {name}: missing")
            continue
        texts[name] = path.read_text(encoding="utf-8")
    if len(texts) != len(files):
        continue

    owner = {}
    for name, text in texts.items():
        for line in text.splitlines():
            match = HEADING.match(line)
            if match:
                owner.setdefault(match.group(1), name)

    for name in phase_docs:
        lines = texts[name].splitlines()
        listed = contents_labels(lines)
        headings = [m.group(1) for line in lines if (m := HEADING.match(line))]
        if listed != headings:
            hits.append(
                f"  {name}: Contents lists {listed} but the headings are {headings}"
            )

    for name, text in texts.items():
        for label in sorted(set(REFERENCE.findall(text))):
            if label not in owner:
                hits.append(
                    f"  {name}: 'Phase {label}' has no heading anywhere in /nase:{skill}"
                )

print("\n".join(hits))
PY
)
if [[ -n "$d24_hits" ]]; then
  red "FAIL"; printf ': phase numbering drifted between headings, Contents lists, and cross-references:\n'
  printf '%s\n' "$d24_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': fsd and address-comments phase numbers resolve consistently\n'
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
