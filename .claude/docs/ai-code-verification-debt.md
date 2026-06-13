# AI Code Verification Debt

Shared doctrine for AI-assisted code review, review-comment handling, and tech-debt audit workflows.

Use this doc from command files instead of redefining AI provenance, evidence tiers, or verification-debt scoring in each skill.

## Definition

AI code verification debt is the unresolved risk left when AI-assisted code, AI-authored review feedback, or AI-generated fixes are accepted without enough independent evidence.

Track it when any of these are true:
- AI provenance is explicit.
- A bot or AI reviewer made the claim being acted on.
- A human asks the agent to verify whether previous AI work was sufficiently checked.
- A tech-debt audit finds code that looks finished but lacks tests, scanner evidence, runtime proof, or documented constraints for the risk it carries.

Do not treat "AI-looking code" as AI-authored. Guessing authorship creates noisy audits and unfair blame.

## Explicit AI Provenance

Record `ai_provenance = explicit` only when at least one concrete artifact says so:
- Git author, committer, co-author, or trailer names a known AI agent or bot.
- PR body, commit message, branch metadata, review comment, session log, or tool log says the change was AI-generated or AI-assisted.
- GitHub login is a known bot or AI-reviewer account such as `copilot-pull-request-reviewer`, `chatgpt-codex-connector`, `coderabbitai`, `claude`, `sonarcloud`, or a login ending in `[bot]` / `-bot`.
- Local workspace logs explicitly connect the session to the change under review.

Otherwise record `ai_provenance = none-found`. Never infer AI provenance from style, formatting, verbosity, or perceived code shape.

## Risk Tiers

Use these tiers for both PR comment dossiers and audit findings:

| Tier | Meaning | Required evidence before action |
| --- | --- | --- |
| `P0 security/data-loss` | Auth, tenant isolation, secret handling, destructive writes, data corruption/loss | Head/base diff, caller impact, tests or scanner evidence, and a second-opinion verifier before mutation when available |
| `P1 correctness/runtime` | Crashes, wrong results, migration/runtime failures, broken contracts | Head/base diff, caller/consumer trace, related test or explicit missing-test note |
| `P2 architecture/maintainability` | Coupling, duplication, unclear interfaces, stale patterns, code-smell accumulation | Repo/KB pattern check plus concrete file evidence |
| `P3 style/nit` | Naming, formatting, local clarity only | Concise evidence that the change is safe, or a decline if it adds churn without value |

Escalate one tier when explicit AI provenance exists and the change has no matching verification evidence.

## Comment Dossier Contract

Before accepting, declining, or replying to a review thread, produce a bounded dossier:

```text
Thread: <file:line + reviewer/comment id>
Premise: <what the reviewer is claiming>
Risk: <P0/P1/P2/P3 + reason>
Evidence checked:
- comment chain: <summary>
- PR diff/base/HEAD: <summary>
- KB/repo rule: <matched doc or none>
- caller/dependency impact: <summary>
- tests/scanners: <available or missing>
- explicit AI provenance: <artifact or none-found>
Decision: accept | decline | reply-only | ask-user
Action: <code change or reply draft or exact question>
Verification: <command/check needed after action>
```

Rules:
- Every unresolved thread gets a dossier before classification.
- Missing evidence is allowed only if it is named explicitly in the dossier and drives `ask-user`, `reply-only`, or a conservative verification step.
- AI provenance stays explicit-only; record `none-found` instead of inferring from style.
- Declines must prove the reviewer premise is false, already addressed, out of PR scope, or lower-value than the risk it introduces.
- Accepts must name the post-change verification needed.
- P0/P1 or uncertain classifications require a second-opinion verifier before user confirmation when available.

## Verification-Debt Scoring

For tech-debt audits, add these fields to each AI verification-debt finding:

```text
ai_provenance: explicit | none-found
verification_gap: missing-tests | missing-scanner | missing-runtime-proof | missing-contract-doc | stale-review-thread | surviving-finding
risk: P0 security/data-loss | P1 correctness/runtime | P2 architecture/maintainability | P3 style/nit
owner_hint: <module/team/file owner if discoverable, otherwise unknown>
age: <days since explicit AI artifact or first evidence, otherwise unknown>
effort: S | M | L | XL
roi: high | medium | low
recommended_next_check: <smallest evidence-producing command, test, scanner, or code read>
```

Prioritize repayment by `risk x confidence x age / effort`. Do not inflate severity only because AI was involved; inflate when AI provenance combines with missing verification around a real risk.

## Research Notes

- Stack Overflow Developer Survey 2025 shows broad AI adoption and uneven developer trust: https://survey.stackoverflow.co/2025/ai
- DORA 2025 describes high AI adoption but emphasizes process, data, small batches, and quality systems: https://blog.google/innovation-and-ai/technology/developers-tools/dora-report-2025/
- METR's 2025 randomized study found experienced OSS developers took longer with early-2025 AI tools in the measured setting: https://metr.org/blog/2025-07-10-early-2025-ai-experienced-os-dev-study/
- A large empirical study of verified AI-authored commits found many detected issues survived at HEAD, especially security and runtime issues: https://arxiv.org/html/2603.28592v1
- Small batches and automated checks remain key safety rails: https://dora.dev/capabilities/working-in-small-batches/ and https://google.github.io/eng-practices/review/developer/small-cls.html
