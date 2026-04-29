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
listing the **full original parent list, pinned to commit SHAs** to
`<worktree>/.sensible-ralph-pending-merges`. The dispatched session
detects the marker, finishes any in-progress merge (resolve conflicts
or complete a partially-staged merge), then re-invokes
`worktree_merge_parents` with the marker's contents. The helper is
idempotent — it skips parents that are already ancestors of HEAD
(already merged) and attempts only the remaining ones — so re-runs
drain the queue. The marker is deleted by the helper once all parents
are ancestors of HEAD or the helper is invoked with a zero-parent
list (cleanup-only invocation).

This matches the single-parent contract on the conflict-leaves-in-place
axis. The marker file generalizes it across `parent_count`. SHA pinning
ensures retries merge the same commits as the original attempt, so the
agent's resolution work and `base_sha`'s "before the agent contributed"
boundary remain stable even if parent branches advance during the
retry window.

## Data contract: `.sensible-ralph-pending-merges`

- **Path:** `<worktree>/.sensible-ralph-pending-merges` (peer of
  `.sensible-ralph-base-sha` and the dispatch log file).
- **Format:** plain text, one entry per line, in the order originally
  requested. Each entry is a 40-char hex commit SHA, optionally
  followed by a single space and a display ref name for log
  readability (e.g. `abc123…def origin/eng-200-foo`). The session-side
  drain reads only the SHA (first whitespace-separated token); the
  display ref is informational.
- **Lifecycle:**
  - Written by the helper on conflict — overwriting any prior marker.
  - Deleted by the helper unconditionally on every successful run
    that exits the merge loop without a conflict — including
    zero-parent invocations (cleanup-only) and runs where every
    parent is already an ancestor (no-op completion). The helper
    does not assume a marker existed at start; `rm -f` is safe in
    all cases.
  - Never mutated by the orchestrator or the dispatched session
    directly.
- **Content invariant:** the marker always lists the **full original
  list** the caller passed in (each pinned to the SHA the helper
  resolved on its first call), not the remaining-after-conflict list.
  Idempotent re-runs depend on `merge-base --is-ancestor` to skip
  already-merged parents; they do not depend on marker mutation.
- **Pinning rationale:** SHAs guard against parent-branch advancement
  between marker write and rerun (re-fetch, force-push, branch reset
  on origin). Without pinning, a retry could merge different commits
  than the original attempt, breaking idempotence and contaminating
  the `/prepare-for-review` diff with parent updates the agent never
  consciously integrated.

## Helper changes (`lib/worktree.sh`)

Both `worktree_create_with_integration` and `worktree_merge_parents`
get the same shape of change. The merge loop becomes:

```
1. Resolve and pin parent args to (sha, display) tuples. Each input
   may be a ref name OR a 40-char hex SHA:

   for arg in args:
     if arg matches ^[0-9a-f]{40}$ AND `git -C "$path" cat-file -e arg^{commit}`:
       sha = arg
       display = arg
     elif `git -C "$path" show-ref --verify --quiet "refs/heads/$arg"`:
       sha = `git -C "$path" rev-parse "$arg"`
       display = arg
     elif `git -C "$path" show-ref --verify --quiet "refs/remotes/origin/$arg"`:
       sha = `git -C "$path" rev-parse "origin/$arg"`
       display = "origin/$arg"
     else:
       printf 'helper: parent ref not found: %s\n' "$arg" >&2
       return 1
     resolved_shas+=($sha)
     display_refs+=($display)

   The accept-SHA branch is what makes the helper safely re-invokable
   from the session with marker contents (which are SHAs).

2. For each (sha, display) tuple in order:
   a. If `git -C "$path" merge-base --is-ancestor sha HEAD` → continue.
      (Required on both helpers. worktree_merge_parents already has
       this skip; worktree_create_with_integration must add it.)
   b. Run `git -C "$path" merge sha --no-edit`. On success → continue.
   c. On non-zero exit, check `git -C "$path" diff --name-only --diff-filter=U`:
      - If unmerged files exist → conflict path:
        - Write the marker file with `<sha> <display>` per line, in
          original order, for ALL inputs (including ones already
          skipped via ancestor-check this run — the marker captures
          the caller's complete request).
        - Return 0. Worktree is left in MERGING state.
      - If no unmerged files → genuine merge error path:
        - Print existing error message to stderr.
        - Return 1.

3. After the loop exits without conflict (all parents merged or
   skipped, OR zero-parent input):
   - `rm -f <worktree>/.sensible-ralph-pending-merges` unconditionally.
     Safe whether the marker exists or not.
   - Return 0.
```

