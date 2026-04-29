# `/sr-spec` soft-warns when an existing `blocked-by` parent is not yet Approved

## Context

A Linear issue handed to `/sr-spec ENG-X` may already have `blocked-by`
relations set on it — typically created by `/sr-spec` on a parent that named
ENG-X as a child, or set manually by the operator in the Linear UI. Until now,
`/sr-spec` proceeded into the design dialogue without inspecting those
parents' current states.

The orchestrator's dispatch-time preflight (`/sr-start` chain-runnable check)
and `/close-issue`'s "all blockers Done" gate together enforce
*execution-time* correctness — but neither catches the case where a child is
*being designed* against a parent whose own spec is still in flux. Designing
against an unfrozen parent risks rework when the parent's spec lands and the
surface (interfaces, scope, naming) shifts under the child.

## Decision

At step 2 (Explore project context), if `ISSUE_ID` is set, `/sr-spec` fetches
the issue's existing `blocked-by` relations via `linear_get_issue_blockers`
and inspects each parent's current state. **Soft-warn** for any parent whose
state is not in
`{$CLAUDE_PLUGIN_OPTION_APPROVED_STATE,
  $CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE,
  $CLAUDE_PLUGIN_OPTION_REVIEW_STATE,
  $CLAUDE_PLUGIN_OPTION_DONE_STATE}`. The warning lists each un-frozen blocker
(ID + current state) and asks whether to proceed anyway or pause to spec the
parent first. The check is advisory — the operator may proceed if they
understand the rework risk.

## Reasoning

Three options were considered:

1. **Hard block** the child until every prerequisite is Approved.
2. **Soft warn** at design time, no enforcement.
3. **Gate at Approved-or-better**, identical to (1) but allow proceeding past
   the warning manually.

Option 1 was rejected because legitimate parallel design exploration is a
real pattern: sometimes specing the child clarifies what the parent needs, and
forcing strict sequencing creates unnecessary friction. Option 3 collapses to
option 2 in practice (any "manual override" mechanism is just a soft warn
with extra ceremony).

Option 2 was chosen because the **load-bearing** safety check is the
dispatch-time preflight — that's where executing against an unfinished parent
would actually cause damage. At design time, the consequence is at most
rework, not corruption. The cheapest moment to flag risk is at the start of
the dialogue (where the operator can pivot freely); the cheapest safety net
is the existing dispatch gate. Layering an advisory warning on top of an
enforcing gate gives early visibility without sacrificing flexibility.

**Why step 2 and not step 6:** The realistic shape of an un-frozen blocker is
a relation that already existed on the issue when `/sr-spec` started — set
either by an upstream `/sr-spec` call on the parent, or manually in the
Linear UI. Prerequisites identified mid-dialogue (the `/sr-spec` invocation
proposing or the user volunteering "this should also depend on ENG-Y") are
rare in current practice. Anchoring the check on existing relations at
project-context exploration time gives a single, complete inspection point,
rather than a probabilistic per-mention check during design.

The post-Approved set used as the warning predicate matches the lifecycle
doc's definition of "spec frozen" states (`docs/design/linear-lifecycle.md`),
so the warning's semantics stay consistent with the rest of the state
machine. `Canceled` and `Duplicate` blockers fall outside this set and would
also trigger the warning — appropriate, since the dispatch preflight already
refuses chains that include them and the operator must explicitly remove the
relation before dispatch.

## Consequences

- Blocker-state inspection runs once at step 2, against the issue's
  pre-existing `blocked-by` set. A parent whose state changes between step 2
  and finalize is not re-checked — the dispatch preflight handles drift.
- Prerequisites identified mid-dialogue and added in step 11 do not trigger
  the soft-warn. If this becomes a real pattern, extend the check to cover
  step-11 additions; otherwise leave it scoped to existing relations.
- Without-arg invocations (no `ISSUE_ID` until step 6.5) skip the check —
  there are no pre-existing blockers to inspect.
- Future asymmetry watch: if the dispatch preflight gains a "warn but proceed"
  affordance, the design-time warning becomes redundant and should be
  revisited. The current design assumes dispatch-time enforcement remains hard.
