# Worktree contract

The cross-skill contract for how sensible-ralph creates, owns, hands off,
and tears down the linked git worktree backing each Linear issue. Each
issue gets exactly one branch+worktree, created lazily at `/sr-spec` step
7 and torn down at `/close-issue` after merge. `/sr-spec` runs the codex
spec gate and writes the spec on that branch; the orchestrator dispatches
into the same worktree; `/sr-implement` and `/prepare-for-review` run
inside it; `/close-issue` is the sole remover. All five actors must agree
on naming, CWD, the base-SHA file, the output log, and removal
preconditions.

## Naming

Worktree path:

```
<repo-root>/<worktree_base>/<branch>
```

- **`<repo-root>`** is resolved via `_resolve_repo_root` (in
  `lib/worktree.sh`), which calls
  `git rev-parse --path-format=absolute --git-common-dir` and returns the
  parent of the shared `.git`. The path is absolute and stable regardless
  of the caller's CWD (main checkout, linked worktree, subdirectory of
  either) — multi-worktree invocations all resolve to the same root.
- **`<worktree_base>`** is the plugin `userConfig` option `worktree_base`,
  exported by the Claude Code harness as
  `$CLAUDE_PLUGIN_OPTION_WORKTREE_BASE`. Default `.worktrees`. Leading
  and trailing slashes are stripped by `worktree_path_for_issue` before
  the path is composed, so `.worktrees`, `/.worktrees`, and `.worktrees/`
  all yield the same final path.
- **`<branch>`** is Linear's auto-generated `<team-lowercase>-<id>-<slug>`
  (e.g. `eng-296-write-docsdesignworktree-contractmd`), fetched via
  `linear_get_issue_branch` (which reads `.branchName` from
  `linear issue view --json`). The orchestrator treats a literal `"null"`
  return as a missing branch name and records `setup_failed` rather than
  creating a branch named "null".

The path is computed by `worktree_path_for_issue "$branch"` at creation
time. The orchestrator calls it to determine where to run `git worktree
add`; `/close-issue` finds the already-created path via
`git worktree list --porcelain` rather than recomputing it; and
`/prepare-for-review` uses its existing CWD. The naming convention has
one authoritative computation, but different actors discover the path
differently depending on whether they're creating or consuming it.

## Creation

`/sr-spec` step 7 is the **primary creator**: lazily, after the operator
approves the design, it calls `worktree_create_at_base` off the default
base branch and `cd`s in. The spec doc is committed on the branch — not
on main — and persists through the rest of the lifecycle.

`orchestrator.sh` is the **fallback creator**: when `/sr-start`
encounters an Approved issue whose branch+worktree don't already exist
(manual issues filed without `/sr-spec`, or legacy pre-ENG-279 state),
it creates them at the DAG-chosen base. The reuse path — branch+worktree
already exist, `/sr-spec` made them — is the common path under ENG-279;
the create path is the fallback. See "Orchestrator reuse path" in
`docs/design/orchestrator.md` for the dispatch-time branching.

Both creators dispatch via `git worktree add`:

```bash
git worktree add "$path" -b "$branch" "$resolved_base"
```

Two helpers in `lib/worktree.sh` wrap this:

