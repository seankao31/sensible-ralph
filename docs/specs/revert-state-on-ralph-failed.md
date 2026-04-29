# Revert Linear state to Approved when applying ralph-failed

**Linear:** ENG-322 — orchestrator: revert Linear state to Approved when applying ralph-failed
**Status:** Approved
**Prerequisites:** none

## Problem

When the orchestrator dispatches an issue, it transitions Linear state `Approved → In Progress` at `skills/sr-start/scripts/orchestrator.sh:482` (immediately before `claude -p` runs). On the two dispatched-outcome failure paths — `failed` (line 585) and `exit_clean_no_review` (line 580) — it applies the configured `failed_label` (`ralph-failed`) but never reverts state. The issue remains `In Progress` permanently.

The pickup filter in `linear_list_approved_issues` (`lib/linear.sh:43-50`) requires both:

1. `state.name == $CLAUDE_PLUGIN_OPTION_APPROVED_STATE`, AND
2. no `$CLAUDE_PLUGIN_OPTION_FAILED_LABEL` on the issue.

Failed issues fail the first condition, so they are invisible to every subsequent `/sr-start` even after the operator removes the label.

The documented operator retry workflow (`docs/usage.md:15`, `docs/design/linear-lifecycle.md:62`) — *"remove the failed label and re-queue"* — does not work. Removing the label leaves the issue stuck in `In Progress`. The operator must also manually flip state back to `Approved` via the Linear UI, an undocumented and non-obvious second step.

## UX intent

The morning Linear board the operator should see after a `/sr-start` run:

- **In Review** — overnight successes; review and merge with `/close-issue`.
- **Approved + `ralph-failed`** — overnight failures awaiting triage; per-issue decide retry / cancel / debug.
- **Approved (no label)** — fresh `/sr-spec`-produced issues + retries the operator cleared. Ready for next dispatch.
- **In Progress** — should be empty post-run. Non-empty = orchestrator crash mid-run or a session that exited without classifying.

Retry workflow on a `ralph-failed` issue: **one operator action — remove the label**. The label removal is the human triage signal ("I read the log; the failure is worth retrying"). Auto-retry without that signal would hide real problems and burn cycles on broken work; the manual touchpoint is intentional.

The model this restores: **state describes where the issue is in the lifecycle; labels mark exception conditions that don't fit a single linear state**. A failed-pending-retry issue is not "in progress" — it's an Approved issue with a marker saying "needs triage before next pickup."

Downstream specs that depend on this restored model:

- **ENG-309** (Approved): acceptance criterion 3 requires end-to-end retry verification.
- **ENG-312** (Todo): "detect parent-set drift between failure and retry" premise requires retry to be queueable.
- **ENG-247** (Todo): v2 workflow evaluation will exercise retry paths.

## Fix shape

At each of the two dispatched-outcome failure branches in `_dispatch_issue` (`orchestrator.sh:580` for `exit_clean_no_review`, `:585` for `failed`), replace the existing best-effort label-add with a label-first, gated-revert pair. Inline at both call sites — no helper extraction.

```bash
if linear_add_label "$issue_id" "$CLAUDE_PLUGIN_OPTION_FAILED_LABEL"; then
  linear_set_state "$issue_id" "$CLAUDE_PLUGIN_OPTION_APPROVED_STATE" || \
    printf 'orchestrator: failed to revert %s to %s (continuing)\n' \
      "$issue_id" "$CLAUDE_PLUGIN_OPTION_APPROVED_STATE" >&2
else
  printf 'orchestrator: failed to add %s label to %s; leaving state In Progress so the failure stays visible (continuing)\n' \
    "$CLAUDE_PLUGIN_OPTION_FAILED_LABEL" "$issue_id" >&2
fi
_taint_descendants "$issue_id"
```

Notes:

- **Label-first, gated-revert.** The state revert runs only when the label add succeeded. This guarantees the invariant *"an Approved-state issue always carries the `ralph-failed` marker after a failure"* — a failed ticket can never be silently buried among unlabeled Approved tickets.
- **Both calls remain best-effort.** The orchestrator continues regardless of label or revert success; warnings go to stderr matching the existing pattern at the same call sites.
- **Taint runs unconditionally.** Failure of this issue means descendants are tainted regardless of how the Linear writes resolved.

### Partial-write outcomes

