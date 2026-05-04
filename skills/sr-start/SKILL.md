---
name: sr-start
description: Entry point for the user to dispatch the autonomous ralph-loop spec-queue. Do NOT auto-invoke. Run explicitly via /sr-start before stepping away from the desk.
disable-model-invocation: true
allowed-tools: Bash, Read, Glob, Grep
---

# Ralph Start

Dispatch the autonomous spec-queue: sort Approved Linear issues into a DAG-aware order, preview the dispatch plan, and hand control to the orchestrator which creates worktrees, invokes `claude -p` sessions, and classifies their outcomes.

**Source of truth for behavior:** `docs/specs/ralph-loop-v2-design.md`.

## Prerequisites

- `linear` CLI authenticated (`linear --version` succeeds).
- `jq` available on PATH.
- Plugin userConfig values set. The Claude Code harness prompts for these at install time; all have defaults that work with a stock Linear workflow. The eleven keys are: `design_state`, `approved_state`, `in_progress_state`, `review_state`, `done_state`, `failed_label`, `stale_parent_label`, `coord_dep_label`, `worktree_base`, `model`, `stdout_log_filename`. The five state-name keys must match the actual workflow state names in your Linear workspace; edit via `/config` or your `settings.json` if defaults don't match.
- Per-repo `.sensible-ralph.json` at the repo root declaring the run's scope — see next section.
- Workspace-scoped Linear labels exist (one-time admin setup). Label **names are userConfig-driven** — the orchestrator, `/sr-spec`, and your project's merge ritual look up labels by the values of the `failed_label`, `stale_parent_label`, and `coord_dep_label` plugin options, so the labels you create in Linear must match whatever names those options hold. Linear's label-by-name resolution silently no-ops on a nonexistent name, so preflight fails loud rather than letting labelless "marks" accumulate:
  - The label named in the **`failed_label`** option (default `ralph-failed`) — applied by the orchestrator to issues that hard-failed, exited clean without reaching review, or hit a per-issue setup failure. `linear_list_approved_issues` excludes labeled issues from subsequent runs. Preflight (`scripts/preflight_scan.sh` via `lib/preflight_labels.sh`) aborts with a setup hint if missing.
  - The label named in the **`stale_parent_label`** option (default `stale-parent`) — applied by your project's merge ritual to In-Review child issues whose blocked-by parent was amended after dispatch (review was based on pre-amendment content). Preflight-gated by the same helper whenever the option is set.
  - The label named in the **`coord_dep_label`** option (default `ralph-coord-dep`) — applied by `/sr-spec` step 12 (and ENG-281's `/sr-start` backstop) when the coord-dep scan auto-adds `blocked-by` edges to an Approved issue. Cleared by `/close-issue` step 8 once the audited edges have been removed. Preflight-gated by the same helper.

  If you've accepted the defaults, create the three labels once per workspace:
  ```bash
  linear label create --name ralph-failed --color '#EB5757' --description 'Orchestrator dispatched this issue but it did not reach the review state.'
  linear label create --name stale-parent --color '#F2994A' --description 'In-Review issue whose blocked-by parent was amended after dispatch.'
  linear label create --name ralph-coord-dep --color '#9B51E0' --description 'Has at least one coord-dep blocked-by edge auto-added by the /sr-spec scan; cleared on /close-issue.'
  ```
  If you've customized `failed_label`, `stale_parent_label`, or `coord_dep_label`, substitute their values for the `--name` argument above. The preflight error messages quote both the literal label name and the env var that points at it, so a missing or typo'd setup is unambiguous.

The orchestrator scripts have `#!/usr/bin/env bash` shebangs and source `lib/scope.sh` internally, so you can run them from any shell (zsh, fish, sh, etc.). The plugin harness auto-exports userConfig values as `CLAUDE_PLUGIN_OPTION_<KEY>` env vars in plugin subprocesses, so no manual config-path management is needed.

## Scope resolution

Which Linear projects this run drains is declared in `<repo-root>/.sensible-ralph.json` (auto-discovered via `git rev-parse --show-toplevel`, so each worktree reads its own committed version). Two shapes, either resolves to a project list at load time:

```jsonc
// Explicit — one or more projects
{ "projects": ["Project A", "Project B"] }

// Shorthand — Linear initiative name, expanded to its member projects on every invocation
{ "initiative": "My Initiative" }
```

**Default base branch.** An optional `default_base_branch` field (string) sets the branch ralph branches from when an Approved issue has no in-review parent in the queue. Defaults to `"main"` if absent. Example: `{ "projects": [...], "default_base_branch": "dev" }`.

Rules (all hard errors at load time, no silent fallbacks):

- `.sensible-ralph.json` must exist at the repo root. Missing file halts with a message pointing at the expected path.
- Exactly one of `projects` or `initiative` must be set. Both-set or neither-set fails.
- `projects` must be non-empty; `initiative` must resolve to at least one project.
- Project names are checked against Linear at query time (not pre-validated at load), so a misspelled name surfaces as an empty approved-issues list plus Linear's unknown-project error.

Blockers across any in-scope project resolve automatically — a Project B issue blocked by a Project A issue in this run's queue is pickup-ready. A blocker whose project is *outside* the scope triggers the **out-of-scope blocker** preflight anomaly with a pointer back to this file.

## Workflow (run in order)

### Step 1: Pre-flight sanity scan

```bash
"$SKILL_DIR/scripts/preflight_scan.sh"
```

If non-zero exit: STOP. Print the anomalies and ask the user how to proceed (fix the issues in Linear, cancel a bad blocker, etc.). Do NOT continue to dispatch while anomalies exist.

### Step 2: Coordination-dependency backstop scan

Defense-in-depth backstop to `/sr-spec`'s primary coord-dep scan (ENG-280).
Detects coordination dependencies between Approved peers at dispatch time —
covering issues approved before ENG-280 landed, issues approved without
`/sr-spec` (manual finalize), and couplings discovered after the fact when a
later spec reveals overlap with already-approved peers.

The scan runs **after** Step 1 because reasoning over specs whose structural
anomalies have not been triaged is wasted effort, and **before** Step 3
because `blocked-by` relations the scan accepts must exist before
`build_queue.sh`'s toposort sees the graph; otherwise the queue would be
built against an incomplete graph and require a re-run.

Detection is reasoning-driven, not regex-based. The helper assembles data;
the skill prose reasons about overlap and gates operator decisions; Linear
writes use the `coord-dep-audit` audit-comment contract from ENG-280
verbatim so `/close-issue`'s existing cleanup helper applies without
modification.

#### Sub-step 1: Orphan-relation recovery from prior runs

The recovery file `<repo>/.sensible-ralph/coord-dep-recovery.json` records
`(child, parent, rationale)` triples whose relation-add landed in Linear
during a prior `/sr-start` Step 2 but whose audit comment did NOT (per-edge
abort, per-comment partial-rollback). It is the durable provenance record
that makes orphan recovery survive across runs — without it, the next
scan's covered-pairs filter would see the orphan relation in
`existing_blockers` and fast-path the pair, leaving the relation
unauditable for `/close-issue` cleanup forever.

Schema:

```json
{
  "orphans": [
    {
      "child": "ENG-A",
      "parent": "ENG-B",
      "rationale": "<one-line text from the original gate decision>",
      "added_at": "2026-05-04T12:00:00Z"
    }
  ],
  "verify_drift": [
    {
      "child": "ENG-C",
      "newly_added_parents": ["ENG-D", "ENG-E"],
      "expected_blockers": ["ENG-F", "ENG-D", "ENG-E"],
      "actual_blockers": ["ENG-F", "ENG-D", "ENG-E", "ENG-G"],
      "audit_comment_posted": true,
      "label_added": true,
      "drifted_at": "2026-05-04T12:00:00Z"
    }
  ]
}
```

`orphans` and `verify_drift` are independent arrays; either may be empty.
Both keys must exist with array values when the file is present.

All writes use the temp-file + rename pattern so a partial write or
interrupted process cannot leave malformed JSON:

```bash
# Resolve repo root via --git-common-dir so the path is stable whether
# /sr-start runs from the main checkout or a linked worktree (matches
# build_queue.sh and orchestrator.sh).
REPO_ROOT="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
RECOVERY_FILE="$REPO_ROOT/.sensible-ralph/coord-dep-recovery.json"
mkdir -p "$REPO_ROOT/.sensible-ralph"

if [[ -f "$RECOVERY_FILE" ]]; then
  if ! jq -e 'type == "object"
              and has("orphans") and (.orphans | type == "array")
              and has("verify_drift") and (.verify_drift | type == "array")' \
       "$RECOVERY_FILE" >/dev/null 2>&1; then
    echo "step 2: $RECOVERY_FILE is malformed — manual repair required (do NOT delete; orphan triples and drift records would be lost)" >&2
    echo "  Recovery options:" >&2
    echo "    1. Hand-repair the JSON shape and re-run /sr-start." >&2
    echo "    2. Manually rebuild the orphan list by cross-referencing each ralph-coord-dep-labeled child's blocked-by relations against the parent IDs in its coord-dep-audit comments; write the diff into a fresh recovery file." >&2
    exit 1
  fi
fi
```

Auto-deletion of a malformed recovery file is NOT offered: silently losing
orphan triples would let the relations they describe slip through
covered-pairs filtering forever. The operator's recovery is one of:

* Inspect and repair the JSON shape by hand; re-run `/sr-start`.
* Manually walk Linear's `ralph-coord-dep`-labeled children, cross-reference
  each child's `blocked-by` relations against the parent IDs in their
  `coord-dep-audit` comments, and rebuild the orphan list from the diff.

**Orphan repair.** If `.orphans` is non-empty, group entries by child and
attempt to compose-and-post the audit comment now (idempotent — if a
comment already exists from a prior repair attempt, posting another is
harmless; cleanup unions over all matching audit blocks). The repair
sequence is the same compose-and-post used in Sub-step 6 for fresh writes,
just operating on triples loaded from the file rather than from the gate.

* All orphans for child X repaired → atomic-write the file with X's
  entries removed. If both `.orphans` AND `.verify_drift` are empty after
  the prune, delete the file.
* Some orphans for child X failed repair (Linear API failure, comment-post
  error) → keep X's entries; surface to operator at end of recovery
  sub-step; proceed with normal scan (the unrepaired relations are still
  in `existing_blockers`, sub-step 4 will fast-path them, but the operator
  now has a visible record they can act on next run).
* Operator aborts during recovery → exit Step 2; do NOT proceed to Step 3.

**Verify-drift surfacing.** If `.verify_drift` is non-empty, list each
entry as informational output (child ID, expected vs. actual blocker sets,
`audit_comment_posted` boolean, `drifted_at` timestamp). No auto-action:
drift records are observability artifacts, not orphans (the audit trail is
intact for committed parents). After investigating, the operator can clear
drift records manually:

```bash
jq '.verify_drift = []' "$RECOVERY_FILE" \
  | tee "$RECOVERY_FILE.tmp" >/dev/null \
  && mv "$RECOVERY_FILE.tmp" "$RECOVERY_FILE"
```

Drift surfacing does NOT block proceeding to sub-step 2.

Recovery completes BEFORE the helper runs. If the file is empty or absent
(the common path), recovery is a no-op.

#### Sub-step 2: Run the helper

```bash
SCAN_JSON=$("$SKILL_DIR/scripts/coord_dep_backstop_scan.sh") || {
  # Operator chooses: retry / skip Step 2 (proceed to Step 3 with no
  # scan; ENG-280 covered most edges already at /sr-spec time) / abort.
  :
}
```

The helper emits `{ approved: [{id, title, description, existing_blockers}, ...] }`.
See `skills/sr-start/scripts/coord_dep_backstop_scan.sh` for the full contract.

#### Sub-step 3: Trivial fast paths

* If `.approved | length` is 0 or 1 (no pairs possible): emit
  `step 2: No coordination dependencies detected.` and proceed to Step 3.
* If after candidate-pair filtering (sub-step 4) every pair is already
  covered by `existing_blockers`: emit the same one-line summary and
  proceed.

#### Sub-step 4: Reason over the bundle

1. **Compute the covered-pairs set in prose.** A pair `(A, B)` is covered
   if `B ∈ A.existing_blockers` OR `A ∈ B.existing_blockers`. Candidate
   pairs are all unordered pairs `{A, B}` where neither direction is
   covered. To generate each unordered pair exactly once, sort the
   Approved set by **numeric suffix** of the Linear ID (so
   `ENG-9 < ENG-50 < ENG-281`, not the string-lexicographic order which
   would put `ENG-281 < ENG-9`), and iterate `(approved[i], approved[j])`
   for `i < j`.

2. **Seven-item checklist per candidate pair, applied bundle-wide in one
   reasoning prompt** — extends ENG-280 step 11 sub-step 5's six-item list
   with an open-ended seventh item so coordination dependencies that don't
   fit the path/identifier/rename mental model are still surfaced:

   1. Path-level surface for spec A (files touched, restructured, renamed).
   2. Same for spec B.
   3. Shared paths between A and B.
   4. For each shared path: collide vs. disjoint section.
   5. Identifier-level overlaps (function names, env vars, config keys,
      label names).
   6. Rename/move overlaps (one moves/renames a file the other edits).
   7. **Any other sequencing dependency or shared invariant** not captured
      by 1–6: behavior changes the other depends on, test fixtures or
      helpers both modify, hooks one introduces that the other consumes,
      contract changes (return-type or argument-list changes to a function
      the other calls), shared workflow assumptions (one skill's output
      format that another skill parses). Surface each with a one-line
      rationale even if it doesn't fit the path/identifier/rename
      categories.

3. **Direction heuristic — total ordering, deterministic.** Each surfaced
   overlap commits to one `(child, parent)` direction with a one-line
   rationale. Apply the **first matching rule** and stop:

   1. **Rename-before-edit, one-sided:** exactly one spec renames or moves
      a file the other edits. The renamer is parent (rename lands first;
      edit rebases onto new path).
   2. **Interface-before-use, one-sided:** exactly one spec introduces an
      identifier (function, env var, config key, label name) the other
      consumes. The introducer is parent.
   3. **All other surfaced overlaps:** numeric-suffix tiebreaker — the
      smaller Linear-ID suffix is parent. This rule is the unconditional
      final fallback and explicitly covers: mutual renames; mutual
      interface introductions; mixed conflicting evidence (one renames,
      other introduces); same-section path collisions with no
      rename/interface signal; identifier-only collisions where neither
      side introduces (both modify an existing config key/env var/function
      contract); any other overlap rules 1 and 2 do not match.

      The rationale MUST enumerate the evidence on both sides so the
      operator sees the choice was a tiebreak, not an asymmetry the
      reasoning failed to detect: e.g., `Both modify CLAUDE_PLUGIN_OPTION_FOO; neither introduces it; numeric-suffix tiebreaker (100 < 200).`

   Two reasoning passes over identical bundles produce identical proposals
   because every rule reduces to a deterministic function of the spec
   content. Rule 3 is the catch-all by design; if a future overlap
   category emerges that is genuinely asymmetric and rule 3 produces an
   obviously-wrong direction, add a higher-priority rule before rule 3 —
   never below.

4. **One candidate per pair, even with multiple overlaps.** If A and B
   share a path AND a referenced identifier AND a rename, the proposed
   edge is **one** `blocked-by` relation with a multi-fact rationale. The
   `coord-dep-audit` JSON block only stores parent IDs.

5. **Output:** array of `{child, parent, category, rationale}` tuples.
   Category is one of `path-collide` / `identifier` / `rename` (or
   comma-joined when multi-fact).

#### Sub-step 5: Per-candidate operator gate

Present candidates one at a time. Per candidate:

```
Candidate edge: ENG-A → blocked-by ENG-B  (path-collide)
  Rationale: Both restructure `lib/scope.sh::_scope_load` —
             ENG-B introduces the function, ENG-A renames it.

  [accept / reject / abort]?
```

* **accept** — append to `accepted_edges`, move to next.
* **reject** — drop the candidate, move to next. Operator can always add
  the relation manually via Linear UI later; the next `/sr-start` will see
  it in `existing_blockers` and not re-prompt.
* **abort** — stop the gate immediately. No Linear writes have happened
  yet (writes are sub-step 6). Exit Step 2 with stderr
  `step 2: scan aborted by operator — dispatch halted`. Do NOT proceed to
  Step 3.

No `edit-rationale` (operator can edit the posted comment via Linear UI).
No `flip-direction` in v1 — reject and add the inverse manually if the
heuristic chose the wrong direction; the next `/sr-start` will see the
relation in `existing_blockers` and skip it.

**Thin-description fallback.** If a peer's description is structurally
thin (200+ chars but no concrete file-touch information — passes Step 1
but reasoning can't determine its file-touch surface with enough
confidence to rule out overlap), surface a per-peer choice rather than
halting the whole queue:

```
step 2: ENG-A description is too thin to scan reliably for
coord-dep with [ENG-B, ENG-C, ...]. Pairs involving ENG-A
cannot be classified.

Choose:
(a) accept-risk — treat ENG-A's pairs as no-overlap, proceed
    with the rest of the scan and dispatch the queue. The
    backstop's safety guarantee is suspended for ENG-A's
    pairs only.
(b) abort — stop /sr-start. Operator amends ENG-A via /sr-spec
    (add concrete file-touch detail) or removes ENG-A from
    the Approved set before re-running.
```

Choosing (a) excludes ENG-A's pairs from candidate consideration for this
run AND surfaces a stderr summary at end of Step 2:
`step 2: ENG-A's pairs were skipped due to thin description (operator accepted risk).`
The skill does NOT auto-mutate ENG-A in Linear; the operator's
risk-acceptance is a runtime decision, not a state change. Pairs that
don't involve thin peers proceed normally.

#### Sub-step 6: Per-child write loop (relations, comment, label)

Run after the gate completes with non-empty `accepted_edges`. Group edges
by child; iterate per child. The per-child sequence (relations BEFORE
comment, comment-LAST, label after comment) mirrors ENG-280 step 12 so
cleanup-time semantics are identical.

`accepted_edges_json` is a JSON array of `{child, parent, rationale}`
objects in conversation context after the gate. Iterate via jq; bash
arrays cannot model nested-record access, so the implementer indexes into
the JSON directly:

```bash
# Children to process, in numeric-suffix order so failures land on
# deterministic children across re-runs.
children=$(printf '%s' "$accepted_edges_json" \
  | jq -r '[.[].child] | unique
           | sort_by(. | sub("^[A-Z]+-"; "") | tonumber) | .[]')

for child in $children; do
  child_edges_json=$(printf '%s' "$accepted_edges_json" \
    | jq --arg c "$child" '[.[] | select(.child == $c)]')

  INITIAL_BLOCKERS=$(linear_get_issue_blockers "$child" \
    | jq -r '.[].id' | sort -u)

  # newly_added_parents — parents this run actually creates via
  # `linear issue relation add`. The audit comment lists only this
  # set; cleanup at /close-issue treats only this set as
  # delete-authority. Pre-existing parents (already in INITIAL_BLOCKERS)
  # are NEVER added — Step 2 cannot distinguish "operator added this
  # manually for a coord-dep reason" from "operator added this for a
  # semantic reason that happens to align with our scan."
  newly_added_parents=()
  edge_count=$(printf '%s' "$child_edges_json" | jq 'length')
  for (( i = 0; i < edge_count; i++ )); do
    parent=$(printf '%s' "$child_edges_json" | jq -r ".[$i].parent")

    # Concurrent-add race: pre-existing parent (operator added it
    # manually between scan and write loop). Skip relation-add — no
    # audit-set membership. The operator's manual edge keeps whatever
    # classification they gave it; Step 2 does NOT overwrite that.
    if printf '%s\n' "$INITIAL_BLOCKERS" | grep -qx "$parent"; then
      echo "step 2: WARN — accepted edge $child blocked-by $parent was added concurrently (pre-existing in INITIAL_BLOCKERS); Step 2 will not claim audit authority over it. The relation stays as-is in Linear with whatever classification the operator gave it." >&2
      continue
    fi

    if linear issue relation add "$child" blocked-by "$parent"; then
      newly_added_parents+=("$parent")
    else
      # Per-edge failure: see "Per-edge failure choices" below.
      :
    fi
  done

  # No newly-added parents → nothing to audit; skip comment + label.
  [[ "${#newly_added_parents[@]}" -eq 0 ]] && continue

  # Compose audit comment. Bullets and JSON parents array list ONLY
  # newly_added_parents (the parents this run actually created).
  body_file=$(mktemp)
  {
    printf '%s\n\n' "**Coordination dependencies added by /sr-start scan**"
    for (( i = 0; i < edge_count; i++ )); do
      parent=$(printf '%s' "$child_edges_json" | jq -r ".[$i].parent")
      rationale=$(printf '%s' "$child_edges_json" | jq -r ".[$i].rationale")
      printf '%s\n' "${newly_added_parents[@]}" | grep -qx "$parent" || continue
      printf -- '- blocked-by %s — %s\n' "$parent" "$rationale"
    done
    parents_json=$(printf '%s\n' "${newly_added_parents[@]}" \
      | jq -R . | jq -sc '{parents: .}')
    printf '\n```coord-dep-audit\n%s\n```\n\n' "$parents_json"
    printf '%s\n' "Will be removed automatically on \`/close-issue\`."
  } > "$body_file"

  if ! linear issue comment add "$child" --body-file "$body_file"; then
    rm -f "$body_file"
    # Per-comment failure: see "Per-comment failure choices" below.
    :
  fi
  rm -f "$body_file"

  # Label add — log-and-continue (label is observational; the comment
  # is the load-bearing artifact for cleanup).
  linear_add_label "$child" "$CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL" \
    || echo "step 2: failed to add coord-dep label to $child — continuing" >&2

  # Per-child verify (sub-step 7).
  EXPECTED=$(printf '%s\n' "$INITIAL_BLOCKERS" "${newly_added_parents[@]}" \
    | sort -u)
  ACTUAL=$(linear_get_issue_blockers "$child" \
    | jq -r '.[].id' | sort -u)
  if [[ "$EXPECTED" != "$ACTUAL" ]]; then
    echo "step 2: blocker-set mismatch on $child" >&2
    echo "  expected: $EXPECTED" >&2
    echo "  actual:   $ACTUAL" >&2
    echo "step 2: aborting before Step 3 — investigate manually" >&2
    # Persist verify_drift entry per the recovery-file schema before
    # aborting Step 2 (see sub-step 7).
    return 1
  fi
done
```

**Per-edge failure choices** (when `linear issue relation add` fails —
applies only to parents not already in `INITIAL_BLOCKERS`):

* **retry** — re-attempt the same parent.
* **skip-this-edge** — drop this parent from `newly_added_parents`. The
  audit comment will not list it. Operator can re-add manually via Linear
  UI; next `/sr-start` will see it in `existing_blockers` and skip it
  silently. All skipped edges are coord-dep (not PREREQS), so
  skip-this-edge is always safe.
* **abort** — stop the loop. Children processed before the failure are
  fully audited. The current child has partial relations without an audit
  comment. **Before exiting**, append each `(child, parent, rationale)`
  triple from `newly_added_parents` for the current child to
  `<repo>/.sensible-ralph/coord-dep-recovery.json`'s `orphans` array (atomic
  write per the temp+rename pattern). The next `/sr-start` reads the file
  at sub-step 1 and attempts repair (compose-and-post the audit comment
  from the persisted rationale). Surface the manual recovery recipe inline
  for situational awareness:

  ```
  linear issue relation delete <child> blocked-by <parent>
  ```

  Do NOT proceed to Step 3.