- **`worktree_create_at_base $path $branch $base`** — single-base case
  (default base branch, or a single in-review parent's branch).
- **`worktree_create_with_integration $path $branch $parents...`** —
  multi-parent integration case (always 2+ parents — `dag_base.sh`
  emits `INTEGRATION` only when multiple blockers are In Review). Creates
  the worktree at `$SENSIBLE_RALPH_DEFAULT_BASE_BRANCH`, then
  sequentially merges each parent. On conflict, leaves the worktree in
  MERGING state and writes the `.sensible-ralph-pending-merges` marker;
  the dispatched session drains the marker per "Pending parent merges"
  below. See `docs/archive/decisions/ralph-v2-multi-parent-integration-abort.md`
  for the prior fail-fast contract that this approach replaces.

A third helper in `lib/worktree.sh` is used by the orchestrator's reuse
path:

- **`worktree_merge_parents $path $parents...`** — merges a parent list
  into an *already-existing* worktree, in order. Mirrors
  `worktree_create_with_integration`'s conflict semantics: on any
  conflict (single or multi parent), leaves conflicts in place,
  writes the `.sensible-ralph-pending-merges` marker, returns 0. The
  dispatched session drains the marker per "Pending parent merges"
  below. Skips parents that are already ancestors of HEAD (no-op
  merge), which is what makes the helper safely re-invokable from the
  session's drain loop.

**Ref resolution for parent branches** (both helpers): each parent is
resolved against `refs/heads/$parent` first, then
`refs/remotes/origin/$parent` — fresh clones often have review branches
present only via `git fetch` without local heads.

**Ref resolution for the trunk**: `worktree_create_with_integration`
passes `$SENSIBLE_RALPH_DEFAULT_BASE_BRANCH` verbatim to `git worktree add`
with no local/remote fallback. If the trunk exists only as a remote
tracking ref (e.g., `origin/main` without a local `main`), the command
will fail. `worktree_create_at_base` has the fallback because its `$base`
argument can be any ref; the integration helper's trunk is a config-driven
constant expected to be a local branch in any ralph-hosting repo.

The base itself is one of three shapes, chosen by `dag_base.sh`:

| Blockers state | Base passed to creation |
|---|---|
| No blockers, or all blockers `Done` | `$SENSIBLE_RALPH_DEFAULT_BASE_BRANCH` (default `main`) |
| One blocker `In Review`, rest `Done` | That blocker's branch name — worktree branches directly from the parent |
| Multiple blockers `In Review` | `INTEGRATION <parent1> <parent2> ...` (triggers the integration helper) |

**Approved-blocker chains**: the table reads blocker state at B's
dispatch time, not queue-build time. An Approved blocker dispatched
earlier in the same run (rule 3b of the pickup rule) will have
transitioned to `In Review` by the time B dispatches — toposort
guarantees parents dispatch first and each parent session runs
`/prepare-for-review` before exiting. No separate Approved-blocker
row is needed.

**Why not `claude --worktree`.** The orchestrator does not use the
`--worktree` flag on `claude`. That flag is a *create* path that branches
off `HEAD` into `<repo>/.claude/worktrees/<name>/` — it can't accept a
pre-created path and has no DAG or integration-merge awareness, so it
cannot satisfy the base-selection table above. The orchestrator
pre-creates the worktree at the correct base, then dispatches `claude -p`
with the worktree as its CWD via subshell `cd`.

## `.sensible-ralph-base-sha`

A single-line file at `<worktree>/.sensible-ralph-base-sha` containing
the SHA the implementation diff is scoped against. The file is the
cross-skill contract that lets `/prepare-for-review` see *this session's
implementation commits* — not the spec commits that landed at `/sr-spec`
step 7, not parent-branch commits absorbed via integration merges, and
not the main checkout's HEAD.

| Actor | Role |
|---|---|
| `/sr-spec` step 7 | **Does not write the file.** Captures `SPEC_BASE_SHA` in shell only, used by step 10's codex gate (`--base "$SPEC_BASE_SHA"`) to scope adversarial review to this session's spec commits. |
| `orchestrator.sh` (reuse path) | **Writes** the file post-merge: `.sensible-ralph-base-sha = $(git -C "$path" rev-parse HEAD)` AFTER merging in-review parents. In a clean merge HEAD is the merge commit; spec commits + parent commits are now ancestors of base-sha and excluded from the impl diff. In a single-parent conflict (leave-for-agent) HEAD has not advanced — base-sha = spec HEAD, and the agent's resolution commit is intentionally in scope for review. |
| `orchestrator.sh` (create path) | **Writes** the file post-create: HEAD of the just-created worktree (post-merge in INTEGRATION mode). |
| `/sr-implement` | **Does not read.** The file is opaque to the implementer — implementation work needs only the worktree CWD and the PRD. |
| `/prepare-for-review` | **Reads** the file to compute `BASE_SHA`, used to scope (a) `update-stale-docs` (`--base $BASE_SHA`), (b) `codex-review-gate` (`--base $BASE_SHA`), and (c) the `git log --oneline $BASE_SHA..HEAD` block in the Linear handoff comment. |
| `/close-issue` | Does not read directly. The base-SHA's role ends after `/prepare-for-review` completes. |

The post-merge timing is uniform across reuse and create paths and across
single/parent/INTEGRATION shapes — every path writes
`git rev-parse HEAD` after worktree creation/merge completes. This fixes
a latent INTEGRATION-mode bug (pre-ENG-279) where the file pointed at
trunk pre-merge, leaking parent commits into the prepare-for-review
diff.

**Fallback.** When `/prepare-for-review` runs interactively (no
orchestrator dispatch, no `.sensible-ralph-base-sha`), it computes
`BASE_SHA` via `git merge-base HEAD <trunk>`, where `<trunk>` is detected
in this order: `origin/HEAD` symbolic-ref → `refs/heads/main` →
`refs/heads/master` → `origin/main` → `origin/master`. On a stacked
branch (branched from a feature branch, not the trunk), the user must
override `BASE_SHA` explicitly — the merge-base fallback is
trunk-relative and would over-include parent-branch commits.

The file is gitignored as `/.sensible-ralph-base-sha` (see "Required
.gitignore entries" below) so it does not get committed into the
session's first feature commit.

## Pending parent merges

Design-time, we recommend against multi-parent integrations (see
`skills/sr-spec/SKILL.md`); this section describes the best-effort
fallback when they occur.

When `worktree_create_with_integration` or `worktree_merge_parents`
hits a merge conflict on any parent, it leaves the conflict in place
(MERGING state, conflict markers in the worktree) and writes a marker
file to coordinate the session-side drain. Both helpers share the
same shape — single and multi parent.

**File path.** `<worktree>/.sensible-ralph-pending-merges` — peer of
`.sensible-ralph-base-sha` and the dispatch log file.

**Format.** Plain text, one entry per line, in the order originally
requested. Each entry is a 40-char hex commit SHA, optionally
followed by a single space and a display ref name for log readability
(e.g. `abc123…def origin/eng-200-foo`). The session-side drain reads
only the SHA (first whitespace-separated token); the display ref is
informational.

**Lifecycle.**

- Written by the helper on conflict — overwriting any prior marker.
- Deleted by the helper at the end of a successful merge loop (every
  parent merged or skipped via ancestor check). `rm -f` is safe whether
  the marker existed at start or not.
- Zero-parent invocations are NOT a generic cleanup mechanism:
  marker-absent zero-parent runs are a no-op success; marker-present
  zero-parent runs refuse (return 1) and preserve the marker, so a
  stale marker from a prior failed dispatch surfaces as orchestrator
  `setup_failed` rather than being silently obliterated.
- Never mutated by the orchestrator or the dispatched session
  directly.

**Content invariant.** The marker always lists the **full original
parent list** the caller passed in (each pinned to the SHA the helper
resolved on its first call), not the remaining-after-conflict list.
Idempotent re-runs depend on `merge-base --is-ancestor` to skip
already-merged parents; they do not depend on marker mutation.

**SHA pinning.** SHAs guard against parent-branch advancement between
marker write and rerun (re-fetch, force-push, branch reset on origin).
Without pinning, a retry could merge different commits than the
original attempt, breaking idempotence and contaminating the
`/prepare-for-review` diff with parent updates the agent never
consciously integrated.

**Helper contract.** Both `worktree_create_with_integration` and
`worktree_merge_parents` share these properties:

- Each parent arg may be a ref name (resolved against `refs/heads/`
  then `refs/remotes/origin/`) or a 40-char hex SHA validated via
  `git cat-file -e <sha>^{commit}`. The marker stores SHAs so re-runs
  with marker contents merge the same commits even if the named refs
  have advanced. The helper does NOT accept already-prefixed forms
  like `origin/<branch>` as input — pre-change contract preserved.
- The merge loop skips parents that are already ancestors of HEAD
  (`merge-base --is-ancestor`). This is what makes the helpers
  re-invokable post-conflict — the session can pass the full marker
  contents back and parents already merged earlier in the loop are
  no-ops.
- On conflict (any `parent_count`), helper leaves the worktree in
  MERGING state, writes the marker with the full original list, and
  returns 0. On a non-conflict merge error (e.g., unrelated histories),
  helper returns 1. The marker write itself is **fail closed**: it
  uses an in-place tempfile + same-FS rename for atomicity, checks
  every I/O step, and refuses if the marker path is occupied by a
  non-file. Any marker-write failure propagates from the helper as
  non-zero — the orchestrator must never see a `return 0` over a
  worktree in MERGING state without a valid marker, since the
  session-side drain treats that combination as unowned state.

**Session-side drain.** The dispatched session's `/sr-implement` Step
2 implements the recovery flow. Before any branch mutation, it
validates the marker fail-closed: every line must match
`^[0-9a-f]{40}( .*)?$` (so blank or whitespace-only lines reject the
marker rather than being silently skipped during awk extraction), and
every SHA must be reachable via `git cat-file -e <sha>^{commit}`
(unreachable SHAs reject the marker before any merge). Only after
both checks pass on every line does the session enter the drain loop:
resolve any unmerged files, then complete any in-progress merge via
`git rev-parse -q --verify MERGE_HEAD` + `git commit --no-edit`
(BEFORE re-invoking the helper — `git merge` on a worktree with
MERGE_HEAD set fails with "fatal: You have not concluded your merge"),
then re-invoke `worktree_merge_parents` with the marker SHAs. The
helper detects ancestors and skips them. The marker is deleted on
clean drain; if another conflict happens, the marker is preserved
(unchanged) and the loop iterates.

**Orchestrator notice.** After both helper call sites, the
orchestrator checks for the marker file. If present, it logs to
stderr:

```
orchestrator: <issue_id> dispatched with pending parent merges (conflicts to resolve in-session): <space-separated parent list>
```

It does NOT record `setup_failed` for the marker case — the helper
returned 0 and the session is responsible for the drain. The
`setup_failed` branch is reserved for genuine merge errors (helper
return 1) and the marker-aware zero-parent guard.

**`base_sha` interaction.** When the helper returns 0 with the marker
present, the orchestrator's post-merge `base_sha` capture sees a
worktree HEAD that has not advanced past the conflict (no merge
commit yet for the conflicting parent). So `base_sha` = pre-conflict
HEAD; the agent's resolution commit and any subsequent parent merges
land **after** `base_sha`, appearing in the `/prepare-for-review`
diff for reviewer awareness. This matches today's single-parent
conflict behavior; the marker generalizes it across `parent_count`.

## Output log

Each dispatched session's `claude -p` output is tee'd to:

```
<worktree>/<stdout_log_filename>
```

`<stdout_log_filename>` is the plugin `userConfig` option
`stdout_log_filename`, exported as
`$CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME`. Default `ralph-output.log`.

`orchestrator.sh` writes via:

```bash
(cd "$path"
 set +e
 claude -p ... "$prompt" 2>&1 | tee "$path/$CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME"
 ec="${PIPESTATUS[0]}"
 exit "$ec")
```

The `${PIPESTATUS[0]}` capture is load-bearing: it preserves `claude`'s
exit code through `tee`, which the orchestrator then combines with the
post-dispatch Linear state to classify the outcome (a successful tee on
top of a failed claude must not collapse to "success").

The log is the operator entry point for debugging `failed` and
`exit_clean_no_review` outcomes. ENG-308: the orchestrator persists
the dispatch-time `worktree_log_path` into `progress.json`, and
`/sr-status` renders it as `transcript: <path>` in the diagnostic
sub-block under each non-success Done row, alongside the JSONL session
transcript pointer (`session: <path>`). For `setup_failed` outcomes,
the log does not exist (the dispatch block never ran); inspect the
`failed_step` field in `.sensible-ralph/progress.json` and the
orchestrator stderr instead.

## CWD convention

Four actors, four rules. The differences are not stylistic — each
encodes a real failure-mode constraint.

| Actor | CWD | Why |
|---|---|---|
| `/sr-spec` (steps 1-6) | Operator's existing CWD (no branch yet) | The dialogue runs before lazy step-7 creation. Operator may be anywhere inside the repo. |
| `/sr-spec` (steps 7-11) | Inside the worktree (CWD = `$WORKTREE_PATH`) | Step 7 `cd`s in after creating (or detecting) the branch+worktree. The spec commit, codex gate (`--base "$SPEC_BASE_SHA"`), and finalize all run with the worktree as CWD so git operations are scoped to the issue's branch. |
| `orchestrator.sh` | Repo root (or any path that resolves to it via `_resolve_repo_root`) | Dispatches each `claude -p` via `(cd "$path" && claude -p ...)` in a subshell, so the orchestrator's own CWD is never disturbed. Worktree-side ops use the captured `$path` (e.g. `git -C "$path" merge ...` for the reuse path's parent merges). |
| `/sr-implement`, `/prepare-for-review` | Inside the worktree (CWD = `$path`) | The orchestrator enters via subshell `cd` before invoking `claude -p`. All implementation and prepare-for-review git operations are scoped to the worktree's branch by being there. |
| `/close-issue` | Main checkout (NOT a linked worktree); `.git` must be a directory, not a file | Worktree-side operations use `git -C "$WORKTREE_PATH" ...`. Running close-issue from inside the worktree being closed used to be the norm, but it pinned the Bash tool's session CWD to a directory that the skill's final step removes — any external cause (another process, stray `rm`, hook) that removed the directory mid-ritual killed the session instantly. The main-checkout CWD removes that failure class entirely; the skill enforces it via `[ -f "$MAIN_REPO/.git" ] && exit 1`. |

## Removal

`/close-issue` is the **normal remover** — it runs Step 9 after the
Linear `Done` transition (and after the Step 8 coord-dep cleanup) so
the high-value state mutations (merge, push, branch delete, Linear
Done) are already committed if removal fails. The
orchestrator's `_cleanup_worktree` helper is the **setup-failure remover**:
it rolls back worktrees this invocation *created* when a pre-dispatch
setup step fails, using `--force` because `.sensible-ralph-base-sha`
would otherwise block `git worktree remove`. These are distinct code
paths with different preconditions; both are documented in this section.

Crucially, the orchestrator's setup-failure cleanup runs **only on the
create path** — never on the reuse path. A reused branch+worktree predate
the orchestrator's invocation (created at `/sr-spec` step 7); tearing
them down on a transient setup failure would destroy the operator's
spec commit. The reuse path's setup-failure outcome is `setup_failed` on
the issue with no worktree teardown; the operator inspects, fixes, and
re-dispatches.

Pre-flight pre-conditions, both required:

1. **Untracked files preserved.** Pre-flight §3 runs
   `git -C "$WORKTREE_PATH" ls-files --others --exclude-standard`. If
   anything appears, the skill stops and asks the operator: commit them,
   copy them to a safe location, or explicitly discard. **Never silently
   discard** — `plan.md` files have been lost this way before, which is
   why this gate exists.
2. **All `blocked-by` parents `Done`.** Pre-flight §2 enforces the "no
   merging un-reviewed parent commits as a side effect of closing the
   child" invariant. (Not directly a worktree concern, but the same
   pre-flight that gates worktree removal.)

