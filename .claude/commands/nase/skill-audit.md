---
name: nase:skill-audit
description: "Scan skills for injection, exfiltration, unsafe operations, supply-chain, and credential risks. Use for audit skills, skill security, or imported skills."
argument-hint: "[skill path]"
pattern: utility
category: Security & maintenance
---

Scan skill files for security risks before they can cause damage. Returns PASS/WARN/FAIL per file with specific findings.

**Input:** $ARGUMENTS — one of:
- A file path: scan that single file
- A directory path: scan all `.md` files in it
- `all`: scan `workspace/skills/` + `.claude/commands/nase/` + `.claude/commands/nase/workspace/`
- Empty: same as `all`

## Step 0 — Language preflight (MUST run first, non-negotiable)

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Fixed severity labels (`PASS`, `WARN`, `FAIL`) stay English.

## Scan Categories

`.claude/scripts/skill-audit-scan.py` owns the deterministic patterns, category names, source lines, severities, and initial verdicts for Categories 1-6. A Category 1, 2, 4, or 6 lead is `FAIL`; Category 3 and 5 leads are `WARN`. The scanner also emits a Category 7 review lead when Categories 1, 2, 4, or 5 expose a dangerous surface. Category 7 is always WARN-only.

Do not mechanically repeat the Category 1-6 regex scan. The scanner is a lead generator, not a completeness proof. The model has three review jobs:

1. Verify each emitted lead in its surrounding section. Dismiss it only when the matched text is clearly quoted, explanatory, non-executable, placeholder data, or protected by an explicit user-confirmation step. Record the dismissal reason.
2. Perform the bounded semantic gap check in Step 2 for every file and record exact source lines for confirmed Category 1-6 findings that the deterministic patterns missed.
3. Evaluate Category 7 for every scanned skill against its stated read/write purpose and actual deny rules, `--disallowedTools` / SDK `disallowed_tools`, sandboxing, or PreToolUse hooks. Scanner-emitted Category 7 leads identify the highest-risk cases, but a read-only, local-only, or mutation-only skill can still merit a WARN when its privilege boundary is missing. Recommend a concrete enforcement control. `allowed-tools` frontmatter is not a blocking boundary.

## Execution

### Step 1: Run the deterministic scanner

```bash
mkdir -p workspace/tmp
target=${ARGUMENTS:-all}
scan_status=0
python3 .claude/scripts/skill-audit-scan.py --format json "$target" > workspace/tmp/skill-audit.json || scan_status=$?
if [ "$scan_status" -gt 1 ]; then
  exit "$scan_status"
fi
```

The scanner resolves a file, a directory recursively, or `all` using the paths in **Input**. Exit `1` means one or more deterministic FAIL leads were emitted; it is audit data, not a scanner error. Exit `2` is an invocation error.

### Step 2: Verify leads and semantic gaps

Read `workspace/tmp/skill-audit.json` and every target file once. The deterministic scanner produces reproducible leads; a clean scanner result does not prove absence.

- For emitted leads, read the surrounding section needed to confirm or dismiss the finding. Preserve the scanner's file, line, category, severity, pattern, and reason fields for confirmed leads.
- For every file, semantically inspect executable fences and instructions involving shell/subprocess execution, file mutation, network sends, package installation, credentials, or permission boundaries. Check equivalent quoted, split-line, absolute-path, and indirect forms instead of hand-running the scanner's regexes again.
- A source-line semantic check may confirm a Category 1-6 finding that the scanner did not emit. Record it as `manual semantic check`, with the exact line or section and reason.
- Evaluate Category 7 for every file, including scanner-clean files, against the documented deny-rule, sandbox, and hook boundaries.

### Step 2.5: Optional Semgrep supplement

Follow `.claude/docs/cli-tooling.md`. Probe with `python3 .claude/scripts/tool-availability.py --group review --format json`. The native 7-category scan remains canonical; `semgrep` is only a supplement.

Use `semgrep` when available for executable snippets or referenced helper scripts, especially injection, exfiltration, unsafe subprocess, and credential patterns. The native scan stays the canonical deterministic lead source. Do not mark a file PASS only because `semgrep` is clean, and do not treat a Semgrep result alone as a finding; confirm the exact source line semantically.

