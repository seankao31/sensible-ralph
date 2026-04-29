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

`skills/sr-start/scripts/orchestrator.sh`, two adjacent branches inside `_dispatch_issue`:

- Line 580 (`outcome="exit_clean_no_review"`): replace the existing single `linear_add_label ... || ...` line with the label-first/gated-revert block above. `_taint_descendants "$issue_id"` already follows on line 582 — keep its position (after the new block).
- Line 585 (`outcome="failed"`): same replacement. `_taint_descendants "$issue_id"` already follows on line 587.

No other call sites change. `linear_set_state` and `linear_add_label` (`lib/linear.sh:264-301`) are unchanged.

### Tests (`skills/sr-start/scripts/test/orchestrator.bats`)

- **Existing Test 3** (`hard failure: exit non-zero adds ralph-failed label, outcome=failed with exit_code`, line 352): add an assertion that `set_state ENG-20 Approved` appears in `STUB_LINEAR_CALLS_FILE` AFTER both `set_state ENG-20 In Progress` (the dispatch-time transition) and `add_label ENG-20 ralph-failed` (the new label-first ordering). Order verified by line-number comparison in the call log, matching the harness pattern already used elsewhere.
- **Existing Test 4** (`soft failure: exit 0 without state transition adds ralph-failed, outcome=exit_clean_no_review`, line 374): same additions for `ENG-30`.
- **New test: revert-fails on label success (failed path).** Stub `linear_set_state` to fail on the post-dispatch revert call only (the In-Progress transition at dispatch time must still succeed). Assert: label was added, revert was attempted, the "failed to revert" stderr warning appears in `$output`, the orchestrator continues, and the progress.json end-record `outcome` is still `failed`.
- **New test: revert-fails on label success (exit_clean_no_review path).** Same shape for the soft-failure branch — stub `linear_set_state` to fail on the post-dispatch revert, classify as `exit_clean_no_review`.
- **New test: label-fail gates revert.** Stub `linear_add_label` to fail. Assert: the post-dispatch `set_state ENG-X Approved` call does NOT appear in the call log (gated out), the "leaving state In Progress" stderr warning appears, the orchestrator continues, and the progress.json end-record `outcome` is still `failed` / `exit_clean_no_review` (test once per branch).

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
4. All existing `orchestrator.bats` tests pass. New assertions in Tests 3 and 4 assert the post-dispatch `set_state ... Approved` call appears in the call log after the In-Progress transition. Three new tests cover the partial-write paths.
5. The four documentation surfaces above are updated in the same commit as the code change. The phrase "remove the failed label and re-queue" no longer appears in the repo's live docs.

## Notes for the autonomous implementer

- The TDD workflow: start with the failing assertions in Tests 3 and 4 (assert the new revert call), then write the orchestrator change. Add the three new tests after the orchestrator code is in place (the failure-injection paths require the new code to even be reachable).
- `linear_set_state` returns non-zero on `linear issue update --state` failure (`lib/linear.sh:264-269`). The bats stub at `orchestrator.bats:114` already mirrors this — extend the stub with a per-call failure counter if you need to fail only the second invocation (the revert) while letting the first invocation (the dispatch-time In Progress transition) succeed.
- Keep the stderr warning text close to the existing pattern at the same call sites (`'orchestrator: failed to add %s label to %s (continuing)\n'`). The new lines should read naturally alongside the unchanged neighbors.
- Match `lib/linear.sh:227` (`_record_setup_failure`'s label-add) — that call site stays best-effort label-add only and explicitly does NOT revert state, because setup_failed paths never reached the `In Progress` transition. The asymmetry between the dispatched-outcome branches (revert) and the setup-failed branches (no revert) is intentional and worth preserving visibly in the code.
