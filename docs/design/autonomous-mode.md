# Autonomous mode

How the orchestrator overrides `CLAUDE.md`'s human-input rules for the
duration of one unattended `claude -p` session.

## The problem the preamble solves

`CLAUDE.md` is written for an interactive session — a human at the
keyboard who can answer "should I do X?" Many of its rules require
that human: "STOP and ask Sean", "get explicit approval", "push back
when you disagree", "discuss architectural decisions before
implementing". In an unattended `claude -p` session those rules
deadlock the loop. The session has no one to ask, no one to confirm
with, and no way to escalate; obeying the rule literally means hanging
or making up an answer.

The preamble is a per-session override layer. For every class of rule
that requires human input, it substitutes a single safe, non-blocking
fallback the autonomous session can actually execute: post a Linear
comment describing what's blocking, then exit clean. The unblocking
conversation moves to Linear, where the operator picks it up on the
next pass.

## How the preamble is delivered

The preamble lives at `skills/sr-start/scripts/autonomous-preamble.md`.
The orchestrator reads that file and prepends its contents to the
`claude -p` prompt, immediately followed by a blank line and the
`/sr-implement <issue-id>` invocation. The full prompt is constructed
in `skills/sr-start/scripts/orchestrator.sh` around the line
`local prompt="${preamble}"$'\n\n'"/sr-implement $issue_id"`. The
session sees the preamble as the first content of its conversation.

Two mechanics are deliberate:

- **Prepended at dispatch time, not embedded in `sr-implement`'s
  `SKILL.md`.** SKILL.md is loaded *after* the session starts, so any
  decision the model makes between session start and skill load would
  otherwise run without autonomous-mode rules. Prepending puts the
  rules in context from token zero.
- **Not an edit to any `CLAUDE.md` file.** Per-repo `CLAUDE.md` and
  the user's global `~/.claude/CLAUDE.md` are unchanged. The override
  is ephemeral — it exists only inside the dispatched subprocess's
  prompt.

## What the preamble overrides

The umbrella substitution covers every `CLAUDE.md` rule that requires
human input:

> Post a Linear comment on the issue you're implementing describing
> what's blocking, then exit clean (no PR, no `In Review` transition).

The preamble enumerates two phrasing patterns that count as "requires
human input":

- **Escalation phrasings** — "STOP and ask", "speak up", "call out",
  "push back", "raise the issue".
- **Gating requirements** — confirmation, approval, permission,
  discussion before proceeding.

Three concrete mappings, drawn from the most common rule classes in
the user's global `CLAUDE.md`:

| `CLAUDE.md` rule | Autonomous-mode behavior |
|---|---|
| "STOP and ask for clarification rather than making assumptions" | Post a Linear comment describing the unclear point; exit clean. |
| "STOP and ask how to handle uncommitted changes or untracked files when starting work" | Treat the worktree state as the starting point — the orchestrator pre-created it. If the orchestrator pre-merged a parent branch and left conflicts, resolve them before implementing (per `sr-implement` Step 2); no escalation needed. |
| "We discuss architectural decisions together before implementation" | Implement the design as the PRD specifies. If the PRD does not specify, or if implementation requires deviating from it, the escape hatch fires — post a comment, exit clean. |

When a decision's class is unclear, the preamble's default is to take
the escape hatch. The preamble names categories that **never** count
as routine and always require escape: architectural choices (framework
swaps, major refactoring, system design), backward-compatibility
additions, rewrites, significant restructures of existing code, and
scope changes beyond the spec.

Linear authorization is fully retained — the session may freely edit
descriptions, comment, change state, manage labels, file new issues,
and set relations on the dispatched issue and any judged-relevant
issue. The escape hatch leans on this; posting the comment is itself
an authorized Linear write. Issue and comment **deletion** is the one
Linear write that remains forbidden in autonomous mode — deletes lose
the history that the operator needs to triage the failure.