### Step 3: Determine verdict per file

- **PASS** - no scanner or manual findings after full semantic verification
- **WARN** - only confirmed WARN findings
- **FAIL** - at least one confirmed FAIL finding

### Step 4: Report

```text
## Skill Security Audit - {YYYY-MM-DD}

Scanned: {N} files

### Results

| File | Verdict | Findings |
|------|---------|----------|
| `workspace/skills/foo.md` | PASS | - |
| `workspace/skills/bar.md` | WARN | 1 prompt injection pattern |
| `workspace/skills/baz.md` | FAIL | 1 command injection, 1 credential exposure |

### Details (WARN and FAIL only)

#### `workspace/skills/bar.md` - WARN
- [WARN] **Prompt Injection** (line 15): confirmed scanner lead - attempts to override Claude's behavior

#### `workspace/skills/baz.md` - FAIL
- [FAIL] **Command Injection** (line 8): confirmed scanner lead - downloads and executes untrusted script
- [FAIL] **Credential Exposure** (line 22): confirmed scanner lead - hardcoded API key

### Summary
- {N} PASS, {N} WARN, {N} FAIL
- {recommendation: "All clear" or "Remove/quarantine FAIL files before use"}
```

## Mitigation: permission deny rules

Claude Code permissions support allow, ask, and deny rules. Deny rules are evaluated before ask/allow and are enforced by Claude Code, not by the model. A bare deny rule such as `Bash` removes that tool from Claude's context; scoped rules such as `Bash(git push *)` keep the tool available but block matching calls.

Use permission deny rules, `--disallowedTools` / SDK `disallowed_tools`, sandboxing, or PreToolUse hooks for Categories 1, 2, 4, 5, and 7. `allowed-tools` in frontmatter only pre-approves matching tools and does not block anything else.

### Settings shape

```json
{
  "permissions": {
    "deny": [
      "Bash(git push *)",
      "Bash(curl *)",
      "WebFetch",
      "mcp__plugin_slack_slack__slack_send_message"
    ]
  }
}
```

Rule names match registered tool identifiers (e.g. `Bash`, `Edit`, `Write`, `WebFetch`, `WebSearch`, and fully-qualified `mcp__<server>__<tool>` form for MCP tools). Prefer scoped Bash rules over blanket `Bash` when the skill still needs safe read/build commands.

### Recommended profiles

| Skill purpose | Suggested enforcement |
|---|---|
| Read-only KB / search / status report | Run in plan/read-only mode; deny `Edit`, `Write`, external write MCP tools, and risky Bash mutations |
| Local-only mutation (file edits, no network) | Deny `WebFetch`, web-search tools, and external write MCP tools; keep repo-local Bash scoped to build/test/git read commands |
| Web research only (no local writes) | Deny `Edit`, `Write`, repo mutation Bash, and external write MCP tools |
| Single-MCP-server skill (e.g. Slack draft only) | Deny other MCP write tools plus repo mutation Bash; allow only the needed read/draft tools |
| Destructive/local cleanup skill | Prefer sandbox/worktree isolation plus PreToolUse hooks; deny broad filesystem delete commands unless exact paths are guarded |

### Reporting the recommendation

For every Category 7 finding, the audit report should include a ready-to-paste permission snippet or hook recommendation, e.g.:

```json
{
  "permissions": {
    "deny": [
      "Bash(git push *)",
      "WebFetch"
    ]
  }
}
```

If a setting would be too broad for the whole workspace, recommend a PreToolUse hook or running the skill in a restricted permission mode instead of weakening the rule.

## Notes

- This scan is pattern-based, not a full static analysis. It catches obvious threats but can miss obfuscated attacks.
- False positives are possible — a skill teaching about security might mention `rm -rf` as an example. Use judgment: is the pattern in a code block meant to be executed, or in explanatory text?
- When called from `/nase:kb-merge`, FAIL files are blocked from import. WARN files are flagged but importable after user confirmation.
- Run periodically as hygiene: `/nase:skill-audit all`
