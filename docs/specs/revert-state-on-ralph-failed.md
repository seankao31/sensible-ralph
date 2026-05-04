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
- **In Progress** — should be empty post-run on the happy path. Non-empty post-run = orchestrator crash mid-run, a session that exited without classifying, OR a degraded recovery path where the orchestrator could not confirm the `ralph-failed` label landed (see Partial-write outcomes below). Today the system surfaces none of these via `/sr-start`, preflight, or `/sr-status` — operator board inspection is the recovery signal. System-side surfacing of stuck `In Progress` is out of scope here (ENG-254 crash-detection territory).

Retry workflow on a `ralph-failed` issue: **one operator action — remove the label**. The label removal is the human triage signal ("I read the log; the failure is worth retrying"). Auto-retry without that signal would hide real problems and burn cycles on broken work; the manual touchpoint is intentional.

The model this restores: **state describes where the issue is in the lifecycle; labels mark exception conditions that don't fit a single linear state**. A failed-pending-retry issue is not "in progress" — it's an Approved issue with a marker saying "needs triage before next pickup."

Downstream specs that depend on this restored model:

- **ENG-309** (Approved): acceptance criterion 3 requires end-to-end retry verification.
- **ENG-312** (Todo): "detect parent-set drift between failure and retry" premise requires retry to be queueable.
- **ENG-247** (Todo): v2 workflow evaluation will exercise retry paths.

## Fix shape

At each of the two dispatched-outcome failure branches in `_dispatch_issue` (`orchestrator.sh:580` for `exit_clean_no_review`, `:585` for `failed`), replace the existing best-effort label-add with a label-first, **verify-after-add**, gated-revert pair. The verification step is load-bearing: `linear_add_label` returning success only proves the CLI update call succeeded, not that the label is actually applied. Linear's label-by-name resolution silently no-ops when the label name is missing from the workspace (documented at `lib/linear.sh:316-322`); preflight checks for label existence before the run, but the label can be deleted between preflight and a failed-dispatch label-add. Without verification, the gate would let the revert run on an unverified label-add and the issue would silently rejoin the queue as `Approved` unlabeled — exactly the invariant the spec is asserting.

A small orchestrator-local helper encapsulates the add-then-verify pattern; both call sites use it. The helper logs the specific failure reason internally so the caller only needs success/failure semantics:

```bash
# Apply the failed label and verify it actually landed on the issue.
# Returns 0 only when the label is observed on the issue post-add.
# On failure, logs the specific reason (CLI failure / read failure /
# silent no-op) to stderr — three distinct mechanisms with three
# distinct terminal Linear states; see Partial-write outcomes below.
# Linear silently no-ops --label updates that reference a workspace
# label name that doesn't exist; we cannot trust linear_add_label's
# exit code as proof of post-write state.
_apply_failed_label_verified() {
  local issue_id="$1"
  if ! linear_add_label "$issue_id" "$CLAUDE_PLUGIN_OPTION_FAILED_LABEL"; then
    printf 'orchestrator: failed to add %s label to %s; leaving state In Progress (continuing)\n' \
      "$CLAUDE_PLUGIN_OPTION_FAILED_LABEL" "$issue_id" >&2
    return 1
  fi
  local labels
  if ! labels="$(linear_get_issue_labels "$issue_id" 2>/dev/null)"; then
    printf 'orchestrator: linear_get_issue_labels failed for %s after label-add; label MAY be on the issue (operator: check Linear and follow the labeled-In-Progress recovery recipe in linear-lifecycle.md); leaving state In Progress (continuing)\n' \
      "$issue_id" >&2
    return 1
  fi
  if printf '%s\n' "$labels" | grep -qFx "$CLAUDE_PLUGIN_OPTION_FAILED_LABEL"; then
    return 0
  fi
  printf 'orchestrator: %s did not land on %s after label-add (silent no-op — workspace label may be missing); leaving state In Progress (continuing)\n' \
    "$CLAUDE_PLUGIN_OPTION_FAILED_LABEL" "$issue_id" >&2
  return 1
}
```

The `failed` and `exit_clean_no_review` branches replace their existing single-line label-add with:

```bash
if _apply_failed_label_verified "$issue_id"; then
  linear_set_state "$issue_id" "$CLAUDE_PLUGIN_OPTION_APPROVED_STATE" || \
    printf 'orchestrator: failed to revert %s to %s (continuing)\n' \
      "$issue_id" "$CLAUDE_PLUGIN_OPTION_APPROVED_STATE" >&2
fi
_taint_descendants "$issue_id"
```

`linear_get_issue_labels` is a new peer of `linear_get_issue_state` / `linear_get_issue_branch` in `lib/linear.sh`. It returns one label name per line on stdout; non-zero on `linear issue view` failure. Implementation pattern matches the existing helpers (single `linear issue view --json --no-comments` + jq extraction).

Notes:

- **Verify-after-add gates the revert.** The state revert runs only when the failed label is *observed* on the issue, not just when `linear_add_label` returns success. This makes the gate robust against the documented Linear silent-no-op (missing workspace label name → CLI returns 0 without applying anything).
- **Both calls remain best-effort.** The orchestrator continues regardless of label-add, verify, or revert success; warnings go to stderr matching the existing pattern at the same call sites.
- **Taint runs unconditionally.** Failure of this issue means descendants are tainted regardless of how the Linear writes resolved.
- **Single helper, both call sites.** The two dispatched-outcome branches inline the same `if _apply_failed_label_verified … fi` block. The helper lives in `orchestrator.sh` (not `lib/linear.sh`) because the verify-after-add policy is orchestrator-specific, not a general Linear-library primitive.
- **Concurrency assumption (load-bearing).** The sequence `add_label → get_labels → set_state Approved` is THREE separate Linear API calls. There is no compare-and-set, no transaction, no atomic combined update. The spec's claim that no **dispatched-outcome** failure path leaves the issue `Approved` without `ralph-failed` is conditioned on **no concurrent unintended label mutation between the `get_labels` verify call and the `set_state` revert call** (a window of one Linear API round-trip — typically tens to low-hundreds of milliseconds). The supported and unsupported cases:
  - *Same-repo concurrent `/sr-start` runs:* unsupported by design (`docs/usage.md`); not a failure case this fix is responsible for.
  - *Human removing the label in Linear UI mid-window:* a human removing the label in that exact millisecond is removing it because they want the issue re-queued. The race converges to operator-intended state (`Approved` no label = "re-pick on next run"). Not a silent-rejoin in the bug-shape sense — the operator's intent IS rejoin.
  - *Other automated processes mutating Linear labels:* out of scope for ralph; not a supported environment.
- **Linear consistency assumption (load-bearing).** The verify-after-add gate's correctness depends on `linear issue view` reflecting the just-applied label-update from the same client session. We assume Linear offers **read-after-write consistency for sequential same-session API calls** — i.e. a write returning success will be visible on a subsequent read from the same client. This is the standard behavior for Linear's GraphQL API in a same-session context (no read replica routing surfaces between writer and reader for sequential calls); ralph already depends on this assumption pervasively (every `linear_set_state` followed by a `linear_get_issue_state` query, every `linear issue update` followed by `linear issue view`). Without it, the silent-no-op detection degrades: a stale-positive read could falsely confirm a label that wasn't actually applied (workspace label deleted post-preflight, `linear_add_label` silent-no-ops, but read replica returns pre-deletion state showing the label still on the issue) and the revert would run, leaving the issue `Approved` without the marker. If your Linear deployment exhibits measurably stale reads, this fix's safety invariant degrades toward today's behavior — but the broader ralph system already depends on the same assumption, so a stale-read environment has bigger problems than ENG-322 to address.

A post-revert re-verification (re-fetch state + labels, surface mismatch as a degraded outcome, possibly re-apply the label) is deliberately NOT in scope: it shifts the race window rather than closes it, and adds complexity for a scenario whose realistic resolutions are already operator-intended.

### Partial-write outcomes

The four `_apply_failed_label_verified` outcomes (label-add, verify-read, label-observed) cross with the two revert outcomes (success, failure) to produce five distinct terminal states. The verify-read step has three sub-outcomes (read succeeds + label observed; read succeeds + label absent; read fails) that collapse into "verify ✓" or "verify ✗" for the gate, but the resulting Linear state differs.

