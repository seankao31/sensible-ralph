# Preflight and pickup
The two gates an Approved Linear issue passes through before the orchestrator dispatches it: the per-issue pickup rule that decides queue eligibility, and the per-run preflight anomaly scan that blocks the entire dispatch loop on any unresolved hazard.

Two checks decide whether a Linear issue can be dispatched by `/sr-start`:

- The **pickup rule** — a per-issue check evaluated at queue-construction time. An issue that fails it is silently filtered from this run.
- The **preflight scan** — a whole-run check evaluated before the dispatch loop. Any anomaly aborts the run with a list of operator-fixable conditions.

The split exists because the two failure modes have different blast radii. A non-pickup-ready issue is normal — it just isn't ready yet — and the right behavior is to skip it and dispatch what *is* ready. A preflight anomaly indicates a structural problem the operator must triage (a canceled blocker on an Approved issue, a missing PRD, a workspace label that doesn't exist) and the right behavior is to refuse to dispatch anything until it's resolved.

## The pickup rule

An Approved issue is **strictly pickup-ready** for autonomous dispatch when ALL three conditions hold:

1. **State is `Approved`** — matched against `$CLAUDE_PLUGIN_OPTION_APPROVED_STATE`. Approval is the operator's signal that the PRD in the issue description is implementation-ready and dispatch is authorized; nothing earlier in the lifecycle (`Todo`, `In Design`) is contractually complete enough for autonomous handling.
2. **No `ralph-failed` label** — matched against `$CLAUDE_PLUGIN_OPTION_FAILED_LABEL`. The label is dispatch-gating: it marks issues whose previous dispatch hard-failed, exited clean without reaching review, or hit a setup error. Re-dispatch requires the operator to inspect the failure and clear the label deliberately, never silently.
3. **Every `blocked-by` parent** is either:
   - already in `Done` or `In Review`, OR
   - in `Approved` AND a member of this run's queue, AND its own blockers satisfy this rule recursively.