**Per-comment failure choices** (when `linear issue comment add` fails
after relations were added):

* **retry** — usually transient.
* **rollback** — best-effort `linear issue relation delete "$child" blocked-by "$parent"`
  for each entry in `newly_added_parents`. By construction
  `newly_added_parents` contains only relations Step 2 actually created;
  pre-existing operator-set blockers are never touched. **Re-fetch
  blockers** after the delete sweep; for each parent in
  `newly_added_parents` still present (delete failed), append the
  `(child, parent, rationale)` triple to the recovery file's `orphans`
  array. Do NOT add label; do NOT proceed to Step 3.

No `proceed-anyway` option. The recovery file is the durable resume
mechanism; the next `/sr-start` auto-repairs from it.

**Label-add failure** is log-and-continue.

#### Sub-step 7: Per-child verification

Inline at the end of each child's iteration (see shell sketch above). On
any mismatch, exit Step 2 non-zero and do NOT proceed to Step 3.

`EXPECTED == ACTUAL` exact-set check carries a known limitation: a
concurrent semantic-blocker add by a human between `INITIAL_BLOCKERS`
capture and the post-add re-fetch makes `ACTUAL ⊃ EXPECTED` and aborts.
Mitigation: rare; operator can re-run `/sr-start` and the scan fast-paths
through.