| Label | Revert | Resulting state | Operator visibility |
|---|---|---|---|
| ✓ | ✓ | `Approved + ralph-failed` (happy path) | Visible; one-action retry (remove label) |
| ✓ | ✗ | `In Progress + ralph-failed` | Visible; manual two-step recovery (today's recipe) |
| ✗ | (skipped) | `In Progress` (no label) | Visible as anomaly: post-run `In Progress` should be empty |

There is no scenario that produces `Approved` (no label) on a failed issue. Silent rejoin is structurally prevented.

## Out of scope

- **`setup_failed`** (`_record_setup_failure` at `orchestrator.sh:223-238`) does NOT need a state revert. Every setup-failed path fires before the `linear_set_state ... In Progress` call at line 482 — including the `linear_set_state` failure itself at line 490, where state was never written. The existing best-effort `linear_add_label` call in `_record_setup_failure` is unchanged.
- **`local_residue`** never mutates Linear; nothing to revert.
- **`unknown_post_state`** (`exit 0` + transient state-fetch failure) deliberately leaves Linear untouched. The orchestrator cannot disambiguate a real `In Review` success from a session that stopped short. A best-effort revert here would risk overwriting correct work. Operator inspects the issue manually (existing behavior preserved).
- **Helper extraction.** Two-line duplication across two adjacent branches of the same `if/elif/else` is below the threshold where a shared helper is justified; the helper would just wrap two best-effort calls under a name. Inline keeps the asymmetry with `_record_setup_failure` (which deliberately does NOT revert) visible at the call sites.

## Implementation surface

### Code

`skills/sr-start/scripts/orchestrator.sh`, two adjacent branches inside the post-dispatch outcome `if/elif/else` in `_dispatch_issue`:

- **`exit_clean_no_review` branch** (current lines 580-582 — the `linear_add_label ... || printf ...` pair followed by `_taint_descendants`): replace the two-line label-add with the label-first/gated-revert block above. `_taint_descendants "$issue_id"` stays as the last statement of the branch.
- **`failed` branch** (current lines 585-587 — same pair): same replacement.

The two call sites are textually identical and should remain so after the change — copy the same block to both branches. No other call sites change. `linear_set_state` and `linear_add_label` (`lib/linear.sh:264-301`) are unchanged.

### Tests (`skills/sr-start/scripts/test/orchestrator.bats`)

Because the `exit_clean_no_review` and `failed` branches inline textually-identical blocks, partial-write coverage targets the `failed` branch only — the implementer should resist any temptation to diverge the two call sites.

- **Existing Test 3** (`hard failure: exit non-zero adds ralph-failed label, outcome=failed with exit_code`, line 352): add a membership assertion that `set_state ENG-20 Approved` appears in `STUB_LINEAR_CALLS_FILE` (in addition to the existing `set_state ENG-20 In Progress` and `add_label ENG-20 ralph-failed` membership checks).
- **Existing Test 4** (`soft failure: exit 0 without state transition adds ralph-failed, outcome=exit_clean_no_review`, line 374): same membership addition for `ENG-30`.
- **New test: revert fails on label success.** Run against the hard-failure branch (`STUB_CLAUDE_EXIT != 0`). Stub `linear_set_state` so the post-dispatch revert call fails while the dispatch-time `In Progress` transition succeeds — i.e. fail the second `set_state` invocation, not the first. Assert: `add_label ENG-X ralph-failed` is in the call log, `set_state ENG-X Approved` was attempted (in the call log), the `'orchestrator: failed to revert ... (continuing)'` stderr warning appears in `$output`, and the progress.json end-record `outcome` is still `failed`.
- **New test: label-fail gates revert.** Run against the hard-failure branch. Stub `linear_add_label` to fail. Assert: `set_state ENG-X Approved` does NOT appear in the call log (the gate kept the revert from running), the `'orchestrator: failed to add ralph-failed label to ENG-X; leaving state In Progress so the failure stays visible (continuing)'` stderr warning appears, and the progress.json end-record `outcome` is still `failed`.

The existing test stubs for `linear_set_state` and `linear_add_label` (`orchestrator.bats:114-135`) already support failure-injection via per-call counters or env flags; extend the stubs minimally if needed to distinguish the dispatch-time `set_state` call (must succeed) from the post-dispatch revert call (must fail) in the revert-fails tests.

### Documentation (same commit as the code change)

All four docs below carry the broken "remove the failed label and re-queue" recipe, or describe the orchestrator's failure-path behavior. Update each:

- **`docs/usage.md:15`** — in the failed/exit_clean_no_review triage paragraph, replace "decide whether to retry (remove the failed label and re-queue)" with "decide whether to retry (remove the failed label — the orchestrator already reverted state to Approved)".
- **`docs/design/linear-lifecycle.md:50`** — in the labels table, the "Cleared by" cell for `ralph-failed` currently reads "Operator removes the label in Linear before re-queueing". Update to clarify that the label is the only operator action required; state revert is automatic.
- **`docs/design/linear-lifecycle.md:62`** — in the "To re-queue an issue that hit `ralph-failed`" recipe, update step 2 to drop the "manually flip state back to Approved" implication. The new recipe: read the failure record, fix the underlying cause if any, remove the `ralph-failed` label.
- **`docs/design/outcome-model.md:32`** (`exit_clean_no_review` triage column) — update "(remove `ralph-failed`, re-queue)" to "(remove `ralph-failed`)".
- **`docs/design/outcome-model.md:33`** (`failed` triage column) — currently says "Same as `exit_clean_no_review`"; this transitively picks up the line-32 correction. Verify the wording reads correctly post-edit; no separate edit needed unless the same-as reference becomes ambiguous.
- **`docs/design/orchestrator.md:148`** — append "and reverts state to Approved" to the `exit_clean_no_review` outcome bullet.
- **`docs/design/orchestrator.md:149`** — append "and reverts state to Approved" to the `failed` outcome bullet.
- **`docs/design/orchestrator.md:151`** (`setup_failed`) — **untouched**; setup_failed does not transition state to `In Progress`, so no revert is involved.

### Out of doc scope

`docs/design/preflight-and-pickup.md` mentions `ralph-failed` in the context of pickup filtering and stuck-chain detection. Those references are still correct after the fix (the label is still dispatch-gating). No edit needed.

`docs/design/autonomous-mode.md` mentions `ralph-failed` in the autonomous-mode escape-hatch flow. The flow is unchanged. No edit needed.

## Acceptance

1. After a `failed` or `exit_clean_no_review` outcome on the happy path, the issue's Linear state is `Approved` and it carries the `ralph-failed` label.
2. After the operator removes the `ralph-failed` label, the next `/sr-start` queues the issue without any other operator action — `linear_list_approved_issues` returns it, the preflight chain check passes, the orchestrator dispatches it.
3. Partial-write paths (label-add fails; or label-add succeeds and revert fails) leave the issue in a visible state — never silently rejoining the dispatch queue. Specifically, no failure path produces an `Approved`-state issue without the `ralph-failed` label.
4. All existing `orchestrator.bats` tests pass. New assertions in Tests 3 and 4 assert the post-dispatch `set_state ... Approved` call appears in the call log. Two new tests cover the partial-write paths (`revert fails on label success`, `label-fail gates revert`).
5. The four documentation surfaces above are updated in the same commit as the code change. The phrase "remove the failed label and re-queue" no longer appears in the repo's live docs.

## Notes for the autonomous implementer

- The TDD workflow: start with the failing assertions in Tests 3 and 4 (assert the new revert call), then write the orchestrator change. Add the three new tests after the orchestrator code is in place (the failure-injection paths require the new code to even be reachable).
- `linear_set_state` returns non-zero on `linear issue update --state` failure (`lib/linear.sh:264-269`). The bats stub at `orchestrator.bats:114` currently fails ALL calls for an issue when `STUB_SET_STATE_FAIL_<KEY>` is set; the `revert fails on label success` test needs to fail only the post-dispatch revert call (target state `Approved`) while letting the dispatch-time `In Progress` transition succeed. The minimal stub extension is to add a second env flag like `STUB_SET_STATE_FAIL_ON_REVERT_<KEY>` that triggers only when `$2 == "$CLAUDE_PLUGIN_OPTION_APPROVED_STATE"`. This keeps the existing `STUB_SET_STATE_FAIL_*` semantics intact for other tests.
- Keep the stderr warning text close to the existing pattern at the same call sites (`'orchestrator: failed to add %s label to %s (continuing)\n'`). The new lines should read naturally alongside the unchanged neighbors.
- Match `lib/linear.sh:227` (`_record_setup_failure`'s label-add) — that call site stays best-effort label-add only and explicitly does NOT revert state, because setup_failed paths never reached the `In Progress` transition. The asymmetry between the dispatched-outcome branches (revert) and the setup-failed branches (no revert) is intentional and worth preserving visibly in the code.