Rule 3 is what makes overnight execution of dependency chains possible. An Approved parent that is queued ahead of its child reaches `In Review` (via the parent's own `/prepare-for-review`) before the child's dispatch begins, and `dag_base.sh` then picks up the parent's branch as the child's base. The recursion matters: an Approved blocker counts as runnable only if its own blockers are themselves runnable — a chain stuck three levels deep does not become unstuck because the immediate parent looks Approved.

### Why Canceled blockers don't count as resolved

Cancellation is a judgment call — someone decided the parent was not worth doing — and that judgment may have invalidated the child's premise too. Silently dispatching the child would substitute the orchestrator's reading of "blocker resolved" for the operator's read of "what does this dependency relationship even mean now." The same reasoning applies to `Duplicate`: both states surface as preflight anomalies, forcing the operator to clean up before dispatch. The supported way to declare "this is no longer a real blocker" is to remove the `blocked-by` relation explicitly:

```bash
linear issue relation delete "$CHILD_ID" blocked-by "$PARENT_ID"
```

After that, the child is unblocked structurally rather than by inference. (See [`linear-lifecycle.md`](linear-lifecycle.md) for the same rule applied at close time by `/close-issue`.)

## The pickup filter

`skills/sr-start/scripts/build_queue.sh` implements the pickup rule and produces the run's ordered queue.

**Step 1 — list candidates.** `linear_list_approved_issues` (in `lib/linear.sh`) makes one `linear issue query --project "$project" --all-teams --limit 0 --json` call per project named in `SENSIBLE_RALPH_PROJECTS`, concatenates the results, and pipes them through a jq filter that keeps only nodes whose state and labels satisfy conditions 1 and 2 of the pickup rule:

```jq
.nodes[]
| select(.state.name == $state)
| select((.labels.nodes | map(.name) | index($failed_label)) == null)
| .identifier
```

The `index($failed_label) == null` form is the label exclusion: an issue carrying `ralph-failed` (or whatever name `failed_label` resolves to) is dropped from the candidate set entirely.

**Step 2 — evaluate condition 3 per candidate.** `build_queue.sh` captures the candidate IDs as `approved_set` (a space-delimited string with leading and trailing spaces so substring matches are unambiguous), then for each candidate fetches `blocked-by` relations via `linear_get_issue_blockers` and walks the list:

- A blocker in `Done` or `In Review` is resolved — continue.
- An Approved blocker is accepted **only if its ID appears in `approved_set`**. An Approved-but-not-in-set blocker fails the rule and the candidate is skipped with a warning to stderr distinguishing the two failure causes (in-scope-but-not-queueable vs. out-of-scope project).
- A blocker in any other state (`Todo`, `In Progress`, `Canceled`, `Duplicate`, `Triage`, `Backlog`) fails the rule and the candidate is skipped.

**Step 3 — toposort.** Candidates that pass condition 3 are written with their priority and blocker IDs to a temporary file consumed by `toposort.sh`, which produces a dependency-respecting order with Linear priority as the tiebreaker (priority=0 sorts last because Linear uses 0 for "no priority").

The orchestrator does not re-evaluate pickup-readiness mid-run. Toposort plus the parent-runs-first invariant guarantees that by the time a child is dispatched, every Approved-blocker-in-queue has already transitioned to `In Review`, and `dag_base.sh` can read the parent's branch directly.

## Preflight anomaly set

`skills/sr-start/scripts/preflight_scan.sh` runs before the dispatch loop. It scans every Approved issue in scope (via the same `linear_list_approved_issues`) and exits non-zero if any anomaly is found. The orchestrator does not run while anomalies exist — the operator triages in Linear and re-runs `/sr-start`.

The anomaly set:

### Canceled blocker

- **Detection.** The issue has a `blocked-by` parent whose state is `Canceled`.
- **Why it blocks the run.** A canceled parent will never reach `Done` or `In Review`, so the child can never become pickup-ready under the strict rule. Auto-dispatching would substitute orchestrator inference for the operator's intent (see [Why Canceled blockers don't count as resolved](#why-canceled-blockers-dont-count-as-resolved)). Surfacing the situation forces the operator to decide whether the child still makes sense at all.
- **Operator fix.** Remove the `blocked-by` relation if the dependency was resolved out of band (`linear issue relation delete <child> blocked-by <parent>`), or cancel the child if the parent's cancellation makes the child meaningless.

### Duplicate blocker

- **Detection.** The issue has a `blocked-by` parent in state `Duplicate`. (Distinct from a duplicate ID appearing multiple times in the blocked-by list, which is reported separately as a data-hygiene warning.)
- **Why it blocks the run.** Same as Canceled — the parent's terminal state means the child cannot become unblocked through normal lifecycle progression.
- **Operator fix.** Re-point the relation at the duplicate's canonical issue, or delete it.

### Deep-stuck / circular dependency chain

- **Detection.** `_chain_runnable` recurses through Approved blockers, accumulating a visited list. It returns false when it reaches a blocker in a non-runnable state (Todo, In Progress, ralph-failed-labeled Approved, etc.) deep in the chain, OR when it encounters an issue already in the visited list (a cycle).
- **Why it blocks the run.** The chain cannot clear during this run, so even though the child's *immediate* blocker may look Approved-and-queued, dispatching the child would land it on a base whose parent never reaches `In Review`. A cycle is a structural error in the issue graph that no amount of waiting will resolve.
- **Operator fix.** Inspect the chain in Linear, fix the deepest non-runnable issue (write a PRD, clear `ralph-failed`, cancel an obsolete ticket), or break the cycle by removing one `blocked-by` edge.

### Missing PRD

- **Detection.** `_desc_nonws_chars` strips whitespace from the issue description and reports the codepoint length; an anomaly fires when the count is `< 200`.
- **Why it blocks the run.** An Approved-but-empty issue means the dispatch contract was not met — the autonomous session has no spec to implement, and the dispatched `claude -p` would either fail noisily or invent scope. Catching this at preflight is much cheaper than letting it surface as a `failed` outcome that taints downstream issues for the rest of the run.
- **Operator fix.** Write the PRD into the issue description, or move the issue back to `Todo` / `In Design` while it's drafted. The 200-character threshold is a heuristic; tune it in `preflight_scan.sh` if false-positives (short-but-valid PRDs) or false-negatives (long-but-empty descriptions) appear.

### Out-of-scope blocker

- **Detection.** A candidate's Approved blocker has a `project` field whose name is not in `SENSIBLE_RALPH_PROJECTS` (the in-scope project list resolved from `<repo-root>/.sensible-ralph.json` by `lib/scope.sh`). The check distinguishes two sub-cases for messaging:
  - Blocker's project IS in scope but the blocker isn't in the queue → likely `ralph-failed`-labeled.
  - Blocker's project is OUTSIDE scope → operator must add the project to scope or resolve the relationship.
- **Why it blocks the run.** The blocker cannot clear during this run regardless of its state, because the orchestrator never queries that project (out of scope) or filters out the blocker (in scope but ralph-failed). Without this anomaly, the child would silently never become pickup-ready and the operator would have no clear signal about the cause.
- **Operator fix.** Add the missing project to `<repo-root>/.sensible-ralph.json`, or remove the cross-scope `blocked-by` relation. See [`scope-model.md`](scope-model.md) Decision 4 for the full rationale.

### Missing workspace label

- **Detection.** `lib/preflight_labels.sh::preflight_labels_check` queries Linear once per configured label name (`ralph-failed`, `stale-parent`, and `ralph-coord-dep` — userConfig-driven via the `failed_label`, `stale_parent_label`, and `coord_dep_label` plugin options) and reports any that don't exist as a workspace-scoped label.
- **Why it blocks the run.** Linear's label-by-name resolution silently no-ops on a nonexistent label, so an unconfigured workspace would let the orchestrator keep "marking" failed issues with labels that never land — and then `linear_list_approved_issues`'s exclusion filter would silently retry every failed issue forever. Failing loud at preflight is the only way to surface the missing setup; the per-label diagnostic names both the literal label and the env var that points at it so the operator knows whether to create the label or update the config.
- **Operator fix.** Create the label once per workspace (the SKILL.md prerequisites section provides the exact `linear label create` commands), or update the corresponding plugin option to name a label that already exists. See [`skills/sr-start/SKILL.md`](../../skills/sr-start/SKILL.md) Prerequisites.

## Coordination-dependency scan

A reasoning-driven gate that runs between the pickup rule and the preflight anomaly set. Detects coordination dependencies — cases where two specs touch the same file, identifier, or invariant in ways that demand a particular merge order — and converts them into `blocked-by` edges so toposort dispatches them in a sequence that avoids merge conflicts.

The scan is structurally distinct from both other gates:

- A non-pickup-ready issue is silently skipped; a coord-dep candidate pauses dispatch and asks the operator to triage.
- A preflight anomaly is a structural defect the operator fixes in Linear; a coord-dep candidate is a *latent* dependency the scan surfaces for the operator to confirm or reject.

There are two producers of coord-dep edges, with overlapping but non-identical coverage:

- **`/sr-spec` step 11** (ENG-280) — primary scan, runs at finalize time. Compares one new spec against the Approved peers existing at that moment. Catches couplings as they're introduced; misses everything that was already Approved when ENG-280 landed, plus everything that bypasses `/sr-spec` (manual finalize via Linear UI).
- **`/sr-start` Step 2** (ENG-281) — backstop scan, runs at dispatch time. Compares all-pairs across the current Approved set. Catches the migration cases (pre-ENG-280 issues, manual-finalize issues) and post-hoc couplings revealed when a later spec exposes overlap with already-approved peers that pairwise scans never had cause to surface. The backstop runs after Step 1's preflight (no point reasoning over specs whose structural anomalies haven't been triaged) and before Step 3's `build_queue.sh` (`blocked-by` edges the scan accepts must exist before toposort sees the graph).