**On verify failure: persist a `verify_drift` record to the recovery file
before aborting Step 2.** Verify only runs after all sub-step 6 writes
succeeded, so the audit trail for `committed_parents` is intact and
orphans aren't possible — but operators benefit from a durable record that
distinguishes "this child's run aborted at verify with these blockers"
from "this child's run completed cleanly." Schema is the `verify_drift`
array in sub-step 1's recovery-file shape. The next `/sr-start`'s sub-step
1 surfaces drift entries to the operator (informational; no auto-repair,
since nothing is broken).

Drift entries do NOT block subsequent dispatch.

### Step 3: Build the ordered queue

```bash
sr_root="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.sensible-ralph"
mkdir -p "$sr_root"
queue_pending="$sr_root/queue_pending.txt"
if "$SKILL_DIR/scripts/build_queue.sh" "$queue_pending"; then
  : # exit 0: non-empty queue published, continue to step 3
else
  rc=$?
  case "$rc" in
    2) echo "/sr-start: no pickup-ready Approved issues. Nothing to dispatch." >&2 ; exit 0 ;;
    *) echo "/sr-start: build_queue.sh failed with exit $rc" >&2 ; exit "$rc" ;;
  esac
fi
```

`build_queue.sh` lists pickup-ready Approved issues (state == `$CLAUDE_PLUGIN_OPTION_APPROVED_STATE`, no `$CLAUDE_PLUGIN_OPTION_FAILED_LABEL` label, every blocker in `$CLAUDE_PLUGIN_OPTION_DONE_STATE`, `$CLAUDE_PLUGIN_OPTION_REVIEW_STATE`, or `$CLAUDE_PLUGIN_OPTION_APPROVED_STATE`), then topologically sorts them via `toposort.sh` with Linear priority as the tiebreaker (priority=0 sorts last because Linear uses 0 for "no priority"). Approved blockers are accepted because the orchestrator dispatches Approved chains in topological order — the parent reaches In Review before the child runs and `dag_base.sh` picks up the parent's branch as the base. Issues with blockers in any other state (Triage, Backlog, Todo, In Progress, Canceled, Duplicate) are skipped with a warning to stderr.

