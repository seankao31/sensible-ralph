# Ralph v2: Ambiguous Outcome Handling (local_residue + unknown_post_state)

## Context

The orchestrator classifies each dispatch as `in_review`, `exit_clean_no_review`, `failed`, `setup_failed`, `local_residue`, or `unknown_post_state`. Two of these — `local_residue` and `unknown_post_state` — deliberately skip adding the `ralph-failed` Linear label and skip tainting downstream dependents. This is non-obvious: other failure outcomes DO taint, so a future agent might "fix" these two to match.

## Decision

`local_residue` and `unknown_post_state` do NOT mutate Linear state and do NOT taint descendants.

## Reasoning

**`local_residue`** fires when the target worktree path or branch already exists at the start of dispatch — the orchestrator never touched anything (it's a pre-dispatch pre-flight check). The issue itself is in fine shape in Linear; only the local environment has stale state. Adding `ralph-failed` would misrepresent a healthy issue as broken. Not tainting descendants is correct because: (a) `dag_base` only incorporates blockers in `In Review` state, so a local_residue issue (still `Approved`) would not appear in any descendant's base calculation; (b) descendants dispatch against main and proceed normally — the operator will clean up the residue and re-queue the affected issue separately.

**`unknown_post_state`** fires when `claude -p` exited 0 but the post-dispatch `linear_get_issue_state` read failed transiently. We genuinely don't know whether the session succeeded (transitioned to In Review) or stopped short. Adding `ralph-failed` and tainting when the session may have actually succeeded would destroy correct work on a transient API blip. The safer default is to expose the ambiguity and let the operator check Linear directly.

**The old behavior** for both cases was to collapse to `exit_clean_no_review`, which applied `ralph-failed` and tainted descendants. This was wrong in the `local_residue` case (operator state, not issue failure) and dangerous in the `unknown_post_state` case (can destroy a real success).

## Consequences

- A `local_residue` run does not produce any Linear artifacts — the operator's signal is `progress.json` + the `orchestrator: pre-existing worktree path or branch` stderr line.
- A `unknown_post_state` run similarly produces no label; operator checks Linear UI to disambiguate.
- Downstream issues after a `local_residue` or `unknown_post_state` still dispatch — this is intentional. If a downstream issue would fail due to a missing parent merge, it will fail on its own with a clear error; the orchestrator does not pre-emptively skip it.
- Retry semantics: both outcomes are retry-safe. Clean up the residue or wait for the transient failure to resolve, then re-run `/ralph-start`. The pre-flight check for residue will be a no-op once the path/branch is removed.