Both producers emit the **same audit-comment shape**: a `**Coordination dependencies added by /sr-... scan**` header, a bulleted list of `blocked-by ENG-X — <rationale>` lines, and a `coord-dep-audit` fenced JSON block carrying the parent IDs. The fenced JSON block is the load-bearing artifact for cleanup — bullet text is not delete authority. Both producers also apply the `ralph-coord-dep` workspace label (configurable via `coord_dep_label`) to each child that received at least one accepted edge. The label is observational; the audit comment is what `/close-issue` parses.

`/close-issue` step 8 invokes `skills/close-issue/scripts/cleanup_coord_dep.sh`, which queries the issue's comments, parses every `coord-dep-audit` block (per-block jq, isolated per comment), unions the parent ID sets, deletes the corresponding `blocked-by` relations best-effort, and clears the `ralph-coord-dep` label on full success. One cleanup helper handles both producers — no per-producer divergence — because the audit format is the cross-skill contract. See [`linear-lifecycle.md`](linear-lifecycle.md) and [`skills/close-issue/SKILL.md`](../../skills/close-issue/SKILL.md) step 8.

The backstop's per-child write loop and per-child verification carry a shared **recovery file** at `<repo>/.sensible-ralph/coord-dep-recovery.json` for orphan-relation auto-repair across runs. Per-edge abort or per-comment partial-rollback may leave a relation in Linear without an audit comment; the recovery file persists `(child, parent, rationale)` triples so the next `/sr-start`'s sub-step 1 can compose-and-post the missing audit comment idempotently. A separate `verify_drift` array records benign concurrent UI adds for operator observability; drift entries are informational, not orphans. Atomic temp-file + rename writes ensure the file is never half-written; auto-deletion on malformed JSON is deliberately not offered because losing orphan triples would let unauditable relations slip through covered-pairs filtering forever.

