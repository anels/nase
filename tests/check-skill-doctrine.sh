#!/usr/bin/env bash
# Enforce skill-authoring doctrine across .claude/commands/nase/ + workspace/skills/.
#
# FAILS on:
#   D1. curl-with-PAT for ADO endpoints (must use az CLI per feedback_ado-az-cli-only.md)
#   D2. mkdir line in init.md missing any workspace/kb/* subdir whose stub-write step follows
#   D4. session-start.sh no longer delivers the configured language to the session
#   D5. verification-gate callers that still frame the gate as conditional on an
#       external provider, which would make a mandatory gate optional again
#   D6. restore archive flow missing path traversal / symlink hardening
#   D7. kb-teamshare import external flow missing canonical path / symlink hardening
#   D8. kb-teamshare import generated skill wrappers missing frontmatter sanitization
#   D9. retired - it gated a `pattern:` frontmatter key nothing consumed. D18 now
#       rejects the key outright, so reintroducing it fails there instead.
#   D10. durable workspace write skills missing workspace-write-guard.md
#   D11. auto-write modes allowed to skip drift checks
#   D12. /nase:today treats tech-digest as a proactive action instead of optional
#   D13. workspace/tmp artifact paths embed raw branch names that may contain slashes
#   D15. critical KB-consuming workflows contain an explicit KB lookup marker
#   D17. command frontmatter descriptions contain CJK trigger terms
#   D18. core command frontmatter misses bounded Claude-native metadata
#   D20. review skills lose diff-first investigation or trace-shape checks
#   D21. discuss-pr loses outgoing-comment quality or review-state gates
#   D22. KB writers regress to append-only refreshes, heartbeat facts, or placeholders
#   D23. fsd/address-comments/simplify lose the code-comment default or the gate that scores it
#   D24. a pipeline skill's phase number disagrees between its heading, its document's
#        Contents list, and the cross-references that route to it
#   D25. a `Step N` cross-reference names a step its skill's numbered workflow does not have
#
# WARNS (does not fail) on:
#   W1. mutation-keyword skills (Slack/Jira/Confluence/ADO/GitHub PR writes) missing reference
#       to .claude/docs/external-mutation-policy.md
#
# The 240-char description cap lives in tests/scripts/test-command-skill-size-budget.sh only.
# D3, D14, D16 and D19 were retired: D3 guarded one untracked skill with no recorded use, D14 and
# D16 duplicated that budget, and D19 guarded a frontmatter key no skill sets (D18 plus
# skill-audit Category 8 reject it).
#
# Exit codes: 0 = no failures (warnings OK), N = N failure types tripped.
#
# Run from repo root:  bash tests/check-skill-doctrine.sh

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

# Assertions on git-ignored workspace/ files skip on a fresh clone. Count them so the skip
# is visible, and fail when workspace/skills/ exists but a named skill file does not.
# shellcheck source=lib/workspace-skip.sh
source "$ROOT/tests/lib/workspace-skip.sh"
ws_skip_file_init
trap 'rm -f "$WS_SKIP_FILE"' EXIT

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

