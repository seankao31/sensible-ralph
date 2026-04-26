# Worktree contract

The cross-skill contract for how sensible-ralph creates, owns, hands off,
and tears down the linked git worktree backing each dispatched Linear
issue. Every dispatched issue runs in its own worktree; the orchestrator,
`/sr-implement`, `/prepare-for-review`, and `/close-issue` each touch the
worktree at different points and must agree on naming, CWD, the base-SHA
file, the output log, and removal preconditions.

## Naming

Worktree path:

```
<repo-root>/<worktree_base>/<branch>
```

- **`<repo-root>`** is resolved via `_resolve_repo_root` (in
  `skills/sr-start/scripts/lib/worktree.sh`), which calls
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

The path is computed by `worktree_path_for_issue "$branch"` — the single
implementation every actor calls, so the naming convention has one home.

## Creation

`orchestrator.sh` is the **sole creator**. It runs from the repo root
(see CWD convention below) and dispatches via `git worktree add`:

```bash
git worktree add "$path" -b "$branch" "$resolved_base"
```

Two helpers in `skills/sr-start/scripts/lib/worktree.sh` wrap this:

- **`worktree_create_at_base $path $branch $base`** — single-base case
  (default base branch, or a single in-review parent's branch).
- **`worktree_create_with_integration $path $branch $parents...`** —
  multi-parent integration case. Creates the worktree at
  `$SENSIBLE_RALPH_DEFAULT_BASE_BRANCH`, then sequentially merges each
  parent. Single-parent conflicts are left in place for the dispatched
  agent to resolve; multi-parent conflicts abort fast (subsequent parents
  can't be silently dropped). See
  `docs/archive/decisions/ralph-v2-multi-parent-integration-abort.md`.

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
| One blocker `In Review`, rest `Done` | That blocker's branch name |
| Multiple blockers `In Review` | `INTEGRATION <parent1> <parent2> ...` (triggers the integration helper) |

**Why not `claude --worktree`.** The orchestrator does not use the
`--worktree` flag on `claude`. That flag is a *create* path that branches
off `HEAD` into `<repo>/.claude/worktrees/<name>/` — it can't accept a
pre-created path and has no DAG or integration-merge awareness, so it
cannot satisfy the base-selection table above. The orchestrator
pre-creates the worktree at the correct base, then dispatches `claude -p`
with the worktree as its CWD via subshell `cd`.

## `.sensible-ralph-base-sha`

A single-line file at `<worktree>/.sensible-ralph-base-sha` containing
the SHA from which this branch was created. The file is the cross-skill
contract that lets `/prepare-for-review` scope its work to *this
session's* commits — not parent-branch commits absorbed via integration
merges, and not the main checkout's HEAD.

| Actor | Role |
|---|---|
| `orchestrator.sh` | **Writes** the file before dispatch, after worktree creation succeeds. For `main` and parent-branch bases, the SHA is the post-create `HEAD`. For integration bases, the SHA is `git rev-parse $SENSIBLE_RALPH_DEFAULT_BASE_BRANCH` captured **before** any parent merges run — post-merge HEAD would pull parent commits into the prepare-for-review diff. |
| `/sr-implement` | **Does not read.** The file is opaque to the implementer — implementation work needs only the worktree CWD and the PRD. |
| `/prepare-for-review` | **Reads** the file to compute `BASE_SHA`, used to scope (a) `update-stale-docs` (`--base $BASE_SHA`), (b) `codex-review-gate` (`--base $BASE_SHA`), and (c) the `git log --oneline $BASE_SHA..HEAD` block in the Linear handoff comment. |
| `/close-issue` | Does not read directly. The base-SHA's role ends after `/prepare-for-review` completes. |

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

The log is the operator entry point for debugging `failed`,
`exit_clean_no_review`, and `setup_failed` outcomes — `/sr-status`
points at `<worktree>/$CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME` for
post-mortem reading.

## CWD convention

Three actors, three rules. The differences are not stylistic — each
encodes a real failure-mode constraint.

| Actor | CWD | Why |
|---|---|---|
| `orchestrator.sh` | Repo root (or any path that resolves to it via `_resolve_repo_root`) | Dispatches each `claude -p` via `(cd "$path" && claude -p ...)` in a subshell, so the orchestrator's own CWD is never disturbed. Worktree-side ops use the captured `$path`. |
| `/sr-implement`, `/prepare-for-review` | Inside the worktree (CWD = `$path`) | The orchestrator enters via subshell `cd` before invoking `claude -p`. All implementation and prepare-for-review git operations are scoped to the worktree's branch by being there. |
| `/close-issue` | Main checkout (NOT a linked worktree); `.git` must be a directory, not a file | Worktree-side operations use `git -C "$WORKTREE_PATH" ...`. Running close-issue from inside the worktree being closed used to be the norm, but it pinned the Bash tool's session CWD to a directory that the skill's final step removes — any external cause (another process, stray `rm`, hook) that removed the directory mid-ritual killed the session instantly. The main-checkout CWD removes that failure class entirely; the skill enforces it via `[ -f "$MAIN_REPO/.git" ] && exit 1`. |

## Removal

`/close-issue` is the **normal remover** — it runs Step 8 after the
Linear `Done` transition so the high-value state mutations (merge, push,
branch delete, Linear Done) are already committed if removal fails. The
orchestrator's `_cleanup_worktree` helper is the **setup-failure remover**:
it rolls back worktrees this invocation created when a pre-dispatch setup
step fails, using `--force` because `.sensible-ralph-base-sha` would
otherwise block `git worktree remove`. These are distinct code paths
with different preconditions; both are documented in this section.

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
`--force` — but only as a setup-failure rollback, gated on the worktree
having been created by the same invocation that's now cleaning it up.
That is a different code path; close-issue's removal of a *human-
reviewed* worktree never uses force.

## Required `.gitignore` entries

Each consumer repo (any repo where `/sr-start` runs) must gitignore the
following at its root. The plugin's own `.gitignore` ships them so the
canonical list is copy-pasteable:

```
/.sensible-ralph/
/.worktrees/
/.sensible-ralph-base-sha
ralph-output.log
```

| Entry | Why |
|---|---|
| `/.sensible-ralph/` | Orchestrator runtime state — `progress.json`, `ordered_queue.txt`. Per-run, transient, repo-root-only. |
| `/.worktrees/` | Default `worktree_base`. Linked worktrees should never appear in the parent repo's tracked tree. If `worktree_base` is overridden, the override path needs the equivalent entry. |
| `/.sensible-ralph-base-sha` | Per-worktree contract file. Absolute-from-worktree-root, so the entry uses a leading slash to anchor it. Without this, the file would be staged into the session's first feature commit. |
| `ralph-output.log` | Default `stdout_log_filename`. Per-worktree session log; no leading slash so it matches anywhere. If `stdout_log_filename` is overridden, the override needs its own entry. |

The two `userConfig`-driven names (`worktree_base`, `stdout_log_filename`)
mean the gitignore list is technically convention-dependent, not
hardcoded — operators who customize either option must update their
`.gitignore` accordingly.

## Contract summary

What each actor owns:

| Actor | Creates path | Writes `.sensible-ralph-base-sha` | Writes log | Removes path | Required CWD |
|---|---|---|---|---|---|
| `orchestrator.sh` | yes | yes (pre-dispatch) | yes (via tee) | only on setup-failure rollback (`--force`, gated on same-invocation creation) | repo root |
| `/sr-implement` | no | no (does not read) | no (writes to it indirectly via `claude -p`) | no | inside worktree |
| `/prepare-for-review` | no | no (reads only) | no | no | inside worktree |
| `/close-issue` | no | no | no | yes (no `--force`, after `Done` transition) | main checkout (NOT a worktree) |

The naming convention is authoritative in `worktree_path_for_issue` —
the orchestrator calls it to compute each path before creation. The
*lookup* side differs by actor: `/close-issue` finds the already-created
worktree via `git worktree list --porcelain` (resolves by branch ref,
not by path composition); `/prepare-for-review` uses its existing CWD.
Filename defaults come from the same `$CLAUDE_PLUGIN_OPTION_*` env vars
for all actors. The orchestrator is the only writer of state that
downstream skills consume. Drift shows up as a contract violation here,
not as a silent inconsistency in the field.
