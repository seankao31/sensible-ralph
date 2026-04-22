# Ralph-spec finalization: verify at spec time, not dispatch time

## Context

`ralph-spec` produces Approved Linear issues that `/ralph-start` picks up
unattended. Three related failure modes all have the same root cause: the
dispatcher trusts `Approved` state implicitly and only re-validates a narrow
slice of the issue at preflight.

1. An issue transitioned to Approved while Done or Canceled gets silently
   reopened — ralph-start doesn't care that the transition was unusual.
2. An issue transitioned to Approved with a partial `blocked-by` set gets
   dispatched before all its prerequisites land — ralph-start trusts the
   relation graph as-fetched and will order it however the partial graph
   allows.
3. An issue transitioned to Approved in a project outside `.ralph.json`
   scope never dispatches at all, but isn't flagged either — ralph-start
   builds its queue by querying only in-scope projects, so out-of-scope
   Approved issues are simply invisible, not anomalous.

The third one is the sharpest: ralph-start's preflight *cannot* flag what it
never queries. "Preflight will catch it" is not a valid fallback for
out-of-scope state.

## Decision

`ralph-spec`'s "Finalizing the Linear Issue" section enforces three
preflight/commit gates before any state transition to `$RALPH_APPROVED_STATE`:

1. **Current-state gate** (step 2): fetch `.state.name` and `.project.name`
   in one read, branch on state before any mutation. `Done`/`Canceled` stops
   unconditionally. Already-`$APPROVED` requires explicit confirmation.
   `In Progress`/`In Review` stops (likely wrong ticket).
2. **Scope gate** (step 2): the existing issue's project must be in
   `$RALPH_PROJECTS`. Out-of-scope issues stop with a pointer to the two
   real fixes (move the issue, or widen `.ralph.json`) — not dispatch
   preflight.
3. **Blocker verification gate** (step 5): after adding each `blocked-by`
   relation with strict error handling, re-fetch the blocker set via
   `linear_get_issue_blockers` (the *same* helper the orchestrator uses)
   and compare to the expected set. Mismatch stops before the state
   transition, leaving the issue in its prior state with the mutations
   that did land reported to the user.

## Reasoning

**Why preflight before mutation, not a red-flag note at the end.** The
original draft had red-flag prose after the numbered command flow. Codex's
adversarial pass caught that an agent following the numbered commands in
order would run the preservation comment, description overwrite, relation
adds, and state transition before reading the red flags. Making state
validation a gated step 2 — *before* any Linear write — is the only way
the guards actually fire in practice.

**Why verify blockers with the same helper the orchestrator uses.** Linear's
CLI doesn't expose `--json` for `issue relation list`. Rolling our own
parser would drift from whatever the orchestrator's GraphQL query returns.
`linear_get_issue_blockers` returns exactly the set `dag_base.sh` and
`build_queue.sh` reason about, so verification sees what dispatch will see.

**Why scope validation for existing issues, not just new ones.** New issues
already go through a scope-list pick (step 3 of finalization). Existing
issues pass through unvalidated in the original draft because "ralph-start's
preflight will catch it." But ralph-start queries by project — out-of-scope
Approved issues are filtered out of the query entirely, never flagged.

## Consequences

**Do not relax any of the three gates to save round-trips.** The state fetch
+ project fetch + blocker re-fetch are the load-bearing verification. Every
guard exists because a specific failure mode was caught by review and
verified against ralph-start's actual query behavior.

**Do not move the red flags before the gates.** Future cleanup passes may
want to "consolidate" the state-check prose into a red-flag appendix —
don't. The gates live in the numbered flow because their placement *is*
the guarantee they fire.

**If adding new finalization steps, gate them the same way.** Any new
post-spec mutation (labels, assignees, project moves) that affects
whether or how `/ralph-start` picks up the issue should validate first,
fail before transition, and verify post-mutation.