| `_apply_failed_label_verified` outcome | Revert | Resulting Linear state | Operator visibility |
|---|---|---|---|
| Label add ✓, read ✓, label observed (= helper returns 0) | ✓ | `Approved + ralph-failed` (happy path) | Visible; one-action retry (remove label) — acceptance 2a |
| Label add ✓, read ✓, label observed (= helper returns 0) | ✗ | `In Progress + ralph-failed` (revert API blip) | Visible; manual two-step recovery (remove label + flip state) — acceptance 2b |
| Label add ✓, read ✗ (= helper returns 1, *labels-state-unknown* path) | (gated out) | `In Progress + ralph-failed` (most likely — label IS on the issue, just couldn't confirm) OR `In Progress` no label (very unlikely simultaneous failures) | Same as above: criterion 2b recipe handles both (label removal is a no-op if not labeled). Stderr names the read-failure cause. |
| Label add ✓, read ✓, label NOT observed (= helper returns 1, silent no-op path) | (gated out) | `In Progress` (no label) — workspace label name missing | Operator board inspection — acceptance 2c (out of scope) |
| Label add ✗ (= helper returns 1, add-failed path) | (gated out) | `In Progress` (no label) — `linear_add_label` returned non-zero | Same as above: acceptance 2c |

**Within the dispatched-outcome paths and absent concurrent unintended label mutation** (see Concurrency assumption above), no scenario produces `Approved` (no label) on a failed issue. The "labeled-but-unverified" outcome (row 3) is functionally indistinguishable from the revert-failed outcome (row 2) for operator recovery purposes — the criterion 2b recipe ("remove label if present; flip state if In Progress") handles both. The two `In Progress` (no label) rows (4 and 5) are degraded recovery paths that depend on operator board inspection — the spec does NOT claim system-level surfacing for them. The `setup_failed` paths are explicitly out of scope and retain today's behavior; see Out of scope.

## Out of scope

- **State revert in `setup_failed`** (`_record_setup_failure` at `orchestrator.sh:223-238`) — out of scope because no revert is needed. Every setup-failed path fires before the `linear_set_state ... In Progress` call at line 482 — including the `linear_set_state` failure itself at line 490, where state was never written. State stays `Approved`; only the label is applied. (The verify-after-add gate IS applied to setup_failed in this PR — see Implementation surface > Code; only the *state revert* dimension is out of scope for setup_failed because it doesn't apply.)
- **`local_residue`** never mutates Linear; nothing to revert.
- **`unknown_post_state`** (`exit 0` + transient state-fetch failure) deliberately leaves Linear untouched. The orchestrator cannot disambiguate a real `In Review` success from a session that stopped short. A best-effort revert here would risk overwriting correct work. Operator inspects the issue manually (existing behavior preserved).
- **System-side surfacing AND operator recovery doc for stuck `In Progress`.** The verify-fail and label-fail recovery paths leave the issue `In Progress` with no marker (acceptance criterion 2c). Operator board inspection is the recovery signal today. ENG-322 does NOT ship a recovery doc for this class because operator-facing recovery without a system-side surfacing path would ask the operator to manually scan `progress.json` after every run for a rare anomaly. Both deliverables — the system-side surfacing AND the operator recovery flow — should land together in a follow-up tied to ENG-254 (crash detection), since the same path-survey would catch both classes. Filing as a single follow-up keeps scope discipline here AND avoids stranding 2c on a half-shipped recovery story.
- **Atomicity / post-revert re-verification.** The `add_label → get_labels → set_state` sequence is non-atomic; concurrent unintended label mutation between verify and revert can produce `Approved` without label. Realistic upstream causes converge to operator-intended state (see Fix shape > Concurrency assumption); other concurrent mutators are unsupported scenarios. A post-revert re-verification step (re-fetch and re-apply on mismatch) shifts the window without closing it, adds non-trivial complexity, and is not in scope here. If realistic incidents surface, file a follow-up that designs around Linear's actual concurrency primitives.

## Implementation surface

### Code

**`lib/linear.sh`** — add one new peer helper, `linear_get_issue_labels`:

```bash
# Get the list of label names currently applied to an issue.
# Outputs one label name per line on stdout.
# Returns non-zero if the linear issue view call fails.
linear_get_issue_labels() {
  local issue_id="$1"
  local view_json
  view_json="$(linear issue view "$issue_id" --json --no-comments)" \
    || { printf 'linear_get_issue_labels: failed to view %s\n' "$issue_id" >&2; return 1; }
  printf '%s' "$view_json" | jq -r '(.labels.nodes // []) | .[].name'
}
```

Update the comment block at the top of `lib/linear.sh` (lines 11-22) to include `linear_get_issue_labels` in the function index.

**`skills/sr-start/scripts/orchestrator.sh`** — three changes:

1. Add the `_apply_failed_label_verified` helper from "Fix shape" above. Place it adjacent to the other dispatched-outcome helpers (above `_dispatch_issue` is fine, alongside `_record_setup_failure` and `_record_local_residue` near the top of the helper section, around lines 220-300).
2. **In `_dispatch_issue`'s post-dispatch outcome branches**, replace the existing label-add at the two failure branches:
   - **`exit_clean_no_review` branch** (current lines 580-582 — the `linear_add_label ... || printf ...` pair followed by `_taint_descendants`): replace the two-line label-add with the `if _apply_failed_label_verified … fi` block from "Fix shape". `_taint_descendants "$issue_id"` stays as the last statement of the branch.
   - **`failed` branch** (current lines 585-587 — same pair): same replacement.

   The two call sites are textually identical and should remain so after the change — copy the same block to both branches.
3. **In `_record_setup_failure`** (current line 227): replace the existing best-effort label-add with the verified helper.
   - Before: `linear_add_label "$issue_id" "$CLAUDE_PLUGIN_OPTION_FAILED_LABEL" || true`
   - After: `_apply_failed_label_verified "$issue_id" || true`

   No state revert is added here (state is still `Approved` since setup_failed paths fire before line 482's transition). The `|| true` keeps setup-failure path behavior best-effort end-to-end; the helper logs the precise failure reason to stderr internally, so no extra log line at this call site is needed.

No other call sites change. `linear_set_state` and `linear_add_label` (`lib/linear.sh:264-301`) are unchanged.

### Tests (`skills/sr-start/scripts/test/orchestrator.bats`)

Because the `exit_clean_no_review` and `failed` branches inline textually-identical blocks, partial-write coverage targets the `failed` branch only — the implementer should resist any temptation to diverge the two call sites.

**Stub extensions required** (modify the `LINEARSH` heredoc at `orchestrator.bats:76-173`):

1. **Add a `linear_get_issue_labels` stub.** Reads `STUB_LABELS_<KEY>` (newline-separated label names) and writes them to stdout. Default empty (no labels). Records the call to `STUB_LINEAR_CALLS_FILE` as `get_labels <issue_id>`. Failure flag: `STUB_GET_LABELS_FAIL_<KEY>` (returns non-zero with stderr).
2. **Extend `linear_set_state` stub** to support fail-on-revert-only. Add a second flag `STUB_SET_STATE_FAIL_ON_REVERT_<KEY>`: when set, the stub returns non-zero ONLY when `$2 == "$CLAUDE_PLUGIN_OPTION_APPROVED_STATE"` (i.e., the post-dispatch revert call). Existing `STUB_SET_STATE_FAIL_<KEY>` semantics (fail ALL calls) remain unchanged.
3. **The `linear_add_label` stub does NOT need to track applied labels.** Silent-no-op is simulated by leaving the stub's existing success/failure logic alone (no `STUB_ADD_LABEL_FAIL_<KEY>` set → returns 0) AND independently leaving `STUB_LABELS_<KEY>` empty so the `linear_get_issue_labels` stub returns no labels. The two stubs are deliberately decoupled — tests express the silent-no-op scenario by setting label-add success and `get_labels` empty.

With those stubs in place, the test cases:

- **Existing Test 3** (`hard failure: exit non-zero adds ralph-failed label, outcome=failed with exit_code`, line 352): set `STUB_LABELS_ENG_20="ralph-failed"` so the post-add verify sees the label. Add three new membership assertions on `STUB_LINEAR_CALLS_FILE`: `add_label ENG-20 ralph-failed`, `get_labels ENG-20`, `set_state ENG-20 Approved`. Existing assertions retained.
- **Existing Test 4** (`soft failure: exit 0 without state transition adds ralph-failed, outcome=exit_clean_no_review`, line 374): same additions for `ENG-30`.
- **New test: revert fails after verified label-add.** Run against the hard-failure branch (`STUB_CLAUDE_EXIT != 0`). Set `STUB_LABELS_ENG_X="ralph-failed"` (verify will see it). Set `STUB_SET_STATE_FAIL_ON_REVERT_ENG_X=1` (the new flag) so only the revert call fails; the dispatch-time `In Progress` transition still succeeds. Assert: `add_label`, `get_labels`, and `set_state ENG-X Approved` all appear in the call log; the `'orchestrator: failed to revert ... (continuing)'` stderr warning appears; progress.json end-record `outcome` is `failed`.
- **New test: label-add hard-fails, gate trips.** Run against the hard-failure branch. Set `STUB_ADD_LABEL_FAIL_ENG_X=1`. Assert: `add_label ENG-X ralph-failed` appears in the call log; `get_labels ENG-X` does NOT (helper short-circuits on label-add failure); `set_state ENG-X Approved` does NOT (gated out); the `'failed to add ralph-failed label to ENG-X; leaving state In Progress (continuing)'` stderr warning appears (matches the helper's first failure message); progress.json end-record `outcome` is `failed`.
- **New test: label silently no-ops, gate trips.** Run against the hard-failure branch. Do NOT set `STUB_ADD_LABEL_FAIL_ENG_X` (label-add returns 0). Do NOT set `STUB_LABELS_ENG_X` (default empty — verify won't find the label). Assert: `add_label ENG-X ralph-failed` and `get_labels ENG-X` BOTH appear in the call log (the verify path runs); `set_state ENG-X Approved` does NOT appear (gated out); the `'<label> did not land on ... after label-add (silent no-op'` stderr warning appears; progress.json end-record `outcome` is `failed`.
- **New test: verify-read fails after successful label-add, gate trips.** Run against the hard-failure branch. Do NOT set `STUB_ADD_LABEL_FAIL_ENG_X` (label-add returns 0). Set `STUB_GET_LABELS_FAIL_ENG_X=1` (the new flag from stub extension #1) so the post-add `linear_get_issue_labels` call returns non-zero. Assert: `add_label ENG-X ralph-failed` and `get_labels ENG-X` BOTH appear in the call log; `set_state ENG-X Approved` does NOT appear (gated out by helper return 1); the `'linear_get_issue_labels failed for ... after label-add'` stderr warning appears; progress.json end-record `outcome` is `failed`. (This case represents partial-write row 3 — labeled-but-unverified — and exercises the criterion 2b recovery path's second underlying cause.)

**`setup_failed` test surface** (every existing setup_failed test in `orchestrator.bats` — there are several around lines 666-840 covering `dag_base` empty, `linear_get_issue_branch` returns "null", `linear_set_state` after worktree create, integration worktree helper post-add merge error, etc.):

- For each existing setup_failed test that asserts `add_label ENG-X ralph-failed` (e.g. lines 808, 1064), set `STUB_LABELS_ENG_X="ralph-failed"` so the new verify-after-add gate passes on the happy path. Add a membership assertion that `get_labels ENG-X` also appears in the call log (the verify path runs).
- **New test: setup_failed with label silent no-op.** Pick any setup_failed scenario (e.g. dag_base empty for ENG-110 — see line 668). Do NOT set `STUB_ADD_LABEL_FAIL_ENG_110` (label-add returns 0). Do NOT set `STUB_LABELS_ENG_110` (default empty — verify won't find the label). Assert: `add_label ENG-110 ralph-failed` and `get_labels ENG-110` BOTH appear in the call log; the `'<label> did not land on ... after label-add (silent no-op'` stderr warning appears; progress.json end-record `outcome` is `setup_failed` with the appropriate `failed_step`. (No state revert involved — state stays `Approved` because the setup-failed path fired before the dispatch-time `In Progress` transition.)

### Documentation (same commit as the code change)

All four docs below carry the broken "remove the failed label and re-queue" recipe, or describe the orchestrator's failure-path behavior. Update each. **Important framing:** the doc-update prescriptions describe the happy-path retry recipe (label-only) and the degraded path (manual state flip) honestly. Per Partial-write outcomes, the post-fix behavior is: in most cases the orchestrator reverts state to `Approved` automatically and the operator's only retry action is to remove the label; in rare degraded paths (revert API call fails after the label landed) the issue is left `In Progress + ralph-failed` and the operator must additionally flip state. The docs must surface BOTH paths, not pretend the second doesn't exist.

- **`docs/usage.md:15`** — in the failed/exit_clean_no_review triage paragraph, replace "decide whether to retry (remove the failed label and re-queue)" with "decide whether to retry (remove the failed label — the orchestrator typically reverts state to Approved automatically; on the rare path where the revert call failed, also flip state to Approved manually — see `docs/design/linear-lifecycle.md` for the full triage recipe)". Brief in-line because this is the operator playbook; full detail lives in lifecycle.
- **`docs/design/linear-lifecycle.md:50`** — in the labels table, the "Cleared by" cell for `ralph-failed`: replace today's text with a one-line summary that pointers into the recipe at line 62 — e.g., "Operator removes the label; see [re-queue recipe](#re-queue-recipe) for happy-path and degraded steps".
- **`docs/design/linear-lifecycle.md:62`** — rewrite the "To re-queue an issue that hit `ralph-failed`" recipe to cover both paths explicitly:
  1. Read the failure record in `.sensible-ralph/progress.json` and identify the failed step (`failed` / `exit_clean_no_review` / `setup_failed`); for dispatched-outcome failures, also `cd` into the worktree and read `<stdout_log_filename>` for the session's final output.
  2. Decide retry / cancel / debug.
  3. To retry, remove the `ralph-failed` label via the Linear UI. Then **check the issue's state**:
     - If state is `Approved`: orchestrator's revert succeeded; the next `/sr-start` will pick the issue up. Done.
     - If state is `In Progress`: the orchestrator's revert call failed (see stderr / the `'failed to revert ... (continuing)'` warning in the run's log). Manually flip state to `Approved` via the Linear UI before the next `/sr-start`.
  4. (Cancellation alternative.) Mark the issue `Canceled`; the label is irrelevant in terminal states.
  Add a brief explanatory line after the recipe noting that the degraded path is a transient Linear-API blip and is logged to stderr at run-time.
- **`docs/design/outcome-model.md:32`** (`exit_clean_no_review` triage column) — update "(remove `ralph-failed`, re-queue)" to "(remove `ralph-failed` to retry; if state is still `In Progress`, also flip state to `Approved` manually — see `linear-lifecycle.md` for the full recipe)".
- **`docs/design/outcome-model.md:33`** (`failed` triage column) — currently says "Same as `exit_clean_no_review`"; transitively picks up the line-32 correction. Verify the wording reads correctly post-edit; no separate edit needed unless the same-as reference becomes ambiguous.
- **`docs/design/orchestrator.md:148`** — append "; on success also reverts state to Approved (best-effort, gated on observed label presence)" to the `exit_clean_no_review` outcome bullet.
- **`docs/design/orchestrator.md:149`** — append the same "; on success also reverts state to Approved (best-effort, gated on observed label presence)" to the `failed` outcome bullet.
- **`docs/design/orchestrator.md:151`** (`setup_failed`) — append "; label-add now goes through the verify-after-add gate (silent-no-op detection), state stays `Approved` regardless (no revert involved)" to the existing bullet. Functional behavior matches today's; the gate is a diagnostic addition.
- **`docs/design/outcome-model.md:34`** (`setup_failed` triage column) — append a sentence at the end: "If the orchestrator's stderr includes `'<label> did not land on … (silent no-op — workspace label may be missing)'`, the workspace `ralph-failed` label may have been deleted; restore it via the Linear UI before re-queueing."

### Out of doc scope

`docs/design/preflight-and-pickup.md` mentions `ralph-failed` in the context of pickup filtering and stuck-chain detection. Those references are still correct after the fix (the label is still dispatch-gating). No edit needed.

`docs/design/autonomous-mode.md` mentions `ralph-failed` in the autonomous-mode escape-hatch flow. The flow is unchanged. No edit needed.

## Acceptance

The acceptance criteria below distinguish the happy path from the two classes of degraded outcomes the spec accepts. Implementers and reviewers should read the criteria as a contract: ENG-322 is shippable when 1, 2a, 2b, 3, 4, and 5 hold. Criterion 2c is intentionally listed as a *known limitation* with a follow-up plan; ENG-322 does NOT close it.

1. **Happy-path terminal state.** After a `failed` or `exit_clean_no_review` outcome where label-add, verify, AND revert all succeed, the issue's Linear state is `Approved` and it carries the `ralph-failed` label.

2a. **Happy-path retry.** After the operator removes the `ralph-failed` label from a happy-path-terminal issue, the next `/sr-start` queues the issue without any other operator action — `linear_list_approved_issues` returns it, the preflight chain check passes, the orchestrator dispatches it.

2b. **Degraded retry — labeled `In Progress` (revert failed OR verify-read failed after successful label-add).** After a degraded outcome where the label is on (or likely on) the issue but state is `In Progress`, the operator removes the `ralph-failed` label AND flips state to `Approved` per the recipe in `docs/design/linear-lifecycle.md`; the next `/sr-start` then queues the issue without any other operator action. Two underlying causes collapse into this same recovery: (i) revert API call failed after a verified label-add (`'failed to revert ... (continuing)'` warning); (ii) `linear_get_issue_labels` failed after a successful label-add, leaving the label state unverified-but-likely-present (`'linear_get_issue_labels failed for ... after label-add'` warning). The recipe's "remove label if present; flip state" wording handles both, since label removal is a no-op when the label isn't on the issue.

2c. **Known limitation — unlabeled `In Progress` (out of scope).** Two degraded outcomes leave the issue `In Progress` with NO `ralph-failed` label: label-add hard-fails (returns non-zero), and label-add silently no-ops on a missing workspace label and verify correctly rejects (label not observed). These outcomes are visible at run-time via two distinct stderr warnings emitted by `_apply_failed_label_verified`: `'failed to add ralph-failed label to <id>; leaving state In Progress (continuing)'` (hard-fail) and `'ralph-failed did not land on <id> after label-add (silent no-op — workspace label may be missing); leaving state In Progress (continuing)'` (silent no-op). Neither is surfaced post-run by `/sr-start`, preflight, or `/sr-status`. Operator recovery requires manual board inspection. ENG-322 does NOT close this gap — the system-side surfacing path is filed as a follow-up issue tied to ENG-254 (crash detection); the operator-facing recovery doc for this class lands in the follow-up alongside the surfacing mechanism. Documenting the recovery here without surfacing would ask operators to scan `progress.json` after every run for a rare anomaly, which is not a workflow ENG-322 is positioned to ship.

3. **Bounded silent-rejoin invariant — dispatched-outcome paths only.** **For the dispatched-outcome failure paths only** (`failed`, `exit_clean_no_review`), **assuming no concurrent unintended label mutation between verify and revert** (Fix shape > Concurrency assumption) AND **assuming Linear read-after-write consistency for sequential same-session API calls** (Fix shape > Linear consistency assumption), no partial-write outcome produces an `Approved`-state issue without the `ralph-failed` label. The verify-after-add gate plus the gated state revert together guarantee this: on verify failure, the gate keeps the revert from running, so state stays `In Progress` (visible per criterion 2c). The unlabeled `In Progress` degraded outcomes (criterion 2c) do not violate this invariant because state is not `Approved`.

3b. **`setup_failed` invariant — diagnostic only, NOT closed.** The verify-after-add gate is applied to `_record_setup_failure` for diagnostic value (stderr signal when the workspace label is missing), but `setup_failed` paths fire BEFORE the dispatch-time `In Progress` transition, so state is already `Approved` when the failure handler runs and there is no state to revert. If the gate trips on a silent no-op or hard-fails, the issue remains `Approved` AND unlabeled — silent-rejoin to the next `/sr-start` queue. Closing this invariant for `setup_failed` requires either (A) introducing a new "error" state that's outside pickup, or (B) blocking dispatch until the workspace label is verified at preflight time. Both are out of scope for ENG-322. Operator recovery for setup_failed silent-no-op relies on the stderr warning being noticed at run-time; if missed, the issue will re-attempt setup on the next run, possibly hitting the same failure cause. This is a known limitation that preserves today's setup_failed behavior modulo the new diagnostic surface.

4. All existing `orchestrator.bats` tests pass (with `STUB_LABELS_<KEY>` additions to existing setup_failed tests so the new verify-after-add gate passes on their happy path). New assertions in Tests 3 and 4 assert `add_label`, `get_labels`, and `set_state ... Approved` all appear in the call log. Five new tests cover the partial-write paths (`revert fails after verified label-add`, `label-add hard-fails, gate trips`, `label silently no-ops, gate trips`, `verify-read fails after successful label-add, gate trips`, `setup_failed with label silent no-op`).

5. The four documentation surfaces above are updated in the same commit as the code change. The phrase "remove the failed label and re-queue" no longer appears in the repo's live docs. The new docs cover criterion 2a (happy-path retry — label-only) and criterion 2b (degraded retry — revert-failed → label removal + manual state flip), so an operator following the docs cannot be stranded on either of those paths. The criterion 2c paths (unlabeled `In Progress`) are NOT covered by the new docs; their operator recovery flow lands in the system-side surfacing follow-up. The spec's `Out of scope` section explicitly names this gap so reviewers do not infer from doc completeness that all degraded paths are covered.

## Notes for the autonomous implementer

- **TDD ordering:** start by adding `linear_get_issue_labels` to `lib/linear.sh` and a corresponding stub in `orchestrator.bats` (with a `lib/linear.bats` test for the production helper, mirroring existing patterns there). Then update existing Tests 3 and 4 with the new membership assertions — they will fail because the orchestrator doesn't yet call `_apply_failed_label_verified` or revert state. Then implement `_apply_failed_label_verified` and the call-site replacement in `orchestrator.sh`. Then add the three new partial-write tests (each requires the new code to be reachable). Finally update the docs.
- **Verification grep:** `grep -qFx` (fixed-string, exact-line match) is the right shape for checking the failed label appears as a complete label name in the newline-separated output of `linear_get_issue_labels`. Substring match (`grep -qF`) would false-positive on a label name that contains the failed label as a prefix.
- **Stub extensions are additive.** Existing `STUB_SET_STATE_FAIL_<KEY>` and `STUB_ADD_LABEL_FAIL_<KEY>` semantics are unchanged; new flags `STUB_SET_STATE_FAIL_ON_REVERT_<KEY>`, `STUB_LABELS_<KEY>`, and `STUB_GET_LABELS_FAIL_<KEY>` are pure additions. No existing test should need to change beyond the membership-assertion additions in Tests 3 and 4.
- **stderr warning text — single source of truth.** The four distinct warnings the implementation must emit are exactly the four shown in the helper pseudocode and the call-site block in "Fix shape" above. They are NOT collapsed into a single "could not confirm" wording — that earlier draft was inconsistent with the helper's three failure-mode messages, and the spec now treats the helper's pseudocode as authoritative. The four warnings are: (1) `'orchestrator: failed to add %s label to %s; leaving state In Progress (continuing)\n'` (label-add CLI failed); (2) `'orchestrator: linear_get_issue_labels failed for %s after label-add; label MAY be on the issue (operator: check Linear and follow the labeled-In-Progress recovery recipe in linear-lifecycle.md); leaving state In Progress (continuing)\n'` (verify-read failed); (3) `'orchestrator: %s did not land on %s after label-add (silent no-op — workspace label may be missing); leaving state In Progress (continuing)\n'` (verify-absent / silent no-op); (4) `'orchestrator: failed to revert %s to %s (continuing)\n'` (revert path, emitted by the call site, not the helper). Tests assert against substrings of these exact strings; do not paraphrase or restructure them.
- **`_record_setup_failure` change is small but non-trivial in tests.** The orchestrator.sh edit at line 227 is one line (replace `linear_add_label "$issue_id" "$CLAUDE_PLUGIN_OPTION_FAILED_LABEL" || true` with `_apply_failed_label_verified "$issue_id" || true`); no state revert is added (setup_failed paths fire pre-line-482, so state is still `Approved`). The test impact is broader: every existing setup_failed test that asserts `add_label ENG-X ralph-failed` needs `STUB_LABELS_ENG_X="ralph-failed"` so the new verify gate passes on the happy path. Search the bats file for `add_label ENG-1.. ralph-failed` to find them. Add a `get_labels ENG-X` membership assertion alongside each. The asymmetry between the dispatched-outcome paths (verify gate + state revert) and the setup_failed path (verify gate only, no revert) is intentional and worth preserving visibly in the code — both call sites use `_apply_failed_label_verified`, but only the dispatched-outcome branches gate state revert on it.