Removal sequence:

```bash
# 1. Reap the worktree's codex broker (if any), three-layer safety:
#    (a) --cwd canonicalizes to this worktree, (b) no live non-broker
#    process rooted in the worktree, (c) SIGTERM not SIGKILL.
#    The codex plugin's app-server-broker.mjs is scoped per-session and
#    leaks if the session crashed or was force-closed; git doesn't
#    notify the broker on worktree removal.
# 2. Remove the worktree itself:
git worktree remove "$WORKTREE_PATH"
```

**No `--force`.** If `git worktree remove` exits non-zero, the skill
prints the diagnostic and stops without retrying. `--force` has
destroyed work before; the failure is informational (uncommitted
changes that slipped past pre-flight, an editor holding files open,
a shell `cd`'d into the worktree), not an obstacle to blast through.

The orchestrator's internal `_cleanup_worktree` helper *does* use
`--force` — but only as a setup-failure rollback on the create path,
gated on the worktree having been created by the same invocation
that's now cleaning it up. That is a different code path; close-issue's
removal of a *human-reviewed* worktree never uses force.

### Cancellation cleanup

Under ENG-279's lazy step-7 creation, residue only exists if the
operator advances `/sr-spec` past step 7 (commits a spec doc to the
branch) and then abandons or cancels the issue. There is no automated
cleanup for this case — `/sr-cleanup` is a deferred follow-up. Manual
recipe (after the operator cancels the issue in Linear):

```bash
git worktree remove --force "<repo>/.worktrees/<branch>" 2>/dev/null
git branch -D "<branch>" 2>/dev/null
```

`/sr-spec`'s preflight (step 1) refuses to start a fresh dialogue on a
`Todo`/`Backlog`/`Triage` issue when residue is present, surfacing the
same recipe in its error message. The orchestrator's `local_residue`
outcome is the dispatch-time analogue.

## Required `.gitignore` entries

Each consumer repo (any repo where `/sr-start` runs) must gitignore the
following at its root. The plugin's own `.gitignore` ships them so the
canonical list is copy-pasteable:

```
/.sensible-ralph/
/.worktrees/
/.sensible-ralph-base-sha
/.sensible-ralph-pending-merges
ralph-output.log
/.close-branch-inputs
/.close-branch-result
/.sensible-ralph-coord-dep.json
```

| Entry | Why |
|---|---|
| `/.sensible-ralph/` | Orchestrator runtime state — `progress.json`, `ordered_queue.txt` (committed-run record with `# run_id:` header), `queue_pending.txt` (transient build artifact from `/sr-start`). Per-run, repo-root-only. |
| `/.worktrees/` | Default `worktree_base`. Linked worktrees should never appear in the parent repo's tracked tree. If `worktree_base` is overridden, the override path needs the equivalent entry. |
| `/.sensible-ralph-base-sha` | Per-worktree contract file. Absolute-from-worktree-root, so the entry uses a leading slash to anchor it. Without this, the file would be staged into the session's first feature commit. |
| `/.sensible-ralph-pending-merges` | Per-worktree marker for conflicts left in place by the parent-merge helpers. Absolute-from-worktree-root anchor. Without this, the file would be staged into the session's resolution commit during the drain loop. |
| `ralph-output.log` | Default `stdout_log_filename`. Per-worktree session log; no leading slash so it matches anywhere. If `stdout_log_filename` is overridden, the override needs its own entry. |
| `/.close-branch-inputs` | Handoff file written by `/close-issue` before invoking `close-branch`. Written at the start of each close ritual, deleted by `close-branch` on entry. Presence between runs signals an interrupted `/close-issue`. |
| `/.close-branch-result` | Result file written by `close-branch`, read and deleted by `/close-issue`. Same lifecycle as `/.close-branch-inputs`. |
| `/.sensible-ralph-coord-dep.json` | Per-worktree transport file written by `/sr-spec` step 11 (coord-dep scan) and consumed at step 12 (finalize). Successful finalize deletes it; presence between runs means the prior `/sr-spec` aborted between scan and finalize and the next `/sr-spec` re-loads the staged edges. |

The two `userConfig`-driven names (`worktree_base`, `stdout_log_filename`)
mean the gitignore list is technically convention-dependent, not
hardcoded — operators who customize either option must update their
`.gitignore` accordingly.

## Contract summary

What each actor owns:

| Actor | Creates path | Writes `.sensible-ralph-base-sha` | Writes log | Removes path | Required CWD |
|---|---|---|---|---|---|
| `/sr-spec` | yes (lazy at step 7) | no (only captures shell `SPEC_BASE_SHA`) | no | no | inside worktree (after step 7) |
| `orchestrator.sh` | yes (fallback create path only) | yes (post-merge HEAD) | yes (via tee) | only on create-path setup-failure rollback (`--force`, gated on same-invocation creation) | repo root |
| `/sr-implement` | no | no (does not read) | no (writes to it indirectly via `claude -p`) | no | inside worktree |
| `/prepare-for-review` | no | no (reads only) | no | no | inside worktree |
| `/close-issue` | no | no | no | yes (no `--force`, after `Done` transition) | main checkout (NOT a worktree) |

The naming convention is authoritative in `worktree_path_for_issue` —
both `/sr-spec` and the orchestrator call it to compute each path. The
*lookup* side differs by actor: the orchestrator's reuse path also calls
`worktree_branch_state_for_issue` to distinguish reuse / create / partial
residue. `/close-issue` finds the already-created worktree via
`git worktree list --porcelain` (resolves by branch ref, not by path
composition); `/prepare-for-review` uses its existing CWD. Filename
defaults come from the same `$CLAUDE_PLUGIN_OPTION_*` env vars for all
actors. The orchestrator is the only writer of `.sensible-ralph-base-sha`
state that downstream skills consume. Drift shows up as a contract
violation here, not as a silent inconsistency in the field.