# ---------- W1: mutation skills reference policy doc -----------------------
section "W1: mutation skills reference external-mutation-policy.md"
# Keywords that indicate the skill performs an external mutation
MUTATION_RE='((update|create)Confluence(Page|Content)|transitionJiraIssue|createJiraIssue|editJiraIssue|addCommentToJiraIssue|addOrEditJiraIssueComment|execute(Write|Destructive)|slack_send_message($|[^_])|slack_schedule_message|slack_(create|update)_canvas|gh pr create|gh pr edit|gh pr ready|--add-reviewer|pulls/\{pr_number\}/comments|resolveReviewThread|az pipelines run [^a-z]|az pipelines runs cancel|az pipelines runs update|az rest --method (post|put|patch|delete))'
w1_hits=""
while IFS= read -r f; do
  case "$f" in
    *check-skill-doctrine.sh|*external-mutation-policy.md|*workspace/skills/docs/*) continue ;;
  esac
  # Capture, then match. `skill_scan_text | grep -qE` under `pipefail` returns 141
  # when grep matches early and awk's next write hits the closed pipe, and `||
  # continue` reads that as "no mutation keyword" - so this gate skipped
  # mutation-capable skills non-deterministically.
  scan_text=$(skill_scan_text "$f")
  grep -qE "$MUTATION_RE" <<<"$scan_text" || continue
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

# ---------- D4: session start delivers the configured language ------------
section "D4: session start emits the configured language"
# Skills carry no language preflight, so session-start.sh is what puts the configured
# values into context. Run it against a throwaway config. The registration must carry no
# matcher: a matcher would stop it re-firing after a resume, clear, or compaction.
d4_hits=""
if d4_root=$(mktemp -d); then
  mkdir -p "$d4_root/workspace"
  printf '## Language\n- conversation: d4-chat\n- output: d4-artifact\n' >"$d4_root/workspace/config.md"
  d4_out=$(NASE_ROOT="$d4_root" bash .claude/hooks/session-start.sh </dev/null 2>/dev/null)
  grep -qF '[language] conversation: d4-chat; output: d4-artifact; code identifiers: English.' <<<"$d4_out" \
    || d4_hits+="  .claude/hooks/session-start.sh: configured language values missing from its output"$'\n'
  rm -rf "$d4_root"
else
  d4_hits+="  mktemp failed, so the hook could not be probed"$'\n'
fi
python3 - <<'PY' || d4_hits+="  .claude/settings.json: session-start.sh is not registered for every SessionStart source"$'\n'
import json
import sys

with open(".claude/settings.json", encoding="utf-8") as handle:
    groups = json.load(handle)["hooks"].get("SessionStart", [])
sys.exit(not any(
    group.get("matcher", "") in ("", "*")
    and any("session-start.sh" in hook.get("command", "") for hook in group.get("hooks", []))
    for group in groups
))
PY
if [[ -n "$d4_hits" ]]; then
  red "FAIL"; printf ': configured language does not reach the session:\n'
  printf '%s' "$d4_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': session-start.sh delivers the configured language\n'
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
  ".claude/docs/pr-review-fix-verification.md"
  ".claude/docs/address-comments-delivery.md"
  ".claude/docs/fsd-candidate-review.md"
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
section "D7: kb-teamshare import paths are bounded"
KB_IMPORT_SECTION=$(awk '/^## Import mode/ { f = 1; next } /^## / { f = 0 } f' .claude/commands/nase/kb-teamshare.md)
d7_hits=""
for needle in \
  "Import Path Hardening" \
  "canonical path is inside" \
  "Skip symlinks entirely" \
  "Never use an imported path string directly as a write target" \
  "Skipped (unsafe path)"; do
  if ! grep -qF -- "$needle" <<<"$KB_IMPORT_SECTION"; then
    d7_hits+="  missing: $needle"$'\n'
  fi
done
if [[ -n "$d7_hits" ]]; then
  red "FAIL"; printf ': kb-teamshare.md import mode lacks external import path hardening:\n'
  printf '%s' "$d7_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': kb-teamshare import path hardening present\n'
fi

# ---------- D8: imported skill wrappers cannot inject frontmatter -----------
section "D8: kb-teamshare import wrapper frontmatter is sanitized"
d8_hits=""
for needle in \
  "YAML double-quoted strings" \
  "Strip control characters" \
  "Never copy imported frontmatter blocks wholesale"; do
  if ! grep -qF -- "$needle" <<<"$KB_IMPORT_SECTION"; then
    d8_hits+="  missing: $needle"$'\n'
  fi
done
if [[ -n "$d8_hits" ]]; then
  red "FAIL"; printf ': kb-teamshare.md import mode lacks generated-wrapper frontmatter sanitization:\n'
  printf '%s' "$d8_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': kb-teamshare import wrapper frontmatter sanitization present\n'
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
# A phrase that denies writing at all governs the whole line, wherever it sits.
no_write = re.compile(
    r"\b(never writes?|read-only|do not write|does not write|without writing|will later|follow-up)\b",
    re.I,
)
# A read verb only governs the clause it is in, so "read back the last entry" cannot
# cancel an append named in the clause before it.
read_verb = re.compile(r"\b(read|scan|search|list|surface|show|report|flag)\b", re.I)
clause_split = re.compile(r"(?<=[.!?])\s+|\s+[-–]\s+|,\s+")
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
        if no_write.search(line):
            continue
        # The whole line first, then each clause of it, because either granularity
        # alone has a blind spot. An incidental read verb elsewhere in the line
        # ("read back the last entry") cancels the line-level test, and a path and
        # its write verb sitting in different clauses defeat the clause-level one.
        offender = next(
            (
                s
                for s in [line] + clause_split.split(line)
                if durable_path.search(s)
                and write_verb.search(s)
                and not read_verb.search(s)
            ),
            None,
        )
        if offender:
            hits.append(f"  {path}:{lineno}: {offender.strip()}")
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
    ".claude/docs/kb-gap-detect.md": "--auto",
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

# kb-review is model-invocable, so this sentence is the only thing keeping `--gaps --auto`
# from running unasked. Frontmatter used to enforce it when gap detection was its own command.
gap_rule = "It runs only when the user explicitly asks for it, never from model routing or another command."
review = Path(".claude/commands/nase/kb-review.md")
if gap_rule not in review.read_text(encoding="utf-8"):
    hits.append(f"  {review}: gap mode lost its manual-only rule")

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
    # Match the section by its title, not its number, so renumbering the
    # workflow does not silently turn this gate into a no-op.
    after_heading = re.split(r"^### [\w.]+\. Need Attention scan \+ action menu$", text, flags=re.M)[1]
    need_attention = re.split(r"^### [\w.]+\. Closing block$", after_heading, flags=re.M)[0]
except IndexError:
    hits.append(f"  {path}: missing the Need Attention or Closing block section heading")
else:
    if re.search(r"tech[- ]digest", need_attention, re.IGNORECASE):
        hits.append(f"  {path}: Need Attention mentions tech-digest; keep it out of the action menu")

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
import sys

sys.path.insert(0, "tests/lib")
import workspace_skip  # noqa: E402

paths = [
    Path(".claude/commands/nase/fsd.md"),
    Path(".claude/docs/fsd-intake-and-setup.md"),
    Path(".claude/docs/fsd-phase-decomposition.md"),
    Path("workspace/skills/deploy-alpha.md"),
]
unsafe = re.compile(r"workspace/tmp/[^\n\x60]*\{(?:branch_name|branch)\}")
hits = []
for path in paths:
    if not workspace_skip.present(path, hits):
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

# ---------- D15: critical workflows preserve KB lookup markers -------------
section "D15: critical KB workflows preserve lookup markers"
d15_hits=$(python3 - <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, "tests/lib")
import workspace_skip  # noqa: E402

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
    if not workspace_skip.present(path, hits):
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
    "category",
    "order",
    "model",
    "effort",
    "context",
    "agent",
    # Claude-native, like the rest: a command that only a human should trigger
    # (restore, kb-teamshare, the reporting commands) sets this so its description
    # stops sitting in every request's context. The skill side has always
    # allowed it; the command side now matches.
    "disable-model-invocation",
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
        "## 13. Spawn Directive (copy verbatim)",         # the block spawn sites copy
    ],
    ".claude/docs/discuss-pr-analysis.md": [
        "§11",                                       # §11 block reference
        "§13, copied verbatim into the prompt",      # inline directive @ Step 5b spawn
        "trace-shape self-check",                         # self-check call site(s)
        "§12",                                       # §12 self-check reference
    ],
    ".claude/docs/discuss-pr-output.md": [
        "§13 copied verbatim",                       # inline directive @ optional deep-dive spawn
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
        "still continue into Step 8 with `comments: []`",
        "**Cannot-approve conditions (any number of drafts):**",
        "exactly one sentence in every state",
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
import sys

sys.path.insert(0, "tests/lib")
import workspace_skip  # noqa: E402

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
    ".claude/docs/kb-gap-detect.md": [
        "verification triad",
        "current-state reconciliation",
        "admitted drafts",
    ],
    ".claude/commands/nase/kb-teamshare.md": [
        "verification triad",
        "staged proposal",
    ],
    ".claude/docs/fsd-pr-delivery.md": [
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
    if not workspace_skip.present(path, hits):
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
    ".claude/docs/kb-gap-detect.md": [
        "**Source:** detected by /nase:kb-gap-detect",
        "**Tags:** gap-detected",
    ],
    "workspace/kb/.domain-map.md": ["last-loaded:"],
}.items():
    path = Path(filename)
    if not workspace_skip.present(path, hits):
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
        "Comment density as a design signal",
    ],
    ".claude/docs/fsd-implementation-loop.md": [
        ".claude/docs/code-comment-policy.md",
        "Default to none",
        "comment_quality",
    ],
    ".claude/docs/fsd-candidate-review.md": [
        ".claude/docs/code-comment-policy.md",
        "necessity and concision",
    ],
    ".claude/docs/address-comments-delivery.md": [
        ".claude/docs/code-comment-policy.md",
        "Default to none",
    ],
    ".claude/docs/pr-review-fix-verification.md": [
        ".claude/docs/code-comment-policy.md",
    ],
    ".claude/docs/review-mode-comment-threads.md": [
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
            ".claude/docs/fsd-candidate-review.md",
            ".claude/docs/fsd-pr-delivery.md",
            ".claude/docs/fsd-closeout.md",
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

section "D25: step-numbered skills' cross-references resolve to a real step"
d25_hits=$(python3 - <<'PY'
import re
from pathlib import Path

# D24 only sees 'Phase N' headings. /nase:wrap-up numbers its workflow as a plain ordered
# list and every caller spells the reference 'Step N', so both halves of that gate miss it:
# CLAUDE.md, three shared docs, and today-stats.py all routed to a 'Step 4e' that the
# renumbering to 1-14 had already deleted, and the drift read as ordinary prose.
SKILLS = {
    "wrap-up": ".claude/commands/nase/wrap-up.md",
}
ROOTS = (Path(".claude"), Path("CLAUDE.md"))
SCAN_SUFFIXES = (".md", ".py", ".sh")

LIST_ITEM = re.compile(r"^([0-9]+)\. ")
hits = []

files = []
for root in ROOTS:
    if root.is_file():
        files.append(root)
    elif root.is_dir():
        files.extend(
            p for p in sorted(root.rglob("*")) if p.is_file() and p.suffix in SCAN_SUFFIXES
        )

for skill, entrypoint in SKILLS.items():
    path = Path(entrypoint)
    if not path.exists():
        hits.append(f"  {entrypoint}: missing")
        continue
    steps = {
        m.group(1)
        for line in path.read_text(encoding="utf-8").splitlines()
        if (m := LIST_ITEM.match(line))
    }
    if not steps:
        hits.append(f"  {entrypoint}: no numbered workflow steps found")
        continue
    # Matches the backticked and bare spellings alike; the optional decimal and letter
    # suffix are what a stale sub-step reference looks like.
    reference = re.compile(
        rf"/nase:{re.escape(skill)}\x60?\s+Step ([0-9]+(?:\.[0-9]+)?[a-z]?)\b"
    )
    for file in files:
        text = file.read_text(encoding="utf-8", errors="replace")
        for label in sorted(set(reference.findall(text))):
            if label not in steps:
                hits.append(
                    f"  {file}: '/nase:{skill} Step {label}' has no matching step "
                    f"in {entrypoint} (steps are 1-{max(steps, key=int)})"
                )

print("\n".join(hits))
PY
)
if [[ -n "$d25_hits" ]]; then
  red "FAIL"; printf ': step-numbered cross-references point at steps that do not exist:\n'
  printf '%s\n' "$d25_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': wrap-up step cross-references resolve\n'
fi

# ---------- Result ---------------------------------------------------------
ws_skip_summary
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
