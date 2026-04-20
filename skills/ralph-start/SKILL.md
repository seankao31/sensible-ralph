---
name: ralph-start
description: Entry point for the user to dispatch the autonomous ralph-loop spec-queue. Do NOT auto-invoke. Run explicitly via /ralph-start before stepping away from the desk.
disable-model-invocation: true
allowed-tools: Bash, Read, Glob, Grep
---

# Ralph Start

Dispatch the autonomous spec-queue: sort Approved Linear issues into a DAG-aware order, preview the dispatch plan, and hand control to the orchestrator which creates worktrees, invokes `claude -p` sessions, and classifies their outcomes.

**Source of truth for behavior:** `agent-config/docs/specs/2026-04-17-ralph-loop-v2-design.md`.

## Prerequisites

- `linear` CLI authenticated (`linear --version` succeeds).
- `jq` available on PATH.
- `config.json` present in the skill directory (copy from `config.example.json` and customize). Required keys: `project`, `approved_state`, `review_state`, `failed_label`, `worktree_base`, `model`, `stdout_log_filename`, `prompt_template`.
- Invoke from a `bash` shell. `lib/config.sh` uses bash array syntax that fails to parse in zsh (`${!arr[@]}`); on macOS where the default shell is zsh, run `bash` first or wrap each step in `bash -c '…'`.
- Invoke from the **main checkout root**, not from inside a worktree. `worktree_path_for_issue` keys off `git rev-parse --show-toplevel`, which returns a linked worktree's own root if you're inside one — new worktrees will then nest at `<worktree>/.worktrees/<branch>` instead of `<repo>/.worktrees/<branch>`.

## Workflow (run in order)

### Step 1: Load config

```bash
SKILL_DIR="$(dirname "$(realpath "$0")")"  # or the skill install path
source "$SKILL_DIR/scripts/lib/config.sh" "$SKILL_DIR/config.json"
```

This exports `RALPH_PROJECT`, `RALPH_APPROVED_STATE`, `RALPH_REVIEW_STATE`, `RALPH_FAILED_LABEL`, `RALPH_WORKTREE_BASE`, `RALPH_MODEL`, `RALPH_STDOUT_LOG`, `RALPH_PROMPT_TEMPLATE`.

### Step 2: Pre-flight sanity scan

```bash
"$SKILL_DIR/scripts/preflight_scan.sh"
```

If non-zero exit: STOP. Print the anomalies and ask the user how to proceed (fix the issues in Linear, cancel a bad blocker, etc.). Do NOT continue to dispatch while anomalies exist.

### Step 3: Gather pickup-ready queue

Source the Linear wrapper and list approved issues:
```bash
source "$SKILL_DIR/scripts/lib/linear.sh"
approved="$(linear_list_approved_issues)"
```

Filter strictly to pickup-ready issues — an issue is pickup-ready only if ALL of:
- State == `$RALPH_APPROVED_STATE`
- No `$RALPH_FAILED_LABEL` label (already handled by `linear_list_approved_issues`)
- Every `blocked-by` relation is in {`Done`, `$RALPH_REVIEW_STATE`}
- No `blocked-by` relation is `Canceled` or `Duplicate`

For each approved issue, fetch blockers via `linear_get_issue_blockers` and apply the filter. Collect the qualifying issue IDs along with their priority (numeric 1-4 from `linear issue view --json | jq -r '.priority'`).

### Step 4: Topological sort

Render the filtered queue in the format toposort expects (`<id> <priority> [<blocker_id>...]`, one per line), then:

```bash
"$SKILL_DIR/scripts/toposort.sh" < queue_input.txt > ordered_queue.txt
```

If exit is non-zero (cycle detected), STOP and surface the cycle to the user.

### Step 5: Dry-run preview and confirmation

Print the ordered queue to the user. For each issue, also print the base branch selection (call `scripts/dag_base.sh <issue_id>` for each). Format:

```
Queue (5 issues):
  ENG-190: Add foo (base: main)
  ENG-191: Extend foo (base: eng-190-add-foo)
  ENG-192: Integrate foo and bar (base: INTEGRATION eng-190-add-foo eng-188-add-bar)
  ...
```

Ask the user to confirm (accept / skip specific issues / abort). Do NOT proceed without explicit confirmation — this is the point where the user sees what will be dispatched before walking away.

### Step 6: Dispatch via orchestrator

```bash
"$SKILL_DIR/scripts/orchestrator.sh" ordered_queue.txt
```

The orchestrator processes the queue sequentially, creates worktrees, invokes `claude -p`, classifies outcomes (using Linear state transition AS WELL AS exit code — exit 0 alone does not imply success), propagates failure taint downstream, and appends per-issue records to `progress.json` in the caller's cwd.

The orchestrator runs foreground — the user should expect the session to block until the queue completes or all remaining issues are tainted. Each issue's `claude -p` output is tee'd to `<worktree>/<RALPH_STDOUT_LOG>` for later inspection.

## When back

After the orchestrator returns:

- **`progress.json`** at the repo root lists all dispatched/skipped issues with outcomes.
- **In Review issues:** `cd` into the worktree, run a `claude --resume` if the session is still available, review code per the QA plan in the Linear comment, then invoke `/close-feature-branch` (project-local skill) or your project's merge ritual.
- **`ralph-failed` issues:** `cd` into the worktree, read `<worktree>/<RALPH_STDOUT_LOG>` for the session's final output. Decide: retry (remove the `ralph-failed` label and re-queue), cancel the issue, or debug interactively.
- **`setup_failed` issues:** orchestrator couldn't set up the worktree (branch lookup failed, dag_base returned garbage, etc.). Check the `failed_step` field in `progress.json`. Worktree cleanup has already run if the orchestrator created any state; a pre-existing path is left untouched for inspection.

## Red flags / when to stop

- **Pre-flight anomalies present:** do NOT dispatch. Surface the list; let the user fix in Linear first.
- **Cycle in toposort:** design problem in the blocker graph; the user must break the cycle by canceling or re-scoping one of the issues.
- **Preview shows unexpected work:** abort and ask the user. Never dispatch a queue the user didn't sign off on.
- **Linear auth failure:** abort immediately — the orchestrator will fail on every issue, producing noise with no work done.

## Notes

- The skill sets `disable-model-invocation: true` so it never auto-invokes. It is a user-driven trigger.
- The orchestrator's classification uses the Linear state post-dispatch (`exit 0` AND state == `$RALPH_REVIEW_STATE`) to distinguish true success from "session exited clean without completing `/prepare-for-review`" (the `exit_clean_no_review` outcome, which is also treated as `ralph-failed`).
- Worktree paths follow the chezmoi convention: `$REPO_ROOT/.worktrees/<branch-slug>` — project-local, `.gitignore`d, matches `superpowers:using-git-worktrees`.
- The orchestrator writes `.ralph-base-sha` to each worktree before dispatch. This is the cross-skill contract with `/prepare-for-review`, which uses it to scope codex review and the handoff summary to just the session's commits.