Operator interaction in the backstop scan is per-candidate (accept / reject / abort), not all-or-nothing. Rejected candidates can be added back manually via Linear UI and the next `/sr-start` will see them in `existing_blockers` and not re-prompt. A peer with a structurally thin description that the reasoning step cannot classify is handled per-peer (accept-risk for that peer's pairs only, or abort the run) so one weak spec doesn't block dispatch of unrelated Approved issues.

## Pre-existing blocker vs. in-run queue: the non-obvious case

The third pickup condition has a subtlety that catches operators by surprise. An Approved blocker satisfies the condition only if it is **in this run's approved set** — the result of `linear_list_approved_issues` for the current `/sr-start` invocation.

An Approved blocker that is **not** in the set fails the condition, even though it looks state-eligible:

- **`ralph-failed`-labeled.** The blocker carries the label from a prior run. `linear_list_approved_issues`'s jq filter excludes it, so it doesn't enter the queue. The child cannot ride a chain through it.
- **Out-of-scope project.** The blocker is in a Linear project not declared in `<repo-root>/.sensible-ralph.json`. The orchestrator never queries that project, so the blocker is never observed as queueable.
- **Filtered out for any other reason.** Any future filter applied during candidate listing has the same effect.

Without this membership check, the child would be dispatched against the default base (`main`, or whatever `default_base_branch` resolves to) with a stale parent dependency — the pickup rule would treat the Approved-state blocker as runnable, but the orchestrator would never actually dispatch it, so `dag_base.sh` would fall back to the default base and the child's commits would land without the parent's. The check in `build_queue.sh` (and the recursive version in `_chain_runnable`) explicitly tests `approved_set` membership, not just state, to rule this out.

The two preflight anomalies that surface this case — the out-of-scope-blocker and the in-scope-but-not-queueable variant of the stuck-chain anomaly — give the operator different fixes for different causes (add a project to `.sensible-ralph.json` vs. clear `ralph-failed`), but both prevent the silent-misdispatch outcome.

## See also

- [`linear-lifecycle.md`](linear-lifecycle.md) — state-by-state meaning of `Approved`, `In Review`, `Done`; the role of `ralph-failed` in the lifecycle; and the same Canceled-blocker rule applied at close time by `/close-issue`.
- [`scope-model.md`](scope-model.md) Decision 4 — full rationale for the out-of-scope-blocker anomaly and how `lib/scope.sh` produces `SENSIBLE_RALPH_PROJECTS` from `<repo-root>/.sensible-ralph.json`.
