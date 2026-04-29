# Multi-parent INTEGRATION merge: leave conflicts for the session to resolve

## Problem

`lib/worktree.sh` exposes two helpers that merge parent branches into the
issue's worktree:

- **`worktree_merge_parents`** — merges N parents into an *existing*
  worktree+branch (used in the orchestrator's reuse path, the common
  case under ENG-279's per-issue branch lifecycle).
- **`worktree_create_with_integration`** — creates a fresh worktree at
  `$SENSIBLE_RALPH_DEFAULT_BASE_BRANCH` and merges N parents into it
  (used in the orchestrator's fallback create path for INTEGRATION mode).

Both helpers handle merge conflicts asymmetrically:

- **Single parent (`parent_count == 1`):** conflict is left in the
  worktree; helper returns 0; the dispatched session resolves it
  inline. This was the working contract under ENG-279.
- **Multi parent (`parent_count >= 2`):** helper aborts the merge with
  `git merge --abort` and returns 1; the orchestrator records
  `setup_failed`, labels the issue `ralph-failed`, and taints
  downstream issues.

There is no principled reason for this asymmetry. The dispatched
session has Claude; Claude resolves merge conflicts routinely (see
`/close-issue`'s rebase ritual). The fail-fast policy forces operator
triage for something the autonomous session is equipped to handle.

The original asymmetry guarded against a real concern: when parent A
merges cleanly but parent B conflicts, git refuses subsequent merges
while in MERGING state, so parent C would be silently dropped if the
helper just returned 0. The helper had no way to communicate "B is
unresolved AND C never got attempted" to the dispatched session.

This spec resolves both: the asymmetry, and the silent-drop hole.

## Solution overview

Both helpers leave conflicts in the worktree on any `parent_count` and
return 0. To avoid silent-drop, on conflict they write a marker file
listing the **full original parent list** to
`<worktree>/.sensible-ralph-pending-merges`. The dispatched session
detects the marker, resolves the in-progress conflict, commits the
resolution, and re-invokes `worktree_merge_parents` with the marker's
contents. The helper is idempotent — it skips parents that are already
ancestors of HEAD (already merged) and attempts only the remaining
ones — so re-runs drain the queue. The marker is deleted by the helper
once all parents are ancestors of HEAD.

This matches the single-parent contract on the conflict-leaves-in-place
axis. The marker file generalizes it across `parent_count`.

## Data contract: `.sensible-ralph-pending-merges`

- **Path:** `<worktree>/.sensible-ralph-pending-merges` (peer of
  `.sensible-ralph-base-sha` and the dispatch log file).
- **Format:** plain text, one parent ref per line, in the order
  originally requested. Refs are the resolved form (local short-name
  or `origin/<branch>`) — the same form `worktree_merge_parents`
  computes from its argument list.
- **Lifecycle:**
  - Written by the helper on conflict — overwriting any prior marker.
  - Deleted by the helper at the end of a clean run (loop exits without
    a conflict). Deletion is unconditional (the helper does not assume
    a marker existed at start).
  - Never mutated by the orchestrator or the dispatched session
    directly.
- **Content invariant:** the marker always lists the **full original
  list** the caller passed in, not the remaining-after-conflict list.
  Idempotent re-runs depend on `merge-base --is-ancestor` to skip
  already-merged parents; they do not depend on marker mutation.

## Helper changes (`lib/worktree.sh`)

Both `worktree_create_with_integration` and `worktree_merge_parents`
get the same shape of change. The merge loop becomes:

```
1. Resolve and validate parent refs (existing behavior, unchanged).
2. For each parent in resolved_refs, in order:
   a. If `git merge-base --is-ancestor parent HEAD` → continue.
      (worktree_merge_parents already does this; add the same skip to
       worktree_create_with_integration so its idempotence matches.)
   b. Run `git merge parent --no-edit`. On success → continue.
   c. On non-zero exit, check `git diff --name-only --diff-filter=U`:
      - If unmerged files exist → conflict path:
        - Write the marker file with the resolved_refs list (one per
          line, original order).
        - Return 0. Worktree is left in MERGING state.
      - If no unmerged files → genuine merge error path:
        - Print existing error message to stderr.
        - Return 1.
3. After the loop exits without conflict (all parents merged or
   skipped):
   - Remove the marker file if it exists (`rm -f`).
   - Return 0.
```

The asymmetric `if [[ "$parent_count" -eq 1 ]]; then return 0; fi`
block is **removed entirely** from both helpers. The single-parent
case falls through into the same conflict path as multi-parent: marker
written (with the single ref on it), return 0. Functionally
equivalent to today's single-parent behavior, plus a marker file the
session can read.

`worktree_create_with_integration` additionally needs the
`merge-base --is-ancestor` skip added (it currently lacks one;
`worktree_merge_parents` already has it from ENG-279). This is
required for the helper to be re-invokable post-conflict — without
the skip, re-running on a partially-merged worktree would attempt
to merge already-merged parents and emit "Already up to date"
messages or, for the conflicting parent, fail in unexpected ways.

## Orchestrator changes (`skills/sr-start/scripts/orchestrator.sh`)

The `_dispatch_issue` function calls both helpers. Today, both call
sites treat helper non-zero exit as `setup_failed`:

```bash
worktree_merge_parents "$path" ${merge_parents[@]+"${merge_parents[@]}"}
if [[ $? -ne 0 ]]; then
  set -e
  _record_setup_failure "$issue_id" "worktree_merge_parents" "$timestamp"
  return 1
fi
base_sha="$(git -C "$path" rev-parse HEAD)"
```

After this change:

- The helper now returns 0 with a marker file on conflict, so the
  `_record_setup_failure` branch is no longer entered for conflicts.
  The genuine-error path (return 1) is unchanged.
- After the helper returns 0, the orchestrator checks for the marker
  file. If present, log a single line to stderr:

  ```
  orchestrator: <issue_id> dispatched with pending parent merges (conflicts to resolve in-session): <space-separated parent list>
  ```

  Then proceed normally — `base_sha` capture, `.sensible-ralph-base-sha`
  write, dispatch.

The notice fires at both call sites (reuse path line ~426 and create
path line ~444). No change to `progress.json` schema; no change to
`base_sha` capture semantics.

`base_sha` invariant preservation:
- Clean merge: `base_sha` = post-all-merges HEAD (parents are
  ancestors → excluded from `/prepare-for-review` diff). ENG-279
  invariant preserved.
- Conflict: `base_sha` = pre-conflict HEAD. The agent's resolution
  commit and any subsequent parent merges land **after** `base_sha`,
  so they appear in the `/prepare-for-review` diff for reviewer
  awareness. Matches today's single-parent conflict behavior.

## Session-side drain (`skills/sr-implement/SKILL.md`)

Step 2 ("Check for unresolved merge conflicts") is rewritten. New
content:

```markdown
## Step 2: Drain pending parent merges

Check whether the orchestrator left work for you:

    git status --short
    ls .sensible-ralph-pending-merges 2>/dev/null

If neither shows anything, skip to Step 3. Otherwise, drain the merges:

1. If `git status` shows unmerged files (UU/AA), the orchestrator's
   last merge attempt left a conflict. Resolve each file using
   `git diff`, the spec, and `git log <parent>..HEAD` to understand
   each side's intent. `git add` resolved files, then `git commit`
   (default merge commit message is fine).

2. Re-run the helper to drain remaining parents:

       source "$CLAUDE_PLUGIN_ROOT/lib/worktree.sh"
       worktree_merge_parents "$PWD" $(cat .sensible-ralph-pending-merges)

   Possible outcomes:
   - Returns 0 and the marker file is gone → all parents merged.
     Proceed to Step 3.
   - Returns 0 and the marker file is still present → the next parent
     conflicted; loop back to step 1.
   - Returns 1 → genuine merge failure (parent ref missing,
     unexpected git error). Treat as a red flag per Step 5: post a
     Linear comment, do NOT invoke `/prepare-for-review`.

Keep looping (resolve → re-invoke) until the marker file is gone.
Each conflict resolution is a separate commit and shows up in the
`/prepare-for-review` diff for reviewer awareness.
```

The existing Step 2 wording ("If the orchestrator pre-merged a parent
branch into this worktree…") is replaced by the above. The escape
hatch to red-flag in Step 5 is unchanged; we add the new red-flag
case (helper returns 1) by reference, not by extending Step 5's red
flag list (which already covers "merge conflicts can't be resolved
confidently").

## Documentation changes

### `skills/sr-spec/SKILL.md`

Add a paragraph in the prerequisites discussion area of "The Process"
section, near where prerequisites become `blocked-by` relations are
mentioned. Exact wording:

> **Multi-parent prerequisite caveat.** If this spec ends up with 2+
> `blocked-by` parents that won't have landed to
> `$SENSIBLE_RALPH_DEFAULT_BASE_BRANCH` before dispatch, the
> orchestrator will perform a multi-parent INTEGRATION merge of those
> parents into the worktree. We provide best-effort support — when
> parents conflict during integration, the dispatched session resolves
> the conflicts inline (see `docs/design/worktree-contract.md`
> "Pending parent merges"). But parent–parent conflicts are messy: a
> wrong resolution by the autonomous session can wedge the integration
> in subtle ways that only surface at review time. **Prefer to land
> prerequisites to trunk before filing the dependent issue.** If you
> can't avoid the pattern, weight the issue's complexity accordingly
> and expect more review-time iteration.

The paragraph is read by Claude during `/sr-spec` and surfaces the
caveat to the operator at the moment they declare `blocked-by`
parents. Surfacing is deterministic; the operator cannot miss it.

### `docs/design/worktree-contract.md`

Add a new section "Pending parent merges" after the existing "Base
SHA" section. Documents:

- The `.sensible-ralph-pending-merges` file: location, format
  (one ref per line, original parent order), lifecycle (helper-owned
  write/delete, never mutated by orchestrator or session).
- The conflict-leave-in-place semantics for both
  `worktree_create_with_integration` and `worktree_merge_parents`,
  including the `merge-base --is-ancestor` skip that makes the
  helpers idempotent.
- The session-side drain contract: agent resolves the in-progress
  conflict, commits, re-invokes `worktree_merge_parents`. Helper
  detects ancestors and skips them. Marker is deleted on clean
  drain.
- The orchestrator's stderr notice on dispatch when the marker file
  is present after helper return.
- A one-line cross-reference back to the `sr-spec` warning:
  "Design-time, we recommend against multi-parent integrations
  (see `skills/sr-spec/SKILL.md`); this section describes the
  best-effort fallback when they occur."

Update the section list at the top of the doc to include the new
"Pending parent merges" entry between "Base SHA" and the next
section.

## Test plan (`lib/test/worktree.bats`)

Existing single-parent tests are not modified. AC#5 ("existing
single-parent merge behavior and bats coverage unchanged") is
honored.

### Flipped tests (assertions invert; setup unchanged)

1. `worktree_create_with_integration multi-parent conflict fails fast (does not silently drop later parents)` (currently around line 308) → rename to
   `worktree_create_with_integration multi-parent conflict leaves conflicts in worktree, writes pending-merges marker`. New assertions:
   - `[ "$status" -eq 0 ]` (was `-ne 0`).
   - `[ -f "$wt_path/.sensible-ralph-pending-merges" ]`.
   - Marker content equals the original 2-parent list, in order.
   - `git -C "$wt_path" diff --name-only --diff-filter=U` is non-empty.

2. `worktree_merge_parents: multi-parent conflict aborts, returns non-zero, second parent NOT merged` (currently around line 524) → rename to
   `worktree_merge_parents multi-parent conflict leaves conflicts in worktree, writes pending-merges marker`. Same assertion shape as (1) for the existing-worktree case.

### New tests (both helpers)

3. `worktree_create_with_integration: marker not written on clean multi-parent merge`. Two non-conflicting parents A, B. After helper returns 0, assert marker file does NOT exist.

4. `worktree_merge_parents: marker not written on clean multi-parent merge`. Same setup pattern as (3) but on an existing worktree.

5. `worktree_create_with_integration: idempotent re-run after manual conflict resolution`. Trigger the multi-parent conflict from test 1's setup. Manually `git add` + `git commit` to resolve. Re-invoke the helper with the same parent list. Assert: status 0, marker file gone, all parent content present, no errors. Confirms ancestor-skip works.

6. `worktree_merge_parents: idempotent re-run after manual conflict resolution`. Same shape as (5) for the existing-worktree case.

7. `worktree_create_with_integration: marker preserved when re-run hits another conflict`. Three parents A, B, C where A is clean, B conflicts, and C also conflicts after B is resolved (e.g., C and B both touch the same file with incompatible content). Run helper → marker has [A, B, C]. Resolve B's conflict, commit. Re-run helper → C conflicts, marker still present with [A, B, C], status 0. Confirms re-runs also write the marker correctly.

8. `worktree_merge_parents: marker preserved when re-run hits another conflict`. Same shape as (7) for the existing-worktree case.

Total deltas: 2 flipped, 6 added (3 each across both helpers). Existing
single-parent tests are not modified.

### Tests deliberately not added

- No bats coverage for the orchestrator's stderr notice line. There is
  no existing harness for `_dispatch_issue` integration tests; adding
  one for a single log line is disproportionate.
- No bats coverage for `/sr-implement` Step 2's drain loop. It is a
  skill-doc instruction, not a script. Bats covers the helper
  contract; the loop's correctness follows from helper idempotence.

## Acceptance criteria

1. `lib/worktree.sh::worktree_create_with_integration` no longer exits
   non-zero on merge conflict for any `parent_count`. It exits 0 with
   conflict markers in the worktree and `.sensible-ralph-pending-merges`
   present, listing the full original parent list in order.
2. `lib/worktree.sh::worktree_merge_parents` matches (1) on the same
   axes for the existing-worktree case.
3. The orchestrator's `_dispatch_issue` checks for the marker file
   after both helper call sites. If present, it logs the stderr notice
   described in the "Orchestrator changes" section and proceeds with
   `base_sha` capture and dispatch (it does NOT record `setup_failed`
   for the marker case).
4. The dispatched session's `/sr-implement` Step 2 includes the
   drain-loop instructions described in the "Session-side drain"
   section: detect marker → resolve in-progress conflict → commit →
   re-invoke `worktree_merge_parents` → loop until marker is gone.
5. `lib/test/worktree.bats` covers, for both helpers: (a) clean
   multi-parent merge exits 0 with no marker file, (b) conflicting
   multi-parent merge exits 0 with conflict markers and a marker file
   listing the full original parent list, (c) re-running the helper
   after manual conflict resolution drains remaining parents
   idempotently, (d) re-runs that hit another conflict re-write the
   marker correctly.
6. Existing single-parent merge behavior and existing single-parent
   bats coverage are unchanged.
7. `skills/sr-spec/SKILL.md` includes the multi-parent prerequisite
   caveat paragraph in its prerequisites discussion area.
8. `docs/design/worktree-contract.md` includes a new "Pending parent
   merges" section documenting the marker-file contract, the helper
   semantics, the session-side drain contract, and the orchestrator
   stderr notice.

## Out of scope

- No `progress.json` schema change. The dispatched-with-pending-merges
  state is a transient runtime condition, not a persistent record.
- No `autonomous-preamble.md` change. The conflict-resolution
  instructions live in `/sr-implement` Step 2; the preamble doesn't
  need to know.
- No new plugin option (`userConfig`) entries.
- No backward-compatibility shim. The marker file is new; nothing
  reads it before this change.
- No changes to `worktree_create_at_base` (the trunk-base or
  single-parent-create path that doesn't merge anything).
- No changes to ralph-failed cleanup paths. Genuine merge errors
  (helper returns 1) continue to flow through `_record_setup_failure`
  exactly as today.
- No README.md or docs/usage.md updates. The mechanism detail belongs
  in `docs/design/worktree-contract.md`; the operator-facing nudge
  belongs in `skills/sr-spec/SKILL.md`. README and usage.md describe
  the project's pillars and operator flow at a level that does not
  reach into integration internals.