The asymmetric `if [[ "$parent_count" -eq 1 ]]; then return 0; fi`
block is **removed entirely** from both helpers. The single-parent
case falls through into the same conflict path as multi-parent: marker
written (with the single SHA), return 0. Functionally equivalent to
today's single-parent behavior, plus a marker file the session can
read.

The zero-parent fast path in `worktree_merge_parents`
(`if [ "$parent_count" -eq 0 ]; then return 0; fi`, currently around
line 117) is **removed**. With it gone, the for-loop iterates zero
times when called with no parents, falls through to the post-loop
cleanup, and `rm -f`s any orphaned marker. This guarantees that an
orchestrator dispatch with empty `merge_parents` cleans up after a
prior run's stale marker — closing the orphaned-marker hole that
otherwise survives across dispatches.

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

The marker file is the authority for entering recovery. Two checks
gate the flow:

    [ -f .sensible-ralph-pending-merges ] && echo MARKER
    git rev-parse -q --verify MERGE_HEAD && echo MERGING

Three cases:

- **Marker absent, MERGE_HEAD absent:** no drain work. Skip to Step 3.

- **Marker absent, MERGE_HEAD present:** the worktree is mid-merge
  but the state was NOT created by this feature (the helper would
  have written a marker alongside the merge). Do NOT auto-commit —
  this is unowned state. Treat as a red flag per Step 5: post a
  Linear comment ("worktree is mid-merge but `.sensible-ralph-pending-merges`
  is absent; this state was not produced by the orchestrator's
  parent-merge helpers and cannot be safely auto-resolved"), exit
  clean. Do NOT invoke `/prepare-for-review`.

- **Marker present:** enter the drain loop. Marker presence proves
  the merge state belongs to this feature. Run the loop below until
  the marker is gone.

### Drain loop

1. **Resolve unmerged files (if any).** If `git status` shows
   unmerged files (UU/AA), resolve each using `git diff`, the spec,
   and `git log <parent>..HEAD` to understand each side's intent.
   `git add` resolved files (do NOT commit yet — fall through to
   step 2).

2. **Finish any in-progress merge.** Check whether the worktree is
   in MERGING state:

       git rev-parse -q --verify MERGE_HEAD

   If this prints a SHA (exit 0), a merge is in progress and must
   be committed before the helper can run again. Run:

       git commit --no-edit

   This handles three crash-recovery cases:
   - Conflicts just resolved in step 1 → commit them now.
   - Conflicts resolved + staged in a prior session attempt but
     the session crashed before committing → MERGE_HEAD still
     exists, no UU/AA files; this commit completes the merge.
   - Resolution committed already → MERGE_HEAD does not exist;
     the `git rev-parse` returns non-zero, no commit needed.

   Skipping this step and going straight to the helper would
   invoke `git merge` on a worktree with MERGE_HEAD set, producing
   "fatal: You have not concluded your merge" → helper returns 1
   → spurious red flag.

3. **Re-invoke the helper to drain remaining parents.** Pass the
   marker contents as args; the helper accepts SHAs uniformly with
   ref names:

       source "$CLAUDE_PLUGIN_ROOT/lib/worktree.sh"
       worktree_merge_parents "$PWD" $(awk '{print $1}' .sensible-ralph-pending-merges)

   The `awk '{print $1}'` extracts SHAs from the first column of the
   marker (display refs in column 2 are informational only).

   Possible outcomes:
   - Returns 0 and the marker file is gone → all parents merged.
     Proceed to Step 3.
   - Returns 0 and the marker file is still present → the next
     parent conflicted; loop back to step 1.
   - Returns 1 → genuine merge failure (parent SHA unreachable in
     repo, unexpected git error). Treat as a red flag per Step 5:
     post a Linear comment, do NOT invoke `/prepare-for-review`.

Keep looping (resolve → finish-merge → re-invoke) until the marker
file is gone. Each conflict resolution is a separate commit and shows
up in the `/prepare-for-review` diff for reviewer awareness.
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
  (one entry per line: 40-char hex SHA optionally followed by a
  display ref name; first whitespace-separated token is the SHA),
  original parent order, lifecycle (helper-owned write/delete,
  never mutated by orchestrator or session, cleaned up on every
  successful run including zero-parent invocations).
- The SHA-pinning rationale: protects retries against parent-branch
  advancement so the agent's resolution work and `base_sha`'s
  "before the agent contributed" boundary remain stable.
- The conflict-leave-in-place semantics for both
  `worktree_create_with_integration` and `worktree_merge_parents`,
  including the `merge-base --is-ancestor` skip that makes the
  helpers idempotent and the unified ref-or-SHA acceptance in the
  resolution loop.
- The session-side drain contract: agent resolves any unmerged
  files, then completes any in-progress merge (`git rev-parse -q
  --verify MERGE_HEAD` → `git commit --no-edit`) BEFORE re-invoking
  `worktree_merge_parents` with the marker's SHAs. Helper detects
  ancestors and skips them. Marker is deleted on clean drain.
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
   - Marker content has 2 lines, each starting with a 40-char hex SHA;
     SHAs match `git -C "$wt_path" rev-parse <ref>` for the two
     parent refs at the time of the call, in original order.
   - `git -C "$wt_path" diff --name-only --diff-filter=U` is non-empty.

2. `worktree_merge_parents: multi-parent conflict aborts, returns non-zero, second parent NOT merged` (currently around line 524) → rename to
   `worktree_merge_parents multi-parent conflict leaves conflicts in worktree, writes pending-merges marker`. Same assertion shape as (1) for the existing-worktree case.

### New tests (both helpers)

3. `worktree_create_with_integration: marker not written on clean multi-parent merge`. Two non-conflicting parents A, B. After helper returns 0, assert marker file does NOT exist.

4. `worktree_merge_parents: marker not written on clean multi-parent merge`. Same setup pattern as (3) but on an existing worktree.

5. `worktree_create_with_integration: idempotent re-run after manual conflict resolution`. Trigger the multi-parent conflict from test 1's setup. Manually `git add` + `git commit` to resolve. Re-invoke the helper, passing the SHAs from the marker file (as the session would). Assert: status 0, marker file gone, all parent content present, no errors. Confirms ancestor-skip and SHA-arg acceptance both work.

6. `worktree_merge_parents: idempotent re-run after manual conflict resolution`. Same shape as (5) for the existing-worktree case.

7. `worktree_create_with_integration: marker preserved when re-run hits another conflict`. Three parents A, B, C where A is clean, B conflicts, and C also conflicts after B is resolved (e.g., C and B both touch the same file with incompatible content). Run helper → marker has 3 SHA lines for [A, B, C]. Resolve B's conflict, commit. Re-run helper with marker SHAs → C conflicts, marker still present with the same 3 SHAs, status 0. Confirms re-runs also write the marker correctly.

8. `worktree_merge_parents: marker preserved when re-run hits another conflict`. Same shape as (7) for the existing-worktree case.

### New tests for crash-recovery and pinning

9. `worktree_merge_parents: zero-parent invocation cleans up stale marker`. Setup: write a fake marker file at `<wt>/.sensible-ralph-pending-merges` with arbitrary SHA content. Invoke `worktree_merge_parents "$wt_path"` (no parent args). Assert: status 0, marker file gone. Verifies the orphaned-marker hole is closed.

10a. `worktree_create_with_integration: SHA-pinned retry merges the original commit even after the named ref advances`. Setup: two parent refs A0 and B at distinct SHAs; A0 conflicts with main on a file. Run helper with [A0, B] → marker has 2 SHA lines, conflict in tree. Advance the local A0 ref to a new SHA A1 (`git commit --amend` or `--reset` on A0's branch tip). Manually resolve A0's conflict + commit. Re-invoke the helper with the marker's SHAs (which are A0's *original* SHA, plus B). Assert: status 0, marker gone, merged content matches A0's *original* SHA, NOT A1. Confirms SHA pinning prevents drift on the create path.

10b. `worktree_merge_parents: SHA-pinned retry merges the original commit even after the named ref advances`. Same shape as (10a) for the existing-worktree case. Required because the helpers have duplicated bodies — covering one does not cover the other.

11a. `worktree_create_with_integration: helper accepts a 40-char hex SHA as a parent arg`. Setup: a parent ref pointing at SHA X. Invoke helper with the SHA X directly (no ref name). Assert: status 0, parent content present, no errors. Confirms the SHA-arg branch in the create-path resolution loop.

11b. `worktree_merge_parents: helper accepts a 40-char hex SHA as a parent arg`. Same shape as (11a) for the existing-worktree case. Required because the helpers have duplicated bodies.

Total deltas: 2 flipped, 11 added. Existing single-parent tests are
not modified. Tests 10a/10b and 11a/11b are duplicated across helpers
because `lib/worktree.sh` keeps the resolution and merge-loop
implementations separate (not factored into a shared subroutine);
covering both helpers prevents the create path from drifting from
the merge-parents path under future refactors.

### Tests deliberately not added

- No bats coverage for the orchestrator's stderr notice line. There is
  no existing harness for `_dispatch_issue` integration tests; adding
  one for a single log line is disproportionate.
- No bats coverage for `/sr-implement` Step 2's drain loop. It is a
  skill-doc instruction, not a script. Bats covers the helper
  contract; the loop's correctness follows from helper idempotence
  plus the documented MERGE_HEAD-detection step.
- No bats coverage for the MERGING-state restart guard. It is a
  session-side detection step (`git rev-parse -q --verify MERGE_HEAD`);
  the helper's behavior when called WITH MERGE_HEAD set is implicitly
  covered by test 11's documented contract that the session must
  finish the merge first.
- No bats coverage for the unowned-state red flag (marker absent +
  MERGE_HEAD present). This is a session-side hard stop documented
  in `/sr-implement` Step 2; the helper itself never enters this
  path because the helper is the only writer of the marker.

## Acceptance criteria

1. `lib/worktree.sh::worktree_create_with_integration` no longer exits
   non-zero on merge conflict for any `parent_count`. It exits 0 with
   conflict markers in the worktree and `.sensible-ralph-pending-merges`
   present, listing the full original parent list pinned to commit
   SHAs (one per line, original order).
2. `lib/worktree.sh::worktree_merge_parents` matches (1) on the same
   axes for the existing-worktree case. Additionally, its zero-parent
   fast path is removed: a zero-parent invocation falls through to
   the post-loop cleanup, removing any orphaned marker.
3. Both helpers' resolution loops accept either an unprefixed ref
   name (resolved internally to `refs/heads/<arg>` first, then
   falling back to `refs/remotes/origin/<arg>`) or a 40-char hex
   SHA, validated via `git cat-file -e <sha>^{commit}`. The helper
   does NOT accept already-prefixed forms like `origin/<branch>`
   as input; matching the existing pre-change contract. Marker
   writes use the resolved SHAs; subsequent reinvocations passing
   those SHAs back merge the same commits even if the original ref
   names have advanced. The marker's optional column-2 display ref
   may include a resolved-form prefix (`origin/<branch>`) for
   logging readability — it is informational only and never fed
   back to the helper.
4. The orchestrator's `_dispatch_issue` checks for the marker file
   after both helper call sites. If present, it logs the stderr
   notice described in the "Orchestrator changes" section and
   proceeds with `base_sha` capture and dispatch (it does NOT
   record `setup_failed` for the marker case).
5. The dispatched session's `/sr-implement` Step 2 implements the
   recovery flow described in the "Session-side drain" section:
   marker presence is the sole authority for entering the drain
   loop. If the marker is absent and MERGE_HEAD is set, the session
   red-flags (post Linear comment, exit clean — do not invoke
   `/prepare-for-review`). If the marker is present, the drain loop
   runs: resolve unmerged files → finish any in-progress merge
   via `git rev-parse -q --verify MERGE_HEAD` + `git commit --no-edit`
   → re-invoke `worktree_merge_parents` with marker SHAs → loop
   until marker is gone.

5b. The plugin repo's `.gitignore` includes a new line
    `/.sensible-ralph-pending-merges` alongside the existing
    `/.sensible-ralph-base-sha` entry, so the marker file (when
    present in the dogfood case where the plugin repo IS the
    consumer) does not show up as untracked content in
    `git status`.
6. `lib/test/worktree.bats` covers, for both helpers (except where
   noted): (a) clean multi-parent merge exits 0 with no marker file,
   (b) conflicting multi-parent merge exits 0 with conflict markers
   and a marker file listing the full original parent list pinned to
   SHAs, (c) re-running the helper after manual conflict resolution
   drains remaining parents idempotently, (d) re-runs that hit
   another conflict re-write the marker correctly, (e)
   `worktree_merge_parents` zero-parent invocation cleans up a
   stale marker, (f) SHA-pinned retry merges the original commit
   even after the named ref advances, (g) the helper accepts a
   40-char hex SHA as a parent arg.
7. Existing single-parent merge behavior and existing single-parent
   bats coverage are unchanged.
8. `skills/sr-spec/SKILL.md` includes the multi-parent prerequisite
   caveat paragraph in its prerequisites discussion area.
9. `docs/design/worktree-contract.md` includes a new "Pending parent
   merges" section documenting the marker-file contract (including
   SHA pinning), the helper semantics (including unified
   ref-or-SHA acceptance and zero-parent cleanup), the session-side
   drain contract (including MERGE_HEAD detection), and the
   orchestrator stderr notice.

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
