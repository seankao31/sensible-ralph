# Tighten ralph-implement Step 3 with explicit scope-adherence checkpoint

## Context

`ralph-implement`'s Step 3 ("Implement per the PRD") is terse:

> Follow agent-config conventions: TDD (via `superpowers:test-driven-
> development`), `superpowers:systematic-debugging` on failures, smallest
> reasonable changes. The PRD drives the scope.

This delegates the implementation discipline to external skills but doesn't
repeat the scope-adherence checkpoint at an explicit point. The ENG-246
Pass 1 audit flagged this as a thin-spot in an otherwise sound skill: the
red-flag list catches catastrophic deviations (missing ISSUE_ID, test
failures) but does not gate on "implementation stayed in scope" before
handoff.

Sean has historically caught scope-creep — mid-implementation rewrites,
adding features the spec didn't ask for, "while I'm here" refactors — only
after the fact, during `/prepare-for-review`'s codex review or the merge
itself. The escape-hatch rule "Scope deviation" (see
`docs/usage.md`) already covers this as a
session-exit trigger, but the ralph-implement skill itself doesn't prompt
a check against that trigger.

## Decision

Add an explicit scope-adherence mini-checkpoint at the end of Step 3,
before Step 4 (test verification):

> Before moving to Step 4, cross-check your implementation against the PRD:
> - Every deliverable in the PRD's scope section is implemented.
> - Nothing is implemented that the PRD did not ask for.
> - Any decisions made mid-implementation that the PRD did not specify are
>   recorded (either inline in the code, in the commit messages, or via
>   `superpowers:capture-decisions`).
>
> If you find in-scope items missing, loop back. If you find out-of-scope
> work, decide: does it need to be there for the in-scope work to function?
> If yes, it's justified. If no, revert it — the bar for "while I'm here"
> additions in an autonomous session is higher than interactive. See
> `docs/usage.md` "Scope deviation" for
> the escape-hatch trigger.

## Consequences

Positive:
- Makes the playbook's "Scope deviation" trigger actionable from inside
  the skill — the agent is prompted to self-check before handoff rather
  than hoping codex catches it.
- Reduces cross-task integration cost: scope-clean branches rebase onto
  parent branches more predictably.
- Composes cleanly with the other ADR from this recon
  (`verification-before-completion` at Step 4). Step 3 checkpoint catches
  scope bloat; Step 4 gate catches test failures.

Negative:
- Adds text to an already-terse skill. Must be brief enough not to mask
  the existing red-flag list.
- Self-review is inherently weaker than external review; codex still
  catches scope bloat at `/prepare-for-review`. This checkpoint is a
  cheaper first line of defense, not a replacement.

## Alternatives considered

- **Move scope-check to `/prepare-for-review` instead.** Rejected —
  `/prepare-for-review` already runs codex review, which does catch
  scope bloat. The gap is the gap between Step 3 completion and
  `/prepare-for-review` invocation, where mid-session course-correction is
  cheaper than fixing post-review.
- **Add a dedicated "scope review" subagent invocation.** Rejected —
  over-engineered for a self-check. Two bullet points at the end of
  Step 3 do the work.

## Provenance note

`addyosmani/agent-skills/incremental-implementation` ships a
"NOTICED BUT NOT TOUCHING" protocol that addresses the same gap this
ADR does, with a ready-made formulation for surfacing adjacent-scope
observations without acting on them. The Pass 1 recon initially
dismissed that skill as "duplicates upstream," which caused this ADR
to reinvent the primitive rather than adopt it. The recon has been
corrected (see Cross-cutting finding #7 on framing bias). A follow-up
may consolidate this Step 3 checkpoint with the NOTICED formulation
once the broader prompt-lift work lands (ENG-260).

## Scope of this ADR

Bounded to `ralph-implement/SKILL.md` Step 3 text. No changes to:
- The red-flag list in the skill.
- `/prepare-for-review` or its codex gate.
- The playbook's enumerated exit triggers.
