---
name: ralph-start
description: Entry point for the user to dispatch the autonomous ralph-loop spec-queue. Do NOT auto-invoke. Run explicitly via /ralph-start before stepping away from the desk.
disable-model-invocation: true
allowed-tools: Bash, Read, Glob, Grep
---

# Ralph Start

Dispatch the autonomous spec-queue: sort Approved Linear issues into a DAG-aware order, preview the dispatch plan, and hand control to the orchestrator which creates worktrees, invokes `claude -p` sessions, and classifies their outcomes.

**Source of truth for behavior:** `docs/specs/ralph-loop-v2-design.md`.

## Prerequisites

- `linear` CLI authenticated (`linear --version` succeeds).
- `jq` available on PATH.
- Plugin userConfig values set. The Claude Code harness prompts for these at install time; all have defaults that work with a stock Linear workflow. The nine keys are: `approved_state`, `in_progress_state`, `review_state`, `done_state`, `failed_label`, `stale_parent_label`, `worktree_base`, `model`, `stdout_log_filename`. The four state-name keys must match the actual workflow state names in your Linear workspace; edit via `/config` or your `settings.json` if defaults don't match.
- Per-repo `.ralph.json` at the repo root declaring the run's scope — see next section.
- Workspace-scoped Linear labels exist (one-time admin setup). Label **names are userConfig-driven** — the orchestrator and your project's merge ritual look up labels by the values of the `failed_label` and `stale_parent_label` plugin options, so the labels you create in Linear must match whatever names those options hold. Linear's label-by-name resolution silently no-ops on a nonexistent name, so preflight fails loud rather than letting labelless "marks" accumulate:
  - The label named in the **`failed_label`** option (default `ralph-failed`) — applied by the orchestrator to issues that hard-failed, exited clean without reaching review, or hit a per-issue setup failure. `linear_list_approved_issues` excludes labeled issues from subsequent runs. Preflight (`scripts/preflight_scan.sh` via `lib/preflight_labels.sh`) aborts with a setup hint if missing.
  - The label named in the **`stale_parent_label`** option (default `stale-parent`) — applied by your project's merge ritual to In-Review child issues whose blocked-by parent was amended after dispatch (review was based on pre-amendment content). Preflight-gated by the same helper whenever the option is set.

  If you've accepted the defaults, create both labels once per workspace:
  ```bash
  linear label create --name ralph-failed --color '#EB5757' --description 'Orchestrator dispatched this issue but it did not reach the review state.'
  linear label create --name stale-parent --color '#F2994A' --description 'In-Review issue whose blocked-by parent was amended after dispatch.'
  ```
  If you've customized `failed_label` or `stale_parent_label`, substitute their values for the `--name` argument above. The preflight error messages quote both the literal label name and the env var that points at it, so a missing or typo'd setup is unambiguous.

The orchestrator scripts have `#!/usr/bin/env bash` shebangs and source `lib/scope.sh` internally, so you can run them from any shell (zsh, fish, sh, etc.). The plugin harness auto-exports userConfig values as `CLAUDE_PLUGIN_OPTION_<KEY>` env vars in plugin subprocesses, so no manual config-path management is needed.

## Scope resolution

Which Linear projects this run drains is declared in `<repo-root>/.ralph.json` (auto-discovered via `git rev-parse --show-toplevel`, so each worktree reads its own committed version). Two shapes, either resolves to a project list at load time:

```jsonc
// Explicit — one or more projects
{ "projects": ["Project A", "Project B"] }

// Shorthand — Linear initiative name, expanded to its member projects on every invocation
{ "initiative": "My Initiative" }
```

**Default base branch.** An optional `default_base_branch` field (string) sets the branch ralph branches from when an Approved issue has no in-review parent in the queue. Defaults to `"main"` if absent. Example: `{ "projects": [...], "default_base_branch": "dev" }`.

Rules (all hard errors at load time, no silent fallbacks):

- `.ralph.json` must exist at the repo root. Missing file halts with a message pointing at the expected path.
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

### Step 2: Build the ordered queue

```bash
"$SKILL_DIR/scripts/build_queue.sh" > ordered_queue.txt
```

`build_queue.sh` lists pickup-ready Approved issues (state == `$CLAUDE_PLUGIN_OPTION_APPROVED_STATE`, no `$CLAUDE_PLUGIN_OPTION_FAILED_LABEL` label, every blocker in `$CLAUDE_PLUGIN_OPTION_DONE_STATE`, `$CLAUDE_PLUGIN_OPTION_REVIEW_STATE`, or `$CLAUDE_PLUGIN_OPTION_APPROVED_STATE`), then topologically sorts them via `toposort.sh` with Linear priority as the tiebreaker (priority=0 sorts last because Linear uses 0 for "no priority"). Approved blockers are accepted because the orchestrator dispatches Approved chains in topological order — the parent reaches In Review before the child runs and `dag_base.sh` picks up the parent's branch as the base. Issues with blockers in any other state (Triage, Backlog, Todo, In Progress, Canceled, Duplicate) are skipped with a warning to stderr.

