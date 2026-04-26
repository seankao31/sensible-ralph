---
name: close-issue
description: Linear-side close ritual for a sensible-ralph feature branch. Use when the user has finished reviewing an In-Review Linear issue and is ready to ship — runs the Linear preflight (state, blockers), untracked-file preservation, delegates VCS integration to the project-local `close-branch` skill, then handles stale-parent labeling, the Linear Done transition, codex broker reap, and worktree removal. Invoke from the main-checkout CWD with the Linear issue ID as an argument (e.g. `/close-issue ENG-197`). Requires the project to provide a `close-branch` skill at `.claude/skills/close-branch/` — that skill owns every project-specific git decision (base branch, merge strategy, push model, branch-delete policy).
argument-hint: <issue-id>
model: sonnet
allowed-tools: Skill, Bash, Read, Glob, Grep
disable-model-invocation: true
---

# Close Issue

The Linear-side close ritual for a sensible-ralph feature branch, run AFTER the user has reviewed the work. This skill runs every concern that's invariant across projects using ralph (Linear state lifecycle, blocker ordering, worktree/branch naming, codex broker plumbing) and delegates every project-specific VCS decision (base branch, merge strategy, push model) to the project-local `close-branch` skill.

This skill is NOT for doing tests, code review, docs, or decision captures — those belong in `/prepare-for-review`, which runs earlier in the lifecycle. See `docs/usage.md` for how this fits the ralph cycle.

## When to Use

- After the user has reviewed a Linear issue in `$CLAUDE_PLUGIN_OPTION_REVIEW_STATE` (default `In Review`) and approved the work for merge.
- On a feature branch in a worktree under `.worktrees/` (created by the ralph orchestrator, or by `superpowers:using-git-worktrees` if available).

## Invocation

Invoke from the **main-checkout CWD** (repo root) with the Linear issue ID as the only argument:

```
/close-issue ENG-197
```

Running from inside the worktree being closed used to be the norm, but it pinned the Bash tool's session CWD to that worktree — any external cause (another process, stray `rm`, hook) that removed the directory mid-ritual killed the session instantly. Invoking from the main checkout removes that failure class entirely: the CWD is stable throughout, and all worktree-side git ops use `git -C "$WORKTREE_PATH" …`.

## Capture issue ID up front

The agent receives the issue ID as the invocation argument and exposes it as `$ISSUE_ID`. If the argument is missing, stop and ask the user for it.

## Main-checkout-CWD invariant

Verify the session is rooted in the main checkout, not a linked worktree. In a main checkout, `.git` is a directory; in a linked worktree, `.git` is a file.

```bash
MAIN_REPO=$(git rev-parse --show-toplevel)
if [ -f "$MAIN_REPO/.git" ]; then
  echo "Error: must be invoked from the main checkout, not a linked worktree." >&2
  echo "Detected worktree root at: $MAIN_REPO" >&2
  exit 1
fi
```

## Source ralph-start libs

Source from the bundled ralph-start skill at `$CLAUDE_PLUGIN_ROOT/skills/ralph-start/`. This is the same source pattern `/ralph-spec` uses; `$CLAUDE_PLUGIN_ROOT` is exported by the Claude Code harness whenever the plugin is enabled.

