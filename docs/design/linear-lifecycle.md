# Linear lifecycle
The Linear state machine that drives sensible-ralph: who owns each transition, what each label means, and how an issue clears back into the dispatch queue.

Linear is the state machine for the entire ralph lifecycle — not a `progress.txt` blob, not a hand-maintained checklist. Every issue moves through a fixed set of states; each transition has exactly one actor; two labels signal exception conditions outside the state graph. This doc is the definitive reference for that machine.

## States

In dispatch order, with a one-line definition of what each state means for ralph (not just Linear's generic semantics):

- **Backlog** — idle issue. Captured but not yet decided to be worked on.
- **Todo** — actionable but no PRD. The user has decided this should happen; design dialogue has not begun.
- **In Design** — a human is actively running an interactive design session (typically `/sr-spec`). Distinct from `In Progress`, which is reserved for autonomous implementation.
- **Approved** — PRD has been written into the issue description. Signals "ready for autonomous pickup" by `/sr-start`.
- **In Progress** — the orchestrator has dispatched a `claude -p` session for this issue and the worktree is live.
- **In Review** — the dispatched session ran `/prepare-for-review` to completion (doc sweep, codex review, handoff comment) and is awaiting interactive review.
- **Done** — the operator merged via `/close-issue` and the project-local `close-branch` skill.
- **Canceled / Duplicate** — terminal exits outside the success path. `Canceled` is a judgment call to drop work; `Duplicate` folds the issue into another. Neither counts as a resolved blocker (see [Why Canceled blockers don't count as resolved](#why-canceled-blockers-dont-count-as-resolved)).

State names except `Canceled` and `Duplicate` are configurable via plugin userConfig (`design_state`, `approved_state`, `in_progress_state`, `review_state`, `done_state`); the names above are the defaults declared in `lib/defaults.sh`. The orchestrator and skills compare against the configured values for the **pipeline states** (`In Design` through `Done`). One exception: `/sr-spec` hardcodes the idle-state match for its start-of-dialogue transition — it checks `Todo`, `Backlog`, and `Triage` by name. A workspace that has renamed those idle states must account for this gap.

## Transitions

Every state change has exactly one actor — there is no shared write path. The Linear UI is always available as a manual override, but the table below describes the automated transitions that the lifecycle relies on.

| From | To | Trigger | Actor | Command |
|---|---|---|---|---|
| Todo / Backlog / Triage | In Design | User runs `/sr-spec <issue-id>` | `/sr-spec` (step 1) | `linear issue update --state "$CLAUDE_PLUGIN_OPTION_DESIGN_STATE"` |
| In Design (or any non-terminal) | Approved | Spec finalized into description, blockers verified | `/sr-spec` (step 6 of finalization) | `linear issue update --state "$CLAUDE_PLUGIN_OPTION_APPROVED_STATE"` |
| Approved | In Progress | Orchestrator dispatches the issue (post-worktree-create, pre-`claude -p`) | `orchestrator.sh` (`_dispatch_issue`) | `linear_set_state "$CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE"` |
| In Progress | In Review | Implementation done, `/prepare-for-review` finished doc sweep + codex pass + handoff comment | `claude -p` session via `/prepare-for-review` (step 7) | `linear issue update --state "$CLAUDE_PLUGIN_OPTION_REVIEW_STATE"` |
| In Review | Done | Operator approves; `close-branch` integration succeeds | `/close-issue` (step 7) | `linear issue update --state "$CLAUDE_PLUGIN_OPTION_DONE_STATE"` |
| Any | Canceled / Duplicate | Manual operator decision | operator | Linear UI, or `linear issue update --state Canceled` |

Each automated transition is **conditional** on the prior state matching expectations:

- `/sr-spec`'s step 1 preflight validates BOTH the issue's Linear state AND the per-issue branch+worktree state (via `worktree_branch_state_for_issue`). The full matrix lives in `skills/sr-spec/SKILL.md`; in summary: from `Todo`/`Backlog`/`Triage` it transitions to `In Design` (and refuses if branch+worktree residue is present); from `In Design` it resumes; from `Approved` it warns the user about overwriting the prior spec, requires confirmation, and transitions back to `In Design` for the new dialogue; from `In Progress`/`In Review`/`Done`/`Canceled` it refuses outright.
- `/prepare-for-review` checks the current state via `linear issue view --json` before transitioning; if the issue is already `In Review`, it skips the write to keep the activity feed clean. Anything other than `In Progress` or `In Review` is a red flag that aborts the skill.
- `/close-issue`'s pre-flight requires the issue to be in `In Review` and every `blocked-by` parent to be in `Done`. A non-`Done` blocker stops the close — the supported fix is to remove the relation explicitly via `linear issue relation delete` if the dependency was resolved out of band, not to override the gate.

The orchestrator never writes `Approved` (only `/sr-spec` produces Approved issues) and never writes `Done` (only `/close-issue` does). This single-actor-per-transition discipline keeps every state change traceable to one skill or script.

Under ENG-279's per-issue branch lifecycle, the branch and worktree are created lazily at `/sr-spec` step 7 (after design approval) and persist through `In Progress` / `In Review` until `/close-issue` tears them down. State and worktree existence are coupled: by the time an issue reaches `Approved`, its branch+worktree should exist on disk. See `docs/design/worktree-contract.md`.

## Labels

Two workspace-scoped labels are part of the lifecycle. Both label names are userConfig-driven via plugin options; the defaults below ship in `lib/defaults.sh`. Linear's label-by-name resolution silently no-ops on a nonexistent name, so `preflight_scan.sh` aborts with a setup hint if either label is missing from the workspace.

| Label | Default name | userConfig option | Applied by | Cleared by |
|---|---|---|---|---|
| Failed dispatch | `ralph-failed` | `failed_label` | `orchestrator.sh` on `failed`, `exit_clean_no_review`, or `setup_failed` outcomes | Operator removes the label in Linear before re-queueing |
| Stale parent | `stale-parent` | `stale_parent_label` | `/close-issue` (step 6) on In-Review children whose parent landed amendments during review | Operator dismisses after rebasing the child or accepting the review gap |

**`ralph-failed` is dispatch-gating.** `linear_list_approved_issues` excludes any Approved issue carrying this label, so a labeled issue is invisible to subsequent `/sr-start` runs until the operator clears it. This is the load-bearing piece of the v2 failure-handling model: dispatch never silently retries a failure, and the issue's transitive descendants are also tainted for the same run (see Decision 8 of `docs/specs/ralph-loop-v2-design.md`).

**`stale-parent` is observational.** It does not gate anything — by the time it is applied, the parent has already landed via `/close-issue`'s integration step. The label flags a review-integrity gap that the dispatch-time guardrail in `/close-issue`'s pre-flight §2 (the "all blockers Done" check) cannot catch on its own: a child issue in `In Review` reviewed against a base that the parent then amended. The operator decides whether to rebase the child and re-review, accept the gap, or dismiss the label.

To re-queue an issue that hit `ralph-failed`:

1. Read `.sensible-ralph/progress.json` and find the `"end"` record for the issue. The `outcome` field tells you which failure path triggered the label:
   - `failed` / `exit_clean_no_review`: a `claude -p` session ran. Inspect `<worktree>/<stdout_log_filename>` for the session's final output.
   - `setup_failed`: the orchestrator never created the worktree (or failed partway through setup before `claude -p` launched). There may be no worktree log — use the `failed_step` field in the progress record to identify which setup step broke.
2. Fix the underlying issue, then remove the `ralph-failed` label via the Linear UI so the next `/sr-start` picks it up again, or cancel the issue if the work is no longer wanted. The `linear` CLI exposes no per-issue label-removal command; do not run `linear label delete`, which deletes the label workspace-wide.

## Pickup rule

An Approved issue is **strictly pickup-ready** for autonomous dispatch when ALL three conditions hold:

1. **State is `Approved`** (matched against `$CLAUDE_PLUGIN_OPTION_APPROVED_STATE`).
2. **No `ralph-failed` label** (matched against `$CLAUDE_PLUGIN_OPTION_FAILED_LABEL`).
3. **Every `blocked-by` parent** is either:
   - already in `Done` or `In Review`, OR
   - in `Approved` AND a member of this run's queue, AND its own blockers satisfy this rule recursively.

Rule 3 is what makes overnight execution of dependency chains possible: an Approved parent that is queued ahead of its child reaches `In Review` (via the parent's own `/prepare-for-review`) before the child's dispatch begins, and `dag_base.sh` then picks up the parent's branch as the child's base. The recursion matters: if a parent is Approved and queued but one of *its* blockers is `Canceled`, the chain is stuck and the child is not pickup-ready — preflight aborts before dispatch. An Approved blocker that is **not** in this run's queue (`ralph-failed`-labeled, in another project, or otherwise filtered out) cannot clear during the run and surfaces as a preflight anomaly.

Implementation lives in `skills/sr-start/scripts/preflight_scan.sh` (`_chain_runnable`) and the queue-construction layer in `lib/linear.sh` (`linear_list_approved_issues`). Pre-flight catches the "stuck chain" cases before the orchestrator is invoked; the orchestrator itself does not re-evaluate pickup-readiness mid-run because toposort + the parent-runs-first invariant guarantees rule 3 holds at each child's dispatch time.

For the full preflight anomaly set, pickup-filter implementation details, and the pre-existing-blocker vs. in-run-queue distinction, see [`docs/design/preflight-and-pickup.md`](preflight-and-pickup.md).

## Why Canceled blockers don't count as resolved

A natural shortcut: "if the parent was canceled, the child no longer has anything to wait on, so dispatch the child." Sensible-ralph rejects this. Cancellation is a judgment call — someone decided the parent was not worth doing — and that judgment may have invalidated the child's premise too. Silently dispatching the child substitutes the orchestrator's reading of "blocker resolved" for the operator's read of "what does this dependency relationship even mean now."

The same reasoning applies to `Duplicate`. Both states surface as preflight anomalies in `preflight_scan.sh` (`Check 1` and `Check 1b`), forcing the operator to clean up before dispatch. The supported way to declare "this is no longer a real blocker" is to remove the `blocked-by` relation explicitly:

```bash
linear issue relation delete "$CHILD_ID" blocked-by "$PARENT_ID"
```

After that, the child is unblocked structurally, not by inference. The same rule shows up at close time — `/close-issue`'s pre-flight §2 refuses to close a child whose parent isn't `Done` (no `--force` escape hatch), with the same fix: remove the relation if the dependency was genuinely resolved out of band.

The cost is one extra round-trip through human attention on the rare cancellation. The benefit is that the lifecycle never builds on top of work whose disposition was ambiguous.
