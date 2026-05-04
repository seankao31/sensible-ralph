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

## Step 2: Check for unresolved merge conflicts

```bash
git status --short
```

If the orchestrator pre-merged a parent branch into this worktree, the merge may have left conflicts. Resolve them before implementing the feature. Use `git log --all --oneline` and `git diff` to reason about each parent.

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