`codex-rescue` and `codex-review-gate` apply fully when installed.
The codex review gate inside `/prepare-for-review` runs from the
autonomous session the same as it does interactively.

## The escape hatch

The escape hatch is the universal exit path for any blocked autonomous
session:

1. Post a Linear comment on the dispatched issue describing the
   block — what was attempted, what stopped progress, and what the
   operator needs to decide.
2. Exit the session cleanly. Do **not** invoke `/prepare-for-review`.
   Do **not** transition the issue to `In Review`. Leave the issue in
   `In Progress`.

The orchestrator's post-dispatch state check sees `exit 0 + In Progress`
and classifies the run as `exit_clean_no_review`. That outcome applies
the `ralph-failed` label to the issue, taints the issue's transitive
DAG descendants for the rest of the run, and surfaces the failure for
operator triage on the next pass. The full classification rule and
operator triage flow live in `docs/design/outcome-model.md`
(forthcoming, ENG-291).

## Operational rules with no interactive counterpart

Two preamble rules exist only because no human is watching to notice
them — they have no analogue in interactive `CLAUDE.md`:

- **Spec contradicts the code.** If the PRD describes a state of the
  world that does not match the codebase in a way the session cannot
  reconcile (a file the spec says to edit doesn't exist, a function it
  references has a different signature, a prerequisite it assumes is
  missing), treat that as a spec bug, not an implementation puzzle.
  Post a comment and exit clean.
- **Stuck.** If the same operation has been tried 3 times without
  progress, or ≥30 minutes of compute have been spent on the same
  subgoal without convergence, post a comment and exit clean. Fresh
  context (and a human) is cheaper than compounding a confused
  approach.

Both reduce to the same mechanical exit as the umbrella rule —
the trigger is what's distinct.

## Scope of the override

The preamble is in effect **only for the dispatched session** — the
duration of the one `claude -p` invocation the orchestrator's loop
spawned. Once that subprocess exits, the preamble has no further
effect. Each new dispatch starts a fresh session that re-prepends the
preamble's current contents.

Interactive sessions — a user at the keyboard invoking `/sr-spec`,
`/sr-start`, `/prepare-for-review`, `/close-issue`, or any ad-hoc
`claude` invocation — do **not** load the preamble. They follow
`CLAUDE.md` as written, including all its human-input gates. The user
is present to answer them.

## What does not change

The preamble overrides only the human-input-gating rules. The rest of
`CLAUDE.md`'s implementation discipline carries over to the autonomous
session unchanged:

- TDD for every new feature or bugfix.
- Systematic debugging — find root causes, never patch symptoms.
- Smallest reasonable change to achieve the desired outcome.
- No mocks in end-to-end tests.
- No deletion of failing tests.
- Pristine test output as a passing condition.
- Conventional Commit message style.
- The "Unit of Work" rule — code, docs, and comments updated in the
  same pass.

The autonomous session is still expected to produce the same quality
of code an interactive session would. The preamble removes the things
the session cannot do (consult a human), not the things it can do
without one.

## See also

- `skills/sr-start/scripts/autonomous-preamble.md` — the literal
  preamble text the orchestrator prepends. Single source of truth for
  the override rules; this doc is a synthesis.
- `skills/sr-implement/SKILL.md` — Step 3 references the escape hatch
  for in-flight scope deviations; Step 5 enforces the "no
  `/prepare-for-review` on failure" gate that produces
  `exit_clean_no_review`.
- `docs/design/outcome-model.md` (forthcoming, ENG-291) — the
  `exit_clean_no_review` outcome classification, the `ralph-failed`
  label, descendant tainting, and operator triage flow.
- `docs/design/orchestrator.md` (forthcoming, ENG-291) — where in the
  dispatch loop the preamble is read and prepended, and how the
  resulting prompt is handed to `claude -p`.
- `~/.claude/CLAUDE.md` "Autonomous mode" section — the global
  fallback for non-`sensible-ralph` autonomous dispatches that this
  preamble extends with plugin-specific rules.