Source `lib/linear.sh` first — it defines helpers used throughout Pre-flight, Step 6, and Step 7 (`linear_get_issue_blockers`, `linear_label_exists`, `linear_get_issue_blocks`, `linear_comment`, `linear_add_label`, `linear_get_issue_state`) and is a load-time dependency of `scope.sh` (the latter's guard rejects callers that forget) and `preflight.sh` (`close_issue_check_review_state` calls `linear_get_issue_state` at run time). Then source `scope.sh` to resolve the repo's `.ralph.json` (only needed if this skill later references `$RALPH_PROJECTS`; harmless if not). `branch_ancestry.sh` is sourced explicitly for `resolve_branch_for_issue`, `is_branch_fresh_vs_sha`, and `list_commits_ahead`. `close-issue/scripts/lib/preflight.sh` is sourced last for `close_issue_check_review_state` (used in Pre-flight §1). Workflow state-name values (`$CLAUDE_PLUGIN_OPTION_REVIEW_STATE`, `$CLAUDE_PLUGIN_OPTION_DONE_STATE`, `$CLAUDE_PLUGIN_OPTION_STALE_PARENT_LABEL`) are already exported by the plugin harness — no source call needed.

```bash
RALPH_LIB="$CLAUDE_PLUGIN_ROOT/skills/ralph-start/scripts/lib"
source "$RALPH_LIB/defaults.sh"       # CLAUDE_PLUGIN_OPTION_* fallbacks
source "$RALPH_LIB/linear.sh"
source "$RALPH_LIB/scope.sh"
source "$RALPH_LIB/branch_ancestry.sh"
source "$CLAUDE_PLUGIN_ROOT/skills/close-issue/scripts/lib/preflight.sh"
source "$CLAUDE_PLUGIN_ROOT/skills/close-issue/scripts/lib/stale_parent.sh"
```

## Resolve `FEATURE_BRANCH` and `WORKTREE_PATH`

Linear's branch-name convention is lowercase `<issue-id>-<slug>`. The shared ancestry helper is the primary resolver; Linear's canonical `.branchName` is a one-shot fallback for historic/renamed branches.

```bash
resolve_rc=0
FEATURE_BRANCH=$(resolve_branch_for_issue "$ISSUE_ID") || resolve_rc=$?

if [ "$resolve_rc" -eq 2 ]; then
  # Multiple matches — genuinely ambiguous. The helper has already printed
  # the candidate branches to stderr. Stop rather than silently picking one.
  exit 1
fi

if [ "$resolve_rc" -eq 1 ] || [ -z "$FEATURE_BRANCH" ]; then
  # Zero matches — fall back to Linear's canonical branchName in case the
  # local branch uses a non-standard prefix (rename, historic naming).
  FEATURE_BRANCH=$(linear issue view "$ISSUE_ID" --json 2>/dev/null | jq -r '.branchName // empty')
  if [ -z "$FEATURE_BRANCH" ] || ! git show-ref --verify --quiet "refs/heads/$FEATURE_BRANCH"; then
    ISSUE_SLUG=$(echo "$ISSUE_ID" | tr '[:upper:]' '[:lower:]')
    echo "Error: no local branch matches '${ISSUE_SLUG}-*', and Linear's branchName for $ISSUE_ID was not found locally." >&2
    exit 1
  fi
fi

WORKTREE_PATH=$(git worktree list --porcelain | awk -v b="refs/heads/$FEATURE_BRANCH" '
  /^worktree / { path = substr($0, 10) }
  $0 == "branch " b { print path; exit }
')

if [ -z "$WORKTREE_PATH" ]; then
  echo "Error: no worktree found for branch $FEATURE_BRANCH." >&2
  exit 1
fi
```

All subsequent commands reference `$FEATURE_BRANCH`, `$ISSUE_ID`, `$WORKTREE_PATH`, and `$MAIN_REPO`. The CWD stays at `$MAIN_REPO` for the entire ritual — worktree-side operations use `git -C "$WORKTREE_PATH" …`.

## Pre-flight

### 1. Verify the issue is in the review state

```bash
close_issue_check_review_state "$ISSUE_ID" || exit 1
```

Expected: `$CLAUDE_PLUGIN_OPTION_REVIEW_STATE` (default: `In Review`; override via the plugin's userConfig).

- **Matches `$CLAUDE_PLUGIN_OPTION_REVIEW_STATE`** — proceed.
- **Matches `$CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE`** — the work hasn't been handed off for review yet. Run `/prepare-for-review` first.
- **Matches `$CLAUDE_PLUGIN_OPTION_DONE_STATE`** — nothing to do; the branch was already closed. Investigate whether this worktree is leftover and can be removed.
- **Any other state** — stop and surface to the user. The dispatch lifecycle is off.

### 2. Verify all `blocked-by` parents are Done

```bash
blockers_json=$(linear_get_issue_blockers "$ISSUE_ID") || exit 1

printf '%s\n' "$blockers_json" | jq -r --arg done "$CLAUDE_PLUGIN_OPTION_DONE_STATE" '
  if type == "array" and all(.[]; has("id") and has("state")) then
    .[] | select(.state != $done) | "\(.id)\t\(.state)"
  else
    error("linear_get_issue_blockers returned unexpected JSON shape")
  end
'
```

Two fail-closed hinges, both required to keep "no output means proceed" trustworthy:

1. **Capture then filter, not pipe.** `blockers_json=$(...) || exit 1` surfaces helper failures (Linear API, auth, pagination overflow) as a non-zero exit. A direct pipe would feed empty stdin to `jq` on helper failure, which produces empty output and exit 0 — masquerading as "no blockers, proceed."
2. **Validate shape in jq.** The `type == "array" and all(...; has("id") and has("state"))` guard ensures an unexpected return shape (wrapper object, `null`, `{}`, schema drift) errors out instead of iterating to empty output.

- **Non-zero exit** — either the helper failed or its JSON didn't match the expected shape; a diagnostic is on stderr. STOP and surface to the user; the blocker set is unknown and proceeding is unsafe.
- **No output from `jq`** — no unresolved blockers; proceed.
- **Any output from `jq`** — each line is `<blocker-id>\t<state>`. STOP. Print the list and refuse to close. Tell the user: `Canceled` blockers are NOT treated as resolved (per ralph v2 Decision 6 in `docs/specs/ralph-loop-v2-design.md`); the supported way to declare "this is no longer a blocker" is to remove the relation in Linear via `linear issue relation delete "$ISSUE_ID" blocked-by <blocker-id>` and re-run. No `--force` escape hatch.

Why this belongs in pre-flight: ralph v2 dispatches child branches before their parents are Done. If the child closes first, the child's branch still carries the parent's un-reviewed commits — close-branch's rebase reconciles content but doesn't know which commits belong to which issue, and close-branch's fast-forward merge then lands the parent's work on the base branch as a side effect of closing the child. Guarding at the child's close time keeps the "nothing merges until it's been reviewed" invariant intact.

`linear_get_issue_blockers` is sourced from the ralph-start skill's library. It uses `linear api` (GraphQL) rather than text-parsing `linear issue relation list` output — see the function's docstring for rationale and pagination behavior.

### 3. Preserve untracked files

```bash
git -C "$WORKTREE_PATH" ls-files --others --exclude-standard
```

If this lists any files, stop and ask the user what to do with each one. Options:
- Commit them (if they're part of the work that should land).
- Copy them out to a safe location (e.g., `~/ralph-handoff-artifacts/$ISSUE_ID/`) before removing the worktree.
- Explicitly discard if they're truly ephemeral.

Never silently discard untracked files. `plan.md` files have been lost this way before — the whole reason this pre-flight exists. Run this BEFORE invoking `close-branch`: it's a data-safety gate for the worktree-removal step later in this skill, not a precondition for rebase.

## Step 4: Invoke `close-branch`

Hand off VCS integration to the project-local `close-branch` skill via the `Skill` tool. `close-branch` owns every project-specific decision: base branch, rebase policy, merge strategy, push model, branch-delete semantics.

On entry, `close-branch` can assume:

- CWD is the main checkout (`.git` is a directory).
- Linear issue is in `$CLAUDE_PLUGIN_OPTION_REVIEW_STATE` with all `blocked-by` parents in `$CLAUDE_PLUGIN_OPTION_DONE_STATE`.
- Untracked files in `$WORKTREE_PATH` have been preserved or explicitly discarded.
- A file at `$MAIN_REPO/.close-branch-inputs` contains `ISSUE_ID`, `FEATURE_BRANCH`, `WORKTREE_PATH` in single-quoted `KEY='VALUE'` format, readable via `source`.

Shell variables set in `close-issue`'s Bash calls don't reliably propagate into `close-branch`'s Bash calls — each Bash tool dispatch is a fresh shell, and the spec explicitly notes that exports don't cross Skill-tool invocation boundaries. Pass inputs symmetrically with the return channel: write them to a gitignored file that `close-branch` sources at entry.

Before invoking, also delete any stale result file from a previously interrupted `/close-issue` run. Without this, a PR-pending `close-branch` (which intentionally writes no result file) would leave the file containing the previous issue's SHA + summary, and close-issue would apply stale-parent labeling and the final message against the wrong integration point.

Escape embedded single quotes before writing — `WORKTREE_PATH` is an absolute filesystem path and for portable use across projects it may contain quotes (e.g. `/home/ab's laptop/.worktrees/...`). POSIX single-quote escape: `'` → `'\''` (close the quote, insert an escaped literal, reopen).

```bash
rm -f "$MAIN_REPO/.close-branch-result"

sq_escape() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

{
  printf "ISSUE_ID='%s'\n"       "$(sq_escape "$ISSUE_ID")"
  printf "FEATURE_BRANCH='%s'\n" "$(sq_escape "$FEATURE_BRANCH")"
  printf "WORKTREE_PATH='%s'\n"  "$(sq_escape "$WORKTREE_PATH")"
} > "$MAIN_REPO/.close-branch-inputs"
```

Invoke `close-branch`. It sources and deletes the inputs file at entry. On non-zero exit from `close-branch`, print the diagnostic and stop — **no cleanup runs on failure**. Linear Done transition, stale-parent labeling, and worktree removal are all skipped. Partial state is `close-branch`'s concern to report; the operator decides recovery.

## Step 5: Read result file

After `close-branch` returns successfully, read the return values via a result file at `$MAIN_REPO/.close-branch-result`. Bash `export` is scoped to its subprocess and is not visible across `Skill`-tool invocation boundaries, so return values flow via a shell-sourceable `KEY='VALUE'` file:

```
INTEGRATION_SHA='<sha>'
INTEGRATION_SUMMARY='<one-line summary>'
```

```bash
INTEGRATION_SHA=""
INTEGRATION_SUMMARY=""
if [ -f "$MAIN_REPO/.close-branch-result" ]; then
  # shellcheck disable=SC1091
  source "$MAIN_REPO/.close-branch-result"
  rm -f "$MAIN_REPO/.close-branch-result"
fi
```

If the file is absent (e.g., `close-branch` succeeded but did not produce a landed SHA — PR-pending workflows), both values are empty. Stale-parent labeling skips; the final message falls back to a generic line.

`.close-branch-result` is gitignored.

## Step 6: Label In-Review children that built on pre-amendment content

Ralph v2 dispatches multi-level DAGs: parent `A` may still be In Review when child `B` (whose `blocked-by` is `A`) is already being built. If `A` gets amended during review and then lands via this ritual, any In-Review child `B` that was dispatched before the amendments is structurally stale — the reviewer signed off on `B` against a base that no longer exists.

This step detects that at `A`'s close time (when amendments have canonically landed) and labels each stale child with `$CLAUDE_PLUGIN_OPTION_STALE_PARENT_LABEL` plus a Linear comment explaining the divergence. Non-fatal: any failure is recorded in a warning array printed immediately — the landing has already happened, so the labeling is observational, not a merge-safety gate. The ordering guardrail in Pre-flight §2 prevents child branches from landing un-reviewed; this step surfaces the review-integrity gap that guardrail cannot address.

**Skip entirely if `$INTEGRATION_SHA` is empty.** Projects whose `close-branch` doesn't yet produce a landed SHA (PR-pending, multi-branch cascade with a later merge step) don't have a canonical parent HEAD to compare against; labeling against `HEAD` would be wrong.

```bash
close_issue_label_stale_children "$ISSUE_ID" "$INTEGRATION_SHA"
```

**Known limitations.** SHA-ancestry flags a child as stale even if the parent's amendment was a pure rebase with content unchanged — the operator dismisses the label manually. No auto-rebase of stale children; the operator decides whether to rebase and re-review, accept the review gap, or reopen review. Projects that override ralph's default branch naming see the helper gracefully skip each child via the "no local branch matching slug" WARN path.

## Step 7: Transition Linear issue to Done

Check current state, skip the write if it's already Done (harmless but avoids noise), otherwise transition:

```bash
current_state=$(linear_get_issue_state "$ISSUE_ID") || {
  echo "close-issue: failed to read current state for $ISSUE_ID" >&2
  exit 1
}
if [ "$current_state" != "$CLAUDE_PLUGIN_OPTION_DONE_STATE" ]; then
  linear issue update "$ISSUE_ID" --state "$CLAUDE_PLUGIN_OPTION_DONE_STATE" || {
    echo "close-issue: failed to transition $ISSUE_ID to $CLAUDE_PLUGIN_OPTION_DONE_STATE" >&2
    echo "  The feature branch has already been closed; retry the transition by hand:" >&2
    echo "    linear issue update $ISSUE_ID --state \"$CLAUDE_PLUGIN_OPTION_DONE_STATE\"" >&2
    exit 1
  }
fi
```

Direct `linear` CLI call — no delegation to a separate Linear-workflow skill. The `--json`-then-branch pattern preserves the "don't write if already there" guarantee that keeps Linear's activity feed clean.

## Step 8: Reap the worktree's codex broker, then remove the worktree

Last step. CWD is the main checkout, so worktree removal no longer threatens the session. Keeping it last means that if removal fails (dirty worktree, process holding files), the high-value state transitions — merge, push, branch delete, Linear Done — have already been applied cleanly.

**Reap first, then remove.** The codex plugin spawns an `app-server-broker.mjs` daemon per Claude Code session, scoped to that session's CWD. The broker only shuts down when `SessionEnd` fires cleanly — crashes, force-closes, or SIGKILL'd sessions leave it orphaned. `git worktree remove` doesn't notify the broker and the broker has no watchdog, so these leak until reaped. The upstream fix is an idle timeout / cwd watchdog in the plugin; delete this reap block once that ships.

Safety filter, three layers:

1. **`--cwd` exact match** (canonicalized via `pwd -P`) — only brokers rooted in this worktree.
2. **No live non-broker process rooted in the worktree** — catches any separate Claude Code session still active there (another terminal, IDE extension).
3. **SIGTERM, not SIGKILL** — lets the broker run its shutdown handler and cascade-stop its children.

```bash
# Canonicalize for reliable comparison (handles symlinks, trailing slashes).
WORKTREE_REAL=$(cd "$WORKTREE_PATH" && pwd -P)

# Layer 2 gate: any non-broker process whose cwd is at or below the worktree?
live_holders=$(
  lsof -a -d cwd -Fpn 2>/dev/null | awk -v w="$WORKTREE_REAL" '
    /^p/ { pid = substr($0, 2) }
    /^n/ { path = substr($0, 2); if (path == w || index(path, w"/") == 1) print pid }
  ' | sort -u | while read -r pid; do
    cmd=$(ps -p "$pid" -o command= 2>/dev/null)
    # Leading-paren patterns dodge the bash 3.2 parser bug with `case` in $(...).
    # The broker trio (broker.mjs + node codex wrapper + native codex binary)
    # all inherit the broker's cwd, so all three are reap targets, not blockers.
    case "$cmd" in
      (*app-server-broker.mjs*) ;;
      (*codex\ app-server*) ;;
      ('') ;;                       # process vanished between lsof and ps
      (*) printf '  %s %s\n' "$pid" "$cmd" ;;
    esac
  done
)

if [ -n "$live_holders" ]; then
  echo "WARNING: live processes rooted in $WORKTREE_REAL — skipping codex broker reap" >&2
  printf '%s\n' "$live_holders" >&2
else
  # Layer 1: brokers whose --cwd canonicalizes to our worktree.
  ps ax -o pid=,command= | grep 'app-server-broker\.mjs' | grep -v grep | \
    while read -r pid rest; do
      cwd=$(printf '%s\n' "$rest" | sed -n 's/.*--cwd \([^ ]*\).*/\1/p')
      [ -z "$cwd" ] && continue
      cwd_real=$(cd "$cwd" 2>/dev/null && pwd -P) || continue
      [ "$cwd_real" = "$WORKTREE_REAL" ] || continue
      echo "reaping codex broker $pid (cwd: $cwd_real)"
      kill -TERM "$pid" 2>/dev/null || true
    done
fi

git worktree remove "$WORKTREE_PATH"
```

**If removal fails:** Do NOT use `--force`. Check for:
- Uncommitted changes that slipped past pre-flight
- Untracked files that the pre-flight missed
- An editor or other process holding files open in the worktree
- A shell `cd`'d into the worktree

`--force` has destroyed work before; the failure is informational, not an obstacle to blast through.

## Final message

Print `$INTEGRATION_SUMMARY` if set (e.g., `merged to main @ abc1234 and pushed`, `PR opened: https://…`). Otherwise, a generic line:

```
$ISSUE_ID closed.
```

## Red Flags / When to Stop

- **Issue state is not `$CLAUDE_PLUGIN_OPTION_REVIEW_STATE`.** See Pre-flight §1 for the disposition map.
- **A `blocked-by` parent is not Done.** See Pre-flight §2. No `--force` override — the supported fix is to remove the Linear relation if the dependency has been resolved externally.
- **`close-branch` exits non-zero.** Stop. Do NOT run the Linear Done transition, stale-parent labeling, or worktree removal. The operator decides recovery from `close-branch`'s stderr diagnostic.
- **Branch not resolvable from issue ID.** Stop — the naming convention has drifted, or the branch is gone. Investigate before re-running.
- **`git worktree remove` fails.** Do NOT use `--force`. Diagnose the underlying cause.

## Portability

For a project to use `/close-issue`, it must:

1. Have the `sensible-ralph` plugin enabled (which bundles ralph-start; this skill sources its libs via `$CLAUDE_PLUGIN_ROOT`).
2. Provide a skill named exactly `close-branch` at its `.claude/skills/close-branch/`. The name is part of the contract; this skill invokes `Skill(close-branch)` without a discovery step.
3. Use ralph's worktree + Linear-lowercase-slug branch convention (sensible-ralph workflow invariants).
4. Have `$CLAUDE_PLUGIN_OPTION_FAILED_LABEL` and `$CLAUDE_PLUGIN_OPTION_STALE_PARENT_LABEL` set up in its Linear workspace (see the sensible-ralph README Prerequisites section).

If the project's `close-branch` leaves `$INTEGRATION_SHA` empty (e.g., opens a PR and doesn't merge), stale-parent labeling skips entirely — no breakage. Linear Done still transitions, and the final message uses whatever `$INTEGRATION_SUMMARY` `close-branch` provided.
