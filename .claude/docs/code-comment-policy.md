# Code Comment Policy

## Contents

- The bar
- What earns a comment
- What never earns a comment
- Shape, when one is warranted
- Existing comments
- Repos that mandate documentation
- When a reviewer asks for a comment

Shared rule for every workflow that writes or edits source code: `/nase:fsd` Phase 4,
`/nase:address-comments` Phase 6, `/nase:simplify` Steps 3/5/6. Owns when a comment is warranted
and what shape it takes. `/nase:simplify` applies it in the removal direction - it deletes and
repairs comments rather than adding them - and carries it in both its cleanup-target list and
the simplifier dispatch prompt, so a change to its comment behavior has to touch both.

The cost of a comment is not the moment it is written - it is every future reader who must
decide whether it still tells the truth, and every future editor who must keep it in sync.
A comment that restates the code charges that toll forever and returns nothing.

## The bar

Default to no comment. `CLAUDE.md → Code Quality Standards` and
`workspace/kb/general/clean-code.md` set this default; this doc makes it decidable.

The default answers "should I write one unprompted", so an explicit request outranks it: when
the user asks for comments, write them. The shape rules below still apply - a request for
comments is not a request for narration.

**Deletion test.** Delete the comment you are about to write. If everything it said is still
recoverable from the identifiers, the control flow, the types, the test names, or `git log`,
it was not carrying information - leave it deleted. Write it only when deletion loses a fact
that lives outside the code.

**Try these first, in order.** Each one encodes the fact permanently instead of describing it:

1. A more precise name (`retry_after_throttle` beats `delay` + a comment)
2. An extracted function whose name is the sentence you were going to write
3. A type, enum, or assertion that makes the illegal state unrepresentable
4. A test whose name states the rule (`rejects_negative_quantity`)

If one of these removes the need, take it instead of the comment - and, when a reviewer asked
for the comment, say in the reply which one you used.

## What earns a comment

Only facts whose source is outside the diff. Each must carry its concrete anchor:

| Class | Anchor it must name |
|---|---|
| Invariant or precondition the type system cannot express | the caller or contract that guarantees it |
| Workaround for an external defect | bug ID, vendor + version, or spec section |
| Deliberate choice where the obvious alternative is wrong | what specifically breaks under the alternative |
| Domain or regulatory rule originating outside the repo | the rule's name or source |

An anchorless comment in one of these classes is a guess wearing a fact's clothing. Find the
anchor or drop the comment.

## What never earns a comment

- Restating the statement below it (`// increment the counter`)
- Section banners and decorative dividers
- Change narration or attribution: `// added per review feedback`, `// fixed in PR #123`,
  `// new logic`. The diff, commit message, and PR already carry this, and it rots the moment
  the next change lands.
- `TODO` without both an owner and a tracking link
- Commented-out code - delete it; `git log` is the archive
- Docstrings that only re-spell the signature

## Shape, when one is warranted

- One sentence. Two lines maximum. Above the code, not trailing it, unless the repo does otherwise.
- Lead with the reason, not the mechanism. The code already shows the mechanism.
- Describe the code as it now stands, in present tense. A comment is not a changelog entry.
- Match the surrounding file's comment style, marker, and language.

Before - restates the loop, then buries the one fact worth keeping:

```
// Loop through items and skip the null ones because null items would crash the
// downstream parser, so we filter them here before calling parse().
```

After - drops everything the code already shows and keeps the anchored reason:

```
// Upstream feed emits null rows during partial ingestion (PROJ-4412).
```

## Existing comments

Editing code under a comment makes that comment yours. Update it to match the new behavior or
delete it - never leave it drifting. The exception is drift you did not cause: when a comment
you inherited contradicts the code, establish which one is wrong before touching either. A
comment stating an invariant the code no longer holds is often the last surviving record of
the intended behavior, and rewriting it to match the code buries the bug. Comment/code drift is a top source of repeat review
cycles, because a reviewer who cannot tell which one is authoritative has to ask.

## Repos that mandate documentation

This policy governs explanatory comments, not a repo's documented public-API surface. When the
repo already requires doc comments on public members - an analyzer rule, a lint rule, a CI
gate, or a consistent existing convention - satisfy that convention. Do not strip mandated doc
comments in the name of concision, and do not introduce a doc-comment convention the repo does
not already have.

## When a reviewer asks for a comment

A reviewer's "please add a comment here" is a report that something was unclear, not a
specification of the fix. Apply the same bar:

- If the confusion is about *why*, and the reason is anchored outside the code, write the comment.
- If the confusion is about *what*, the comment is the wrong fix - rename, extract, or add the
  test, then say so in the reply.
- If the reviewer flagged a logic or correctness problem, a comment never resolves it. Per
  `.claude/docs/anti-rationalization.md → /nase:address-comments`, an explanation is not a fix.
