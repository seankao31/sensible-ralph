# `.sensible-ralph-base-sha` is written only by the orchestrator, not by `/sr-spec`

## Context

ENG-279 unified the per-issue lifecycle: `/sr-spec` step 7 now creates the
branch+worktree and commits the spec on it. `/prepare-for-review` reads
`.sensible-ralph-base-sha` to scope the impl diff, codex review, and handoff
summary. At spec time there are no impl commits yet — there's nothing to scope.
At dispatch time the orchestrator may merge in-review parents before invoking
`/sr-implement`; those parent commits should NOT appear in the impl diff.

## Decision

`/sr-spec` step 7 captures `SPEC_BASE_SHA` as a **shell variable only** (not
written to disk). The orchestrator writes `.sensible-ralph-base-sha = $(git
rev-parse HEAD)` AFTER parent merges complete — post-merge HEAD in all paths.

## Reasoning

If `/sr-spec` wrote the file at branch creation:

1. **Codex diff contamination:** When the orchestrator later merges in-review
   parents, the base-sha would still point at the branch-creation SHA. Parent
   commits would appear in `/prepare-for-review`'s impl diff — reviewed
   elsewhere but reviewed again here. This is the exact INTEGRATION-mode bug
   ENG-279 set out to fix.

2. **No useful purpose at spec time:** At step 10 (codex spec gate), the
   needed scoping is `SPEC_BASE_SHA..HEAD` which is just the spec commits from
   this session. A shell variable is sufficient; writing a file would be
   premature.

Single-write ownership from one actor (the orchestrator) avoids the two-writer
race and keeps the file's semantics clean: it always means "the commit just
before impl started, after any parent merges."

## Consequences

- `/sr-spec` must NOT write `.sensible-ralph-base-sha`. Future changes to the
  spec flow should preserve this invariant.
- The orchestrator must write the file on BOTH the reuse path (both_exist) AND
  the fallback create path (neither), covering every dispatch shape.
- `/prepare-for-review`'s fallback (no `.sensible-ralph-base-sha` file →
  detect trunk) is preserved for interactive sessions outside the orchestrator.