The script publishes issue IDs (no header) atomically to `queue_pending.txt` via tempfile + same-directory `mv`. Exit codes: `0` = non-empty queue published; `1` = construction failure (toposort cycle, linear error) — STOP and surface to the user; `2` = no pickup-ready Approved issues — exit clean, nothing to dispatch. On failure or empty-queue paths, the destination file is left untouched, and `ordered_queue.txt` (the committed-run record read by `/sr-status`) is *not* affected — aborts and empty queues never create phantom runs.

### Step 4: Dry-run preview and confirmation

Print the pending queue (`queue_pending.txt`) to the user. For each issue, also print the base branch selection (call `scripts/dag_base.sh <issue_id>` for each). Format:

```
Queue (5 issues):
  ENG-190: Add foo (base: main)
  ENG-191: Extend foo (base: eng-190-add-foo)
  ENG-192: Integrate foo and bar (base: INTEGRATION eng-190-add-foo eng-188-add-bar)
  ...
```

Ask the user to confirm (accept / skip specific issues / abort). Do NOT proceed without explicit confirmation — this is the point where the user sees what will be dispatched before walking away.

### Step 5: Dispatch via orchestrator

```bash
sr_root="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.sensible-ralph"
"$SKILL_DIR/scripts/orchestrator.sh" "$sr_root/queue_pending.txt"
```

