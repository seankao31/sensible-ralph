# Outcome model

How the orchestrator classifies each dispatched session.

Each issue the orchestrator processes ends in exactly one outcome. The
outcome decides three downstream effects: whether the `ralph-failed`
label is applied to the Linear issue, whether the issue's transitive DAG
descendants are tainted (skipped) for the rest of the run, and what the
operator needs to do in the morning to resolve it.

## Classification inputs

Three signals classify a dispatched session:

- `exit_code` — the exit status of the `claude -p` subprocess.
- `post_state` — the Linear state of the issue, fetched via
  `linear_get_issue_state` *after* `claude -p` exits.
- `state_fetch_ok` — whether that post-dispatch Linear read succeeded.
  A transient Linear API blip on the read must not be conflated with a
  successful read that returned a non-review state.

For pre-dispatch failures (worktree creation, Linear state transition,
etc.) the orchestrator never invokes `claude -p`; outcome is determined
by which setup step failed. For taint propagation skipping, no claude
invocation occurs and the issue lands as `skipped` directly.

## The seven outcomes

| Outcome | Classification rule | `ralph-failed` label | Taints descendants | Operator triage |
|---|---|---|---|---|
| `in_review` | `exit_code == 0` AND `post_state == REVIEW_STATE` | no | no | `cd` into the worktree, `claude --resume` if available, review per the QA plan in the Linear comment, then run the project's merge ritual from the main checkout. |
| `exit_clean_no_review` | `exit_code == 0` AND `post_state != REVIEW_STATE` (state fetched successfully) | yes | yes | `cd` into the worktree, read `<worktree>/<stdout_log_filename>` for the session's final output. Decide: retry (remove `ralph-failed`, re-queue), cancel the issue, or debug interactively. |
| `failed` | `exit_code != 0` | yes | yes | Same as `exit_clean_no_review` — read the log, decide retry / cancel / debug. |
| `setup_failed` | A pre-dispatch setup step failed (branch lookup, `dag_base`, worktree creation, base-SHA write, Linear `In Progress` transition, etc.) | yes | yes | Check the `failed_step` field in `.sensible-ralph/progress.json`. Worktree cleanup has already run for any state this invocation created. Fix the underlying cause (Linear connectivity, missing branch name, `dag_base` mismatch) and re-queue. |
| `local_residue` | The target worktree path or branch already existed at the start of dispatch — orchestrator never touched anything | **no** | **no** | Check `residue_path` and `residue_branch` in `.sensible-ralph/progress.json`. Manually clean up the residue (commit the work, or remove the path/branch), then re-queue. |
| `unknown_post_state` | `exit_code == 0` AND post-dispatch state fetch failed transiently | **no** | **no** | Open the issue in Linear. If state is `In Review`, treat as success (no `ralph-failed` was applied). If still `In Progress`, treat as a soft failure and re-queue. |
| `skipped` | Issue's transitive ancestor failed earlier in this run; orchestrator never dispatched it | no | no (descendants were already tainted by the originating failure) | Resolve the failed ancestor first; the skipped issue becomes pickup-ready again on the next `/sr-start`. |

`local_residue` is the only outcome where Linear is left completely
untouched — the orchestrator never dispatched the issue and made no
state transitions. `unknown_post_state` is different: Linear was already
mutated (the issue was transitioned to `In Progress` during setup, and
the session may have advanced it to `In Review`); what `unknown_post_state`
deliberately skips is the *additional* `ralph-failed` label write and
descendant taint. The rationale for skipping those additional writes is
below.

## Why exit 0 alone does not imply success

`claude -p --permission-mode auto` does not block on a permission prompt —
when auto mode refuses an operation it can't auto-approve, the session
reports the refusal as a tool-result denial and **exits 0 with the work
incomplete**. The Linear issue is still in `In Progress`; the
`/prepare-for-review` skill never ran, so no transition to `In Review`
occurred.

If the orchestrator classified by exit code alone, an autonomous-mode
escape hatch (or any other clean refusal) would be indistinguishable from
a real success. The post-dispatch Linear state is the second signal that
collapses the ambiguity: `exit 0 + In Review` is the only success
configuration. For any other `exit 0` outcome, the classification
branches on whether the post-dispatch state fetch succeeded:

- **State fetched successfully but not `In Review`** → `exit_clean_no_review`:
  applies `ralph-failed` and taints descendants, the same treatment as a
  hard exit-code failure.
- **State fetch failed transiently** → `unknown_post_state`: no additional
  label or taint — see the `unknown_post_state` rationale below.

## Why `local_residue` deliberately leaves Linear untouched

`local_residue` fires *before* the orchestrator invokes `claude -p` or
mutates Linear, when a pre-flight check finds either the target worktree
path or the target branch already on disk. The pre-existing state is
operator state — a manual `mkdir`, a prior crashed run, or an in-flight
branch the operator created out-of-band. The Linear issue itself is in
fine shape; only the local environment is stale. Adding `ralph-failed`
to the issue would misrepresent a healthy ticket as broken. Tainting
descendants would be similarly wrong: the unmutated issue remains
`Approved`, so `dag_base` (which only incorporates blockers in
`In Review`) would not pick it up as a parent for any descendant
anyway — descendants safely dispatch from the default base.

## Why `unknown_post_state` deliberately leaves Linear untouched

`unknown_post_state` fires when `claude -p` exited 0 but the post-dispatch
`linear_get_issue_state` read failed transiently. The orchestrator
genuinely cannot tell whether the session succeeded (transitioned the
issue to `In Review`) or stopped short. Collapsing the ambiguity in
either direction has a cost: labeling `ralph-failed` on a real success
destroys correct work and forces the operator to undo it; treating it as
a success risks pushing dependent work onto an unreviewed parent. The
safer default is to expose the ambiguity in `progress.json` and let the
operator inspect Linear directly.

## See also

- `docs/design/linear-lifecycle.md` (forthcoming, ENG-291) — Linear
  state machine the orchestrator drives (Approved → In Progress → In
  Review → Done) and the labels (`ralph-failed`, `stale-parent`) it
  applies.
- `docs/design/orchestrator.md` (forthcoming, ENG-291) — the dispatch
  loop itself: queue construction, DAG base selection, per-issue setup,
  `claude -p` invocation, and `progress.json` record schema.
