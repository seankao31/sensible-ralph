# Orchestrator

The dispatch loop that turns a list of Approved Linear issues into a sequence of `claude -p` sessions running in pre-staged worktrees.

The orchestrator is the heart of sensible-ralph's autonomous execution path. `/sr-start` builds the queue and hands it off; everything from worktree creation through outcome classification through `progress.json` accounting happens inside `skills/sr-start/scripts/orchestrator.sh`. This doc is the definitive reference for how that script behaves.

The orchestrator never invents work. Its inputs are a fixed ordered queue of issue IDs, the Linear state of each, and the per-repo scope (`.sensible-ralph.json`). Its outputs are worktrees, Linear state transitions, label writes, and `progress.json` records.

## Dispatch loop at a glance

```
┌─────────────────────────────────────────────────────────────────┐
│  Phase 1 — load queue, build parent→children map for taint      │
│    (per-issue blocker fetch; failure is per-issue isolated)     │
└──────────────────────┬──────────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│  Phase 2 — for each issue in queue order:                       │
│                                                                 │
│    if issue is in tainted set:                                  │
│        record outcome=skipped; continue                         │
│                                                                 │
│    _dispatch_issue:                                             │
│      ├─ linear_get_issue_branch  ─┐                             │
│      ├─ linear_get_issue_title    │ setup steps;                │
│      ├─ dag_base.sh               │ failure → setup_failed,     │
│      ├─ worktree_path_for_issue   │ taint, continue with next   │
│      ├─ pre-existence check       │ issue                       │
│      │     ├─ path / branch exists → local_residue              │
│      │     │   (no Linear mutation, no taint)                   │
│      ├─ git worktree add (at base or INTEGRATION)               │
│      ├─ write .sensible-ralph-base-sha                          │
│      ├─ linear_set_state IN_PROGRESS  ────┘                     │
│      │                                                          │
│      ├─ append progress.json {event:"start"}                    │
│      ├─ (cd worktree; claude -p --permission-mode auto …)       │
│      │     2>&1 | tee <stdout_log_filename>                     │
│      │                                                          │
│      ├─ linear_get_issue_state (post-dispatch)                  │
│      └─ classify outcome:                                       │
│           exit 0 + state fetch failed   → unknown_post_state    │
│           exit 0 + state == REVIEW      → in_review             │
│           exit 0 + state != REVIEW      → exit_clean_no_review  │
│                                            (label, taint)       │
│           exit != 0                     → failed (label, taint) │
│                                                                 │
│      └─ append progress.json {event:"end", outcome, …}          │
└─────────────────────────────────────────────────────────────────┘
```

The loop continues until the queue is empty or every remaining issue is tainted. The orchestrator runs foreground; `/sr-start` blocks on it.

## Queue construction

The ordered queue is built **before** the orchestrator runs and frozen for the duration of the dispatch:

1. **`build_queue.sh`** — calls `linear_list_approved_issues` (which unions over every project in `SENSIBLE_RALPH_PROJECTS` and excludes any issue carrying `$CLAUDE_PLUGIN_OPTION_FAILED_LABEL`), then per-issue checks the [pickup rule](linear-lifecycle.md#pickup-rule). Issues whose blockers are not all in `Done`, `In Review`, or queued-Approved are dropped with a stderr warning. For each surviving issue it emits `<issue_id> <priority> <blocker_id>...` to a temp file.
2. **`toposort.sh`** — Kahn's algorithm over the `blocked-by` graph restricted to the input set. Linear priority is the tiebreaker for issues ready at the same time (priority=0 "no priority" is remapped to 5 so it sorts after Low). A cycle exits non-zero with `error: cycle detected`.

The result lands at `.sensible-ralph/ordered_queue.txt` under the repo root. Fresh Approved issues that are added to Linear mid-run do **not** get picked up — the queue is fixed at `/sr-start` time. The "start" framing is deliberate: one invocation processes one queue.

The pickup rule's "queued Approved blocker counts as resolved" clause is what makes overnight execution of dependency chains work: toposort guarantees the parent dispatches before the child, the parent's session reaches `In Review` before the child's setup begins, and `dag_base.sh` then picks up the parent's branch as the child's base. See `docs/design/linear-lifecycle.md` for the full state-machine context.

## Base-branch selection (`dag_base.sh`)

For each queued issue, `dag_base.sh` reads its blockers and emits one of three outputs:

| In-review blocker count | Output | Worktree base |
|---|---|---|
| 0 | `$SENSIBLE_RALPH_DEFAULT_BASE_BRANCH` (default `main`; configurable via `.sensible-ralph.json` `default_base_branch`) | branch off trunk |
| 1 | the blocker's branch name | branch off the parent |
| ≥2 | `INTEGRATION <branch1> <branch2> ...` | branch off trunk, sequential `git merge` of each parent |

Blocker state is read **at dispatch time**, not at queue-build time. By the time `dag_base.sh` runs for issue B, an Approved-and-queued parent A has already transitioned to `In Review` (its `/prepare-for-review` ran at the end of A's session), so the three rows above cover every pickup-ready case.

A blocker that is `In Review` but has no `branchName` causes `dag_base.sh` to exit non-zero with an explicit error — the orchestrator records `setup_failed` for that issue rather than guessing a base.

### Multi-parent integration

For an `INTEGRATION ...` base, `lib/worktree.sh::worktree_create_with_integration` creates the worktree at the trunk SHA and merges parents sequentially. Conflict handling diverges by parent count:

- **Single parent with conflict:** the worktree is left with unresolved markers; the function returns 0. The dispatched agent resolves during its session — the `/sr-implement` skill instructs it to check `git status` first.
- **Multi-parent with any conflict:** `git merge --abort`, clean up, return non-zero. The orchestrator records `setup_failed` with `failed_step = worktree_create_with_integration`, applies `ralph-failed`, and taints descendants.

The asymmetry exists because Git's MERGING state forbids continuing through the parent list after the first conflict. See `docs/archive/decisions/ralph-v2-multi-parent-integration-abort.md` for the full reasoning. Operator resolution: merge one parent into trunk to promote it to Done, re-sequence the dependency graph, or merge a parent manually before re-running.

The trunk SHA captured for `.sensible-ralph-base-sha` in the integration path is read **before** any parent merges, so the `prepare-for-review` codex review and handoff diff stay scoped to this session's work — not parent commits already reviewed elsewhere.

## Per-issue setup

Inside `_dispatch_issue`, every step before `claude -p` is wrapped in `set +e` with explicit error handling. Any failure produces a `setup_failed` outcome with a `failed_step` identifier that names the broken step, applies `ralph-failed`, taints descendants, and continues with the next issue. The setup steps, in order:

1. `linear_get_issue_branch` — fetches Linear's auto-generated branch name. A literal `null` (from `jq -r` on a missing field) is treated as `missing_branch_name` rather than letting the orchestrator create a branch literally named `null`.
2. `linear_get_issue_title` — used for the `claude -p --name` session name.
3. `dag_base.sh` — base selection (above). Empty or whitespace-malformed output is rejected.
4. `worktree_path_for_issue` — resolves `$REPO_ROOT/$CLAUDE_PLUGIN_OPTION_WORKTREE_BASE/<branch>`.
5. **Pre-existence check.** If the target path exists *or* the branch already exists locally, the issue lands as `local_residue` — Linear is **not** mutated, descendants are **not** tainted. The pre-existing state is operator state (manual mkdir, prior crashed run, in-flight branch) that this invocation did not create. See `docs/design/outcome-model.md` for why.
6. `git worktree add` — through `worktree_create_at_base` (single base) or `worktree_create_with_integration` (multi-parent). Both helpers accept either a local head or a remote-tracking ref under `origin/` so a fresh clone with fetched-but-not-checked-out parents still works. On post-`add` failure (e.g. integration merge error), `_cleanup_worktree` removes the partial worktree and branch so the next run has a clean slate.
7. **Write `.sensible-ralph-base-sha`** to the worktree root. This is the cross-skill contract with `/prepare-for-review`, which uses it to scope codex review and the handoff diff to this session's commits.
8. **Linear: Approved → In Progress** via `linear_set_state`. After this point any failure path also triggers `_cleanup_worktree`.

## Dispatch

The prompt is built from two pieces:

```
<contents of skills/sr-start/scripts/autonomous-preamble.md>

/sr-implement <ISSUE_ID>
```

Prepending the autonomous-mode preamble in the orchestrator (rather than inside the skill) puts the override rules in context from token zero, so any reasoning between session start and the skill's load runs under autonomous-mode rules. The blank line between preamble and `/sr-implement` ensures the slash command starts on its own line for the harness's command recognizer. See `docs/design/autonomous-mode.md` (forthcoming, ENG-297) for the preamble's full override semantics.

The invocation:

```bash
(
  cd "$path"
  claude -p \
    --permission-mode auto \
    --model "$CLAUDE_PLUGIN_OPTION_MODEL" \
    --name "$issue_id: $title" \
    "$prompt" \
    2>&1 | tee "$path/$CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME"
)
```

A few details that matter:

- **`cd $path` in a subshell, not `claude --worktree`.** The `--worktree` flag creates a new worktree off `HEAD` under `~/.claude/worktrees/`; it can't accept a pre-created path and has no DAG/integration awareness. The orchestrator pre-creates the worktree at the right base and dispatches into it via cwd.
- **Foreground, sequential.** Parallel dispatch within a DAG layer is an explicit non-goal; the loop processes issues one at a time.
- **Full session log captured.** The `tee` writes the entire `claude -p` stream to `<worktree>/<stdout_log_filename>` for later inspection. `PIPESTATUS[0]` preserves claude's exit code through the tee pipe.
- **Session name `<ISSUE_ID>: <title>`** — used by `claude --resume` so the operator can drop back into any dispatched session interactively.

The `progress.json` `event: "start"` record is written immediately before the subshell so `/sr-status` can render an in-flight Running row mid-run.

## Outcome classification

After `claude -p` returns, the orchestrator fetches the post-dispatch Linear state and classifies into one of seven outcomes. The full classification rules, the rationale for treating `exit 0` as ambiguous, and the reasons `local_residue` and `unknown_post_state` deliberately leave Linear untouched are in `docs/design/outcome-model.md`. In short:

- `in_review` — `exit 0` + `state == REVIEW_STATE`. The only success.
- `exit_clean_no_review` — `exit 0` + state-fetched-OK but ≠ `REVIEW_STATE`. Auto mode refused something. Labels `ralph-failed`, taints descendants.
- `failed` — `exit != 0`. Labels `ralph-failed`, taints descendants.
- `unknown_post_state` — `exit 0` + state fetch failed transiently. **No** label, **no** taint.
- `setup_failed` — pre-dispatch step failed; recorded with `failed_step`. Labels `ralph-failed`, taints descendants.
- `local_residue` — pre-existing path/branch detected before any mutation. **No** label, **no** taint.
- `skipped` — issue was tainted before its turn arrived; no claude invocation.

## Taint propagation

When an outcome triggers taint (`failed`, `exit_clean_no_review`, `setup_failed`), `_taint_descendants` does a BFS from the failed issue through the parent→children map built in Phase 1, adding every transitive descendant to a space-delimited `tainted_ids` string. Subsequent loop iterations check membership and emit `outcome: skipped` records without attempting dispatch.

**Taint is in-memory for this run only.** It is not persisted to `progress.json` (other than as `outcome: skipped` records on each affected issue). On the next `/sr-start`, the failed issue still carries its `ralph-failed` label, which excludes it from `linear_list_approved_issues` and naturally re-protects its descendants — they fail the pickup rule because their parent isn't in the queue.

The parent→children map is built from each queued issue's `blocked-by` relations. If `linear_get_issue_blockers` fails for one issue during map building, that issue's children are not registered as descendants — a failure of *that* issue won't taint its children. This is a documented degradation; the orchestrator logs it to stderr but doesn't abort.

The independence guarantee: an issue that is **not** transitively downstream of any failure continues to dispatch normally, even if other branches of the DAG fail. The whole point of taint-vs-stop is that a single bad chain doesn't waste an overnight run on independent work.

## `progress.json`

`progress.json` lives at `<repo-root>/.sensible-ralph/progress.json`, where `<repo-root>` is resolved via `git --git-common-dir` (so the path is identical whether the orchestrator runs from the main checkout or a linked worktree). Multiple worktrees of the same repo share the same file by design.

It is a **flat JSON array** appended atomically: every write is a `mktemp` + `jq '. + [$rec]'` + `mv`. POSIX guarantees the rename is atomic on the same filesystem, so a crash mid-write leaves the previous file intact rather than producing a partial append. There is no flock — concurrent orchestrators against the same `progress.json` would race, and same-repo concurrency is an explicit non-goal.

Each record carries:

- **`event`** — `"start"` (immediately before `claude -p`) or `"end"` (after classification). Discriminator added in ENG-241 so `/sr-status` can render in-flight Running rows. Pre-ENG-241 records have no `event` field and are filtered out via `run_id` selection (latest run only).
- **`issue`** — Linear issue ID. Always present.
- **`timestamp`** — ISO 8601 UTC. On `start` records, the dispatch moment. On `end` records, the same dispatch timestamp — so `timestamp + duration_seconds` consistently means "claude end time."
- **`run_id`** — ISO 8601 UTC captured once at orchestrator start. Every record from the same invocation shares this value; consumers group by it for per-run analysis.
- **`outcome`** — `end` records only. One of the seven outcomes above.
- **`branch`, `base`** — `start` records and dispatched-outcome `end` records (`in_review`, `exit_clean_no_review`, `failed`, `unknown_post_state`).
- **`exit_code`, `duration_seconds`** — dispatched-outcome `end` records only. `duration_seconds` is keyed off the `claude -p` invocation start, not function entry, so it measures the session itself rather than setup overhead.
- **`failed_step`** — `setup_failed` end records only.
- **`residue_path`, `residue_branch`** — `local_residue` end records only.
- **(none beyond core)** — `skipped` records carry only `issue`, `outcome`, `event`, `timestamp`, `run_id`.

The schema is additive: old consumers reading only `outcome` continue to work because `start` records have no `outcome` field and naturally filter out. See `docs/decisions/2026-04-25-progress-json-event-discriminator.md` for the alternatives considered.

## See also

- [`linear-lifecycle.md`](linear-lifecycle.md) — Linear state machine, transitions, labels, and the pickup rule the orchestrator drives.
- [`outcome-model.md`](outcome-model.md) — full classification rules for each of the seven outcomes, including the rationale for `local_residue` and `unknown_post_state` leaving Linear untouched.
- [`scope-model.md`](scope-model.md) — how `SENSIBLE_RALPH_PROJECTS` and `SENSIBLE_RALPH_DEFAULT_BASE_BRANCH` are loaded from `.sensible-ralph.json`, and how cross-project blocker resolution works.
- `docs/design/autonomous-mode.md` (forthcoming, ENG-297) — the preamble injected at session start and how it overrides CLAUDE.md rules for dispatched sessions.
- `docs/design/worktree-contract.md` (forthcoming, ENG-296) — naming conventions and the `.sensible-ralph-base-sha` contract between the orchestrator and `/prepare-for-review`.
- `docs/archive/decisions/ralph-v2-multi-parent-integration-abort.md` — why multi-parent integration aborts on conflict instead of leaving conflicts for the agent.
- `docs/decisions/2026-04-25-progress-json-event-discriminator.md` — why `event` is a discriminator field rather than a separate file or nested structure.