The orchestrator generates this run's `run_id` and atomically publishes `# run_id: <iso>` plus the issue list to `.sensible-ralph/ordered_queue.txt` (the authoritative committed-run record read by `/sr-status`) before any progress.json record lands. It then processes the queue sequentially, creates worktrees, invokes `claude -p`, classifies outcomes (using Linear state transition AS WELL AS exit code — exit 0 alone does not imply success), propagates failure taint downstream, and appends per-issue records to `.sensible-ralph/progress.json` at the repo root (resolved via `git --git-common-dir` so the path is stable whether `/sr-start` is invoked from the main checkout or a linked worktree).

The orchestrator runs foreground — the user should expect the session to block until the queue completes or all remaining issues are tainted. Each issue's `claude -p` output is tee'd to `<worktree>/<CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME>` for later inspection.

## When back

After the orchestrator returns:

- **`/sr-status`** prints a sectioned Done / Running / Queued table for the latest run — faster than `jq`-ing `.sensible-ralph/progress.json` by hand. Also useful mid-run to see what's currently dispatching. It reads `run_id` from the `# run_id: <iso>` header on line 1 of `.sensible-ralph/ordered_queue.txt` (published only by the orchestrator at startup) and partitions `progress.json` records by that value.
- **`.sensible-ralph/ordered_queue.txt`** (committed-run record) is written exclusively by the orchestrator — line 1 is `# run_id: <iso>`, subsequent lines are issue IDs. **`.sensible-ralph/queue_pending.txt`** is a transient build artifact internal to `/sr-start`'s build/preview phase (issue IDs only, no header) and is never read by `/sr-status`.
- **`.sensible-ralph/progress.json`** at the repo root lists all dispatched/skipped issues with `event: "start"` (dispatch moment) and `event: "end"` (final outcome) records.
- **`in_review` issues:** `cd` into the worktree, run a `claude --resume` if the session is still available, review code per the QA plan in the Linear comment, then run your project's merge ritual from a session at the main-checkout root — not from inside the worktree.
- **`failed` / `exit_clean_no_review` issues** (labeled `ralph-failed`, descendants tainted): `/sr-status` renders an indented sub-block under the row with the inline diagnostic `hint` (ENG-308), the worktree log path (`transcript:`), and the full JSONL transcript path (`session:`). Read whichever pointer is more useful — the worktree log for the session's final stdout, the JSONL for the full tool-trace. Decide: retry (remove the `ralph-failed` label — the orchestrator reverts state to `Approved` automatically; see `docs/design/linear-lifecycle.md` if the revert failed — and re-queue), cancel the issue, or debug interactively.
- **`setup_failed` issues** (labeled `ralph-failed`, descendants tainted): orchestrator couldn't set up the worktree (branch lookup failed, dag_base returned garbage, etc.). Check the `failed_step` field in `.sensible-ralph/progress.json` — that's the operator signal here, not a session diagnostic (no claude session was invoked, so no transcript exists). Worktree cleanup has already run for state this invocation created.
- **`local_residue` issues** (Linear NOT mutated, descendants NOT tainted): the target worktree path or branch already existed at the start of dispatch — the orchestrator never touched it. Check the `residue_path` and `residue_branch` fields in `.sensible-ralph/progress.json`, manually clean up the residue (commit or remove), then re-queue. Operator state (manual mkdir, prior crashed run, in-flight branch) is preserved unchanged.
- **`unknown_post_state` issues** (Linear NOT mutated, descendants NOT tainted): claude exited 0 but the post-dispatch Linear state fetch failed transiently. `/sr-status` surfaces the same diagnostic sub-block as `failed` rows so the transcript is one click away. Open the issue in Linear: if state is `In Review`, treat as success (no `ralph-failed` was applied); if it's still `In Progress`, treat as a soft failure and re-queue.

