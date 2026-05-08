---
name: sr-implement
description: Dispatched by the ralph orchestrator to implement a single Linear issue autonomously inside a pre-created worktree. Do NOT auto-invoke.
disable-model-invocation: true
argument-hint: <issue-id>
allowed-tools: Skill, Bash, Read, Glob, Grep, Write, Edit, TodoWrite
---

# Ralph Implement

The workflow a single `claude -p` session runs when dispatched by the ralph orchestrator. Invoked with the Linear issue ID as the sole argument:

```
/sr-implement ENG-NNN
```

## Terminal action contract

This contract addresses one specific failure mode: emitting a
markdown summary as the session's final output **instead of**
performing one of the legal terminal actions below. It does NOT
redefine the skill's failure-handling policy. Hard infrastructure
failures (missing CLI, missing argument, irrecoverable conflicts)
exit the skill per the existing Red Flags / When to Stop section,
with whatever exit code that section's existing handlers
specify.

**The legal final actions of this skill are:**

1. **Success path** — invoke `/prepare-for-review` (Step 5). The handoff to the next skill IS this skill's completion.
2. **Blocking failure with `$ISSUE_ID` known** — post an escape-hatch Linear comment to that issue per the autonomous-mode preamble injected by the orchestrator, then exit. Exit code per the failure cause.
3. **Hard infrastructure failure or precondition stop** — exit per the existing Red Flags / When to Stop handlers (e.g., missing argument, unreachable Linear CLI). Exit code per those handlers, typically non-zero.

**The illegal final action is: writing a markdown summary**
("Changes", "Verification", "Tests Passing", etc.) **as the
session's last output without one of the above actions having
fired.** Sessions that end with a summary and no terminal
tool/skill call are misclassified by the orchestrator as
`exit_clean_no_review` — the issue is labeled `ralph-failed` and
DAG descendants are tainted. The session is not complete until
one of the three legal final actions runs.

If you have completed implementation work and feel the urge to
summarize, that is the exact decision point this contract
addresses: instead of writing a summary, invoke
`/prepare-for-review` (which posts a structured handoff comment as
part of its own Step 6 and IS the right place for that prose).

## Checklist

You MUST create a task for each of these items and complete them in order:

1. **Setup** — assign the invocation argument to `$ISSUE_ID`.
2. **Read the PRD** — `linear issue view "$ISSUE_ID" --json | jq -r .description`.
3. **Check for unresolved merge conflicts** — resolve any pre-merged-parent conflicts before implementing.
4. **Implement per the PRD** — TDD, smallest reasonable changes, scope discipline.
5. **Verify tests pass** — run the project's verification commands fresh and confirm pristine output.
6. **Invoke `/prepare-for-review`** — terminal handoff to the next skill in the autonomous flow. (See Terminal action contract above.)

The orchestrator has already `cd`-ed into the worktree, created the branch at the correct DAG base, written `.sensible-ralph-base-sha`, and transitioned the issue to `In Progress` before invoking. The steps below run inside that worktree.

## Setup: Assign the issue ID

Before running any of the steps below, assign the invocation argument to a shell variable so subsequent commands can reference it:

```bash
ISSUE_ID="<the argument you received, e.g. ENG-206>"
```

If the argument is missing or empty, stop and exit without invoking `/prepare-for-review`.

## Step 1: Read the PRD

```bash
linear issue view "$ISSUE_ID" --json | jq -r .description
```

The issue description is the spec. Treat it as the source of requirements.

## Step 2: Drain pending parent merges

The marker file `.sensible-ralph-pending-merges` is the authority for entering the drain loop. Three checks gate the flow:

```bash
[ -f .sensible-ralph-pending-merges ] && echo MARKER
git rev-parse -q --verify MERGE_HEAD && echo MERGING
git diff --name-only --diff-filter=U                   # unresolved index entries
```

Cases:

- **Marker absent, no MERGING, no UU/AA:** no drain work. Skip to Step 3.

- **Marker absent, but MERGING set OR UU/AA present:** the worktree is in an unresolved merge state but the state was NOT created by this feature (the helper would have written a marker alongside the merge). Do NOT auto-commit — this is unowned state. Treat as a red flag per Step 5: post a Linear comment ("worktree has unresolved merge state but `.sensible-ralph-pending-merges` is absent; this state was not produced by the orchestrator's parent-merge helpers and cannot be safely auto-resolved"), exit clean. Do NOT invoke `/prepare-for-review`.

  The UU/AA check is required because `git checkout --merge`, `git stash apply` with conflicts, and a few other operations can leave UU markers in the index without setting MERGE_HEAD. Catching both detectors prevents an unowned partial-merge state from silently slipping through to Step 3.