If exit is non-zero (cycle detected in toposort), STOP and surface the cycle to the user.

### Step 3: Dry-run preview and confirmation

Print the ordered queue to the user. For each issue, also print the base branch selection (call `scripts/dag_base.sh <issue_id>` for each). Format:

```
Queue (5 issues):
  ENG-190: Add foo (base: main)
  ENG-191: Extend foo (base: eng-190-add-foo)
  ENG-192: Integrate foo and bar (base: INTEGRATION eng-190-add-foo eng-188-add-bar)
  ...
```

Ask the user to confirm (accept / skip specific issues / abort). Do NOT proceed without explicit confirmation — this is the point where the user sees what will be dispatched before walking away.

### Step 4: Dispatch via orchestrator

```bash
"$SKILL_DIR/scripts/orchestrator.sh" ordered_queue.txt
```

The orchestrator processes the queue sequentially, creates worktrees, invokes `claude -p`, classifies outcomes (using Linear state transition AS WELL AS exit code — exit 0 alone does not imply success), propagates failure taint downstream, and appends per-issue records to `progress.json` at the repo root (resolved via `git --git-common-dir` so the path is stable whether `/ralph-start` is invoked from the main checkout or a linked worktree).

The orchestrator runs foreground — the user should expect the session to block until the queue completes or all remaining issues are tainted. Each issue's `claude -p` output is tee'd to `<worktree>/<CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME>` for later inspection.

## When back

After the orchestrator returns:

- **`progress.json`** at the repo root lists all dispatched/skipped issues with outcomes.
- **`in_review` issues:** `cd` into the worktree, run a `claude --resume` if the session is still available, review code per the QA plan in the Linear comment, then run your project's merge ritual from a session at the main-checkout root — not from inside the worktree.
- **`failed` / `exit_clean_no_review` issues** (labeled `ralph-failed`, descendants tainted): `cd` into the worktree, read `<worktree>/<CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME>` for the session's final output. Decide: retry (remove the `ralph-failed` label and re-queue), cancel the issue, or debug interactively.
- **`setup_failed` issues** (labeled `ralph-failed`, descendants tainted): orchestrator couldn't set up the worktree (branch lookup failed, dag_base returned garbage, etc.). Check the `failed_step` field in `progress.json`. Worktree cleanup has already run for state this invocation created.
- **`local_residue` issues** (Linear NOT mutated, descendants NOT tainted): the target worktree path or branch already existed at the start of dispatch — the orchestrator never touched it. Check the `residue_path` and `residue_branch` fields in `progress.json`, manually clean up the residue (commit or remove), then re-queue. Operator state (manual mkdir, prior crashed run, in-flight branch) is preserved unchanged.
- **`unknown_post_state` issues** (Linear NOT mutated, descendants NOT tainted): claude exited 0 but the post-dispatch Linear state fetch failed transiently. Open the issue in Linear: if state is `In Review`, treat as success (no `ralph-failed` was applied); if it's still `In Progress`, treat as a soft failure and re-queue.

## Red flags / when to stop

- **Pre-flight anomalies present:** do NOT dispatch. Surface the list; let the user fix in Linear first.
- **Cycle in toposort:** design problem in the blocker graph; the user must break the cycle by canceling or re-scoping one of the issues.
- **Preview shows unexpected work:** abort and ask the user. Never dispatch a queue the user didn't sign off on.
- **Linear auth failure:** abort immediately — the orchestrator will fail on every issue, producing noise with no work done.

## Notes

- The skill sets `disable-model-invocation: true` so it never auto-invokes. It is a user-driven trigger.
- The orchestrator's classification uses the Linear state post-dispatch (`exit 0` AND state == `$CLAUDE_PLUGIN_OPTION_REVIEW_STATE`) to distinguish true success from "session exited clean without completing `/prepare-for-review`" (the `exit_clean_no_review` outcome, which is also treated as `ralph-failed`).
- Worktree paths follow the convention: `$REPO_ROOT/$CLAUDE_PLUGIN_OPTION_WORKTREE_BASE/<branch-slug>` — project-local, `.gitignore`d, matches `superpowers:using-git-worktrees`.
- The orchestrator writes `.ralph-base-sha` to each worktree before dispatch. This is the cross-skill contract with `/prepare-for-review`, which uses it to scope codex review and the handoff summary to just the session's commits.