## Red flags / when to stop

- **Pre-flight anomalies present:** do NOT dispatch. Surface the list; let the user fix in Linear first.
- **Coord-dep scan aborted:** do NOT dispatch. The aborted scan has either left no Linear writes (gate-time abort) or surfaced a write-loop failure with a recovery recipe; resolve before re-running `/sr-start`.
- **Cycle in toposort:** design problem in the blocker graph; the user must break the cycle by canceling or re-scoping one of the issues.
- **Preview shows unexpected work:** abort and ask the user. Never dispatch a queue the user didn't sign off on.
- **Linear auth failure:** abort immediately — the orchestrator will fail on every issue, producing noise with no work done.

## Notes

- The skill sets `disable-model-invocation: true` so it never auto-invokes. It is a user-driven trigger.
- The orchestrator's classification uses the Linear state post-dispatch (`exit 0` AND state == `$CLAUDE_PLUGIN_OPTION_REVIEW_STATE`) to distinguish true success from "session exited clean without completing `/prepare-for-review`" (the `exit_clean_no_review` outcome, which is also treated as `ralph-failed`).
- Worktree paths follow the convention: `$REPO_ROOT/$CLAUDE_PLUGIN_OPTION_WORKTREE_BASE/<branch-slug>` — project-local, `.gitignore`d, matches `superpowers:using-git-worktrees`.
- The orchestrator writes `.sensible-ralph-base-sha` to each worktree before dispatch. This is the cross-skill contract with `/prepare-for-review`, which uses it to scope codex review and the handoff summary to just the session's commits.
