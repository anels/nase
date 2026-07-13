#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

failures=0

pass() {
  printf 'PASS  %s\n' "$1"
}

fail() {
  printf 'FAIL  %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_contains() {
  local name="$1"
  local file="$2"
  local pattern="$3"
  if grep -qE "$pattern" "$file"; then
    pass "$name"
  else
    fail "$name"
  fi
}

assert_not_contains() {
  local name="$1"
  local file="$2"
  local pattern="$3"
  if grep -qE "$pattern" "$file"; then
    fail "$name"
  else
    pass "$name"
  fi
}

ROUTING=".claude/docs/voice-profile-routing.md"

assert_contains "routing doc points to source profile" "$ROUTING" 'workspace/communication-style\.md'
assert_contains "routing has slack dm capsule" "$ROUTING" '`slack-dm`'
assert_contains "routing has PR body capsule" "$ROUTING" '`github-pr-body`'
assert_contains "routing has review comment capsule" "$ROUTING" '`github-review-comment`'
assert_contains "routing has review reply capsule" "$ROUTING" '`github-review-reply`'
assert_contains "routing has Jira capsule" "$ROUTING" '`jira-ticket`'
assert_contains "routing has Confluence capsule" "$ROUTING" '`confluence-doc`'
assert_contains "routing defers attribution to existing doc" "$ROUTING" 'Defer AI attribution to `\.claude/docs/ai-attribution\.md`'
assert_contains "routing defers PR structure to existing doc" "$ROUTING" 'Follow `\.claude/docs/pr-creation-pattern\.md` for template/default structure'
assert_not_contains "routing does not override attribution config" "$ROUTING" 'No AI attribution unless the user explicitly asks'
assert_not_contains "routing does not redefine default PR headings" "$ROUTING" 'Prefer concise sections that help reviewers'

assert_contains "CLAUDE routes external text through voice profile" "CLAUDE.md" 'voice-profile-routing\.md'
assert_contains "CLAUDE keeps attribution per-repo config" "CLAUDE.md" 'commits/PRs follow `\.local-paths` per-repo config'
assert_contains "slack shared doc uses routing" ".claude/docs/slack-draft-style.md" 'voice-profile-routing\.md'
assert_contains "style delta points future drafts to routing" ".claude/docs/style-delta-capture.md" 'voice-profile-routing\.md'
assert_contains "reference describes routing for slack style" ".claude/docs/reference.md" 'routes through `voice-profile-routing\.md`'
assert_contains "PR shared doc uses PR body surface" ".claude/docs/pr-creation-pattern.md" 'surface=github-pr-body'
assert_contains "request-review uses slack surface" ".claude/commands/nase/request-review.md" 'surface=slack-dm'
assert_contains "discuss-pr uses review-comment surface" ".claude/docs/discuss-pr-output.md" 'surface=github-review-comment'
assert_contains "address-comments uses review-reply surface" ".claude/docs/address-comments-delivery.md" 'surface=github-review-reply'
assert_contains "address-comments re-review ping uses slack surface" ".claude/docs/address-comments-delivery.md" 'surface=slack-dm'
assert_contains "FSD delivery gates use PR body surface" ".claude/docs/fsd-delivery-gates.md" 'surface=github-pr-body'
assert_contains "prep-merge uses PR body surface" ".claude/commands/nase/prep-merge.md" 'surface=github-pr-body'

assert_not_contains "request-review avoids review-this template" ".claude/commands/nase/request-review.md" 'Could you help review this\?'
assert_not_contains "request-review avoids approve-this template" ".claude/commands/nase/request-review.md" 'Could you help approve this\?'
assert_contains "request-review uses plain hyphen separator" ".claude/commands/nase/request-review.md" '\[url\] - \[TLDR\]'
assert_not_contains "request-review avoids em dash separator" ".claude/commands/nase/request-review.md" '\[url\] — \[TLDR\]'
assert_contains "PR creation preserves generated footer when configured on" ".claude/docs/pr-creation-pattern.md" 'Generated with'
assert_contains "prep-merge preserves one-time attribution prompt" ".claude/commands/nase/prep-merge.md" 'prompt once if missing'
assert_contains "commit pattern preserves per-repo attribution config" ".claude/docs/commit-push-pattern.md" '\{RepoName\}-ai-attribution'
assert_contains "attribution doc reads local path flags" ".claude/docs/ai-attribution.md" 'Workspace-root `\.local-paths` stores one line per repo'
assert_contains "attribution doc has on flag example" ".claude/docs/ai-attribution.md" 'ai-attribution=on'
assert_contains "attribution doc has config-later section" ".claude/docs/ai-attribution.md" 'Changing Config Later'

if [[ "$failures" -eq 0 ]]; then
  printf '\nvoice-profile-routing tests passed.\n'
  exit 0
fi

printf '\n%d voice-profile-routing assertion(s) failed.\n' "$failures" >&2
exit 1
