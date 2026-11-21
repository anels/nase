# Design Comprehension Read

Shared contract for the naive-reader check that `/nase:design` runs after the scoring loop reaches APPROVED. It tests whether a reader who has never seen this project can follow the design document alone. The scoring verifier cannot test this, because it is handed the criteria and the cited references and so already has the context a new reader lacks.

Callers: `.claude/commands/nase/design.md` (interactive) and `.claude/docs/design-auto-mode.md` (auto). Review mode (`--review`) and grill mode (`--grill`) do not run it. Each caller points here and adds only what is specific to its mode.

## When it runs

- Once, after the scoring loop returns APPROVED. Skip it when the loop ended without APPROVED, such as auto mode's `max-iterations`, because that draft is still owned by the loop. Never run it inside the loop, because the loop still rewrites the text.
- A second run happens only after the main thread fixed a `blocking` finding from the first run. That is the cap: two runs in total.

## Input

Write the current draft to `workspace/tmp/comprehension-{slug}-{YYYYMMDD-HHMMSS}.md` and pass its absolute path. Delete that file when the check ends, including when it ends in failure, because it is a full copy of the design. If the session is interrupted the file stays under `workspace/tmp/`, which git ignores. The reader gets that one path and nothing else. Do not pass the authoring reasoning, the criteria, the scores, or any cited file. A path or link that the document cites counts as defined for the reader.

The reader is the persisted `nase-comprehension-reader` agent (`.claude/agents/nase-comprehension-reader.md`, `tools: Read`). Spawn it with one fresh `Agent` call, never a reused agent, so it carries no brief from an earlier call. The tool list cannot limit which file the agent reads, so "read only this path" is an instruction. `tests/live/probe-isolation.sh` checks the part a tool list can prove, which is that the reader cannot see the parent's context.

## Output and what the main thread does

The reader returns the `.claude/docs/subagent-output-contract.md` block. `Facts` holds one `Paraphrase:` bullet per `##` section, plus one for `### Intent`. `Risks` holds findings tagged `blocking`, `suggestion`, or `nit`, the same words `design-grill-mode.md` uses. A result with no `Paraphrase:` bullet is malformed, so treat it as an empty result.

1. Compare each paraphrase with the design's `### Intent` section and its goals. The reader paraphrases `### Intent` as its own entry, as its agent file requires. A paraphrase that says something the design did not mean is a `blocking` finding, even when the reader raised none. The reader cannot know the intent, so only the main thread can see this gap.
2. A `blocking` finding means the design is not clean. Fix it in the draft, using whatever the caller's mode allows for gaps it cannot close.
3. A fix can break a criterion, and the main thread wrote it. Score the changed draft once more with the scoring verifier before the second read. If that score is not APPROVED, report the failing criteria with the comprehension result and stop there.
4. Run the reader once more on the new draft. If a `blocking` finding remains, show it as written and say the design has an unresolved comprehension gap. Do not run a third time, and do not report the design as clean.
5. A `suggestion` or `nit` goes into the summary with the section it names. It does not block.

## Failure handling

Follow `.claude/docs/review-modes.md → Error handling`. An empty or malformed result is not a pass. Re-request once and name the missing output. After a second failure, record `comprehension read: not run` in the summary and leave the verdict as the scoring loop set it. When the failed run was the re-run after a fix, also list the first run's `blocking` findings as `fixed, unconfirmed`, because the main thread made that fix without a confirming read. Never write "reader found nothing" for a run that returned no result. `Verdict: blocked` means the reader could not open the file, so check the path is absolute and the file exists before the re-request.

## Boundary

This check finds gaps a new reader hits. It does not show the design is correct, and the scoring verifier still owns correctness. It reads the draft as it stands when the check runs, so text that auto mode adds later from Step 4.5 answers is not read. The method is adapted from the Comprehension reviewer in google/elephant-goldfish-model (`agents/comprehension.md`, "Paraphrase First"), which reports no measurement that the stage improves designs, so the value here is unproven until real designs have been through it.
