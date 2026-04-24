---
name: ralph-implement
description: Dispatched by the ralph orchestrator to implement a single Linear issue autonomously inside a pre-created worktree. Do NOT auto-invoke.
disable-model-invocation: true
argument-hint: <issue-id>
allowed-tools: Skill, Bash, Read, Glob, Grep, Write, Edit
---

# Ralph Implement

The workflow a single `claude -p` session runs when dispatched by the ralph orchestrator. Invoked with the Linear issue ID as the sole argument:

```
/ralph-implement ENG-NNN
```

The orchestrator has already `cd`-ed into the worktree, created the branch at the correct DAG base, written `.ralph-base-sha`, and transitioned the issue to `In Progress` before invoking. The steps below run inside that worktree.

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

## Step 2: Check for unresolved merge conflicts

```bash
git status --short
```

If the orchestrator pre-merged a parent branch into this worktree, the merge may have left conflicts. Resolve them before implementing the feature. Use `git log --all --oneline` and `git diff` to reason about each parent.

## Step 3: Implement per the PRD

Follow agent-config conventions: TDD (via `superpowers:test-driven-development`), `superpowers:systematic-debugging` on failures, smallest reasonable changes. The PRD drives the scope.

Before moving to Step 4, cross-check your implementation against the PRD:
- Every deliverable in the PRD's scope section is implemented.
- Nothing is implemented that the PRD did not ask for.
- Any decisions made mid-implementation that the PRD did not specify are recorded (either inline in the code, in the commit messages, or via `capture-decisions`).

If you find in-scope items missing, loop back. If you find out-of-scope work, revert it — unless it is a minimal, behavior-preserving mechanical fix directly implied by the PRD (e.g., a missing import). The carve-out does NOT extend to changes to public interfaces, shared types, persistence schemas, config shapes, or files outside the immediate implementation; any of those, route through the escape hatch. If PRD completion appears to require substantial out-of-scope functionality, that is a scope deviation: invoke the escape hatch (post a Linear comment describing the gap, do NOT invoke `/prepare-for-review`). Do not self-justify out-of-scope additions as "needed for the in-scope work." See `agent-config/CLAUDE.md` `## Autonomous mode` / `### Overrides` for the escape-hatch behavior.

## Step 4: Verify tests pass

Invoke `superpowers:verification-before-completion` to gate the claim that tests pass. Run the project's verification commands fresh (not from memory), read the exit codes and output, and confirm pristine output per the project's testing rules (see CLAUDE.md "Testing" section).

If verification does not pass cleanly, fix the issue — do not suppress, skip, or delete tests. If the issue cannot be resolved within the session, treat as a red flag per Step 5 and do NOT invoke `/prepare-for-review`.

## Step 5: Invoke `/prepare-for-review` (conditional)

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