- **Marker present:** enter the drain loop. Marker presence proves the merge state belongs to this feature. Before calling the helper — and BEFORE any conflict resolution / commit, since those mutate the branch — validate the marker is **fully well-formed**:
  1. Every line (including would-be blank/whitespace-only lines) must match `^[0-9a-f]{40}( .*)?$` (40-char SHA optionally followed by a space and a display ref). Blank or whitespace-only lines fail this regex by construction; reject the marker if any line fails.
  2. Every SHA in column 1 must be reachable in this repo via `git cat-file -e <sha>^{commit}`. A syntactically valid but unreachable SHA (parent ref deleted+gc'd, repository repack lost the object) fails this check.

  If validation fails on any line, red-flag — do NOT invoke the helper, do NOT resolve conflicts, do NOT commit. Any of those would mutate the branch before discovering the corruption and leave the worktree in a worse state than where it started. The helper itself ALSO refuses zero-arg invocations when the marker is present (defense in depth — see `docs/design/worktree-contract.md` "Pending parent merges"), but fail-closed validation in the session is the primary guard because it triggers BEFORE any merge side effects. Run the loop below until the marker is gone.

### Drain loop

1. **Resolve unmerged files (if any).** If `git status` shows unmerged files (UU/AA), resolve each using `git diff`, the spec, and `git log <parent>..HEAD` to understand each side's intent. `git add` resolved files (do NOT commit yet — fall through to step 2).

2. **Finish any in-progress merge.** Check whether the worktree is in MERGING state:

   ```bash
   git rev-parse -q --verify MERGE_HEAD
   ```

   If this prints a SHA (exit 0), a merge is in progress and must be committed before the helper can run again. Run:

   ```bash
   git commit --no-edit
   ```

   This handles three crash-recovery cases:
   - Conflicts just resolved in step 1 → commit them now.
   - Conflicts resolved + staged in a prior session attempt but the session crashed before committing → MERGE_HEAD still exists, no UU/AA files; this commit completes the merge.
   - Resolution committed already → MERGE_HEAD does not exist; the `git rev-parse` returns non-zero, no commit needed.

   Skipping this step and going straight to the helper would invoke `git merge` on a worktree with MERGE_HEAD set, producing "fatal: You have not concluded your merge" → helper returns 1 → spurious red flag.

3. **Re-invoke the helper to drain remaining parents.** Pass the marker contents as args; the helper accepts SHAs uniformly with ref names:

   ```bash
   source "$CLAUDE_PLUGIN_ROOT/lib/worktree.sh"
   worktree_merge_parents "$PWD" $(awk '{print $1}' .sensible-ralph-pending-merges)
   ```

   The `awk '{print $1}'` extracts SHAs from the first column of the marker (display refs in column 2 are informational only).

   Possible outcomes:
   - Returns 0 and the marker file is gone → all parents merged. Proceed to Step 3.
   - Returns 0 and the marker file is still present → the next parent conflicted; loop back to step 1.
   - Returns 1 → genuine merge failure (parent SHA unreachable in repo, unexpected git error). Treat as a red flag per Step 5: post a Linear comment, do NOT invoke `/prepare-for-review`.

Keep looping (resolve → finish-merge → re-invoke) until the marker file is gone. Each conflict resolution is a separate commit and shows up in the `/prepare-for-review` diff for reviewer awareness.

## Step 3: Implement per the PRD

Follow your project's conventions: TDD, systematic debugging on failures, smallest reasonable changes. The PRD drives the scope. If the `superpowers` plugin is installed, prefer its `test-driven-development` and `systematic-debugging` skills; otherwise apply the equivalent discipline directly.

Before moving to Step 4, cross-check your implementation against the PRD:
- Every deliverable in the PRD's scope section is implemented.
- Nothing is implemented that the PRD did not ask for.
- Any decisions made mid-implementation that the PRD did not specify are recorded (either inline in the code, in the commit messages, or via `capture-decisions`).

If you find in-scope items missing, loop back. If you find out-of-scope work, revert it — unless it is a minimal, behavior-preserving mechanical fix directly implied by the PRD (e.g., a missing import). The carve-out does NOT extend to changes to public interfaces, shared types, persistence schemas, config shapes, or files outside the immediate implementation; any of those, route through the escape hatch. If PRD completion appears to require substantial out-of-scope functionality, that is a scope deviation: invoke the escape hatch (post a Linear comment describing the gap, do NOT invoke `/prepare-for-review`). Do not self-justify out-of-scope additions as "needed for the in-scope work." See the autonomous-mode preamble the orchestrator injected at session start for the escape-hatch behavior.

## Step 4: Verify tests pass

If `superpowers:verification-before-completion` is installed, invoke it to gate the claim that tests pass. Otherwise: run the project's verification commands fresh (not from memory), read the exit codes and output, and confirm pristine output per the project's testing rules (see CLAUDE.md "Testing" section).

If verification does not pass cleanly, fix the issue — do not suppress, skip, or delete tests. If the issue cannot be resolved within the session, treat as a red flag per Step 5 and do NOT invoke `/prepare-for-review`.

## Step 5: Invoke `/prepare-for-review` (conditional)

**This is the skill's terminal action.** The next thing you emit MUST be the `/prepare-for-review` invocation (or, on a failure path, the escape-hatch Linear comment), NOT a summary message. See the Terminal action contract at the top of this skill.

If Steps 3–4 succeeded, invoke `/prepare-for-review`. That skill runs the doc sweep, decisions capture, codex review, posts the handoff comment, and transitions Linear to `In Review`.

If any step failed, do NOT invoke `/prepare-for-review`. Leave the Linear issue in `In Progress`. The orchestrator's post-dispatch state check classifies this as `exit_clean_no_review` (labels `ralph-failed`, taints downstream issues) — that's the correct operator signal.

## Red flags / when to stop

Stop the session WITHOUT invoking `/prepare-for-review` if:

- The `$ISSUE_ID` argument is missing.
- The PRD is empty or clearly malformed.
- Merge conflicts from pre-merged parents can't be resolved confidently.
- Tests fail and can't be fixed within the session.
- The `linear` CLI is unreachable (can't read the PRD).

Never invoke `/prepare-for-review` to "complete" a session that didn't actually succeed. The skill itself guards against this, but act on the red flags here first — the `exit_clean_no_review` outcome is the correct signal.
