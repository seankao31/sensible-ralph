# Ralph v2 Usage

End-user playbook for the autonomous spec-queue orchestrator (`/ralph-start`). For design details see `agent-config/docs/specs/2026-04-17-ralph-loop-v2-design.md`; for the SKILL contract see `agent-config/skills/ralph-start/SKILL.md`.

## Producing Approved issues

Approved issues are the input to `/ralph-start`. The canonical way to produce one is `/ralph-spec` — a brainstorming skill that runs the dialogue, writes the spec to `docs/specs/<topic>.md`, overwrites the Linear issue description with the approved spec (preserving the prior description as a comment), sets any `blocked-by` relations identified during design, and transitions the issue to the configured `approved_state`. Invoke `/ralph-spec` with an existing issue ID to populate a pre-filed ticket, or without arguments to create one at the end. Other paths to Approved are fine too — hand-editing a description and toggling state works — but `/ralph-spec` is the one that guarantees the ralph input contract is satisfied.

## When to run `/ralph-start`

Run it before stepping away from the desk — typically end-of-day or before a long break — when there are one or more Linear issues in the **Approved** state, across the projects declared in `<repo-root>/.ralph.json` (either a `projects: [...]` list or an `initiative: "..."` shorthand that expands on every invocation), with a complete PRD (≥200 non-whitespace chars). Workflow fields (state names, labels, worktree base, model) still live in the global `agent-config/skills/ralph-start/config.json`; scope is the only field that moved to the per-repo file. An issue's blockers are "resolved enough to dispatch" when every blocker is Done, In Review, or **Approved and also in this run's queue** — which means **an entire chain of Approved issues can run end-to-end overnight in a single session**: the orchestrator dispatches the root first; that session completes and moves the root to In Review; then the child dispatches against the parent's branch; and so on down the chain. You don't need to wait for each level to be reviewed before kicking off the next. Blocker chains (`blocks` / `blocked by` relations) are traced across any project in scope — a Machine Config issue blocked by an Agent Config issue clears automatically when both are in `.ralph.json` — but a blocker whose project is *outside* the scope trips the **out-of-scope blocker** preflight anomaly, which points back at `.ralph.json` as the fix. The orchestrator dispatches a `claude -p --permission-mode auto` session per issue in DAG-aware order; expect roughly 5–15 minutes of wall time per issue depending on scope. The skill is invoked manually (`disable-model-invocation: true`) and pauses for explicit confirmation after the dispatch preview, so it never auto-runs and never dispatches a queue you haven't seen. Invoke it from a `bash` session anywhere inside the repo — main checkout or a linked worktree both work. Concurrent `/ralph-start` sessions in *different* repos are safe by construction (disjoint repo roots → disjoint `progress.json`, worktree dirs, and queue files); concurrent runs in the *same* repo are not supported.

## What to expect in the morning

Inspect `progress.json` at the repo root — it lists every issue the orchestrator touched in this run, keyed by `run_id` (ISO 8601 UTC). Each record has an `outcome` field. **`in_review`** means the session completed cleanly and `/prepare-for-review` transitioned the issue (review the worktree, then invoke `/close-issue ENG-NNN` from a fresh session at the main-checkout root to merge — not from inside the worktree). **`failed`** and **`exit_clean_no_review`** mean the issue is labeled `ralph-failed` and downstream dependents were tainted with **`skipped`** outcomes — `cd` into the worktree, read `<worktree>/ralph-output.log` for the session's final output, then decide whether to retry (remove the `ralph-failed` label and re-queue), cancel the issue, or debug interactively. **`setup_failed`** means the orchestrator never got as far as dispatching `claude -p` (branch lookup, dag_base, worktree creation step, etc., recorded in `failed_step`); cleanup ran for state this invocation created. Two outcomes leave Linear untouched and descendants un-tainted because the orchestrator can't tell that anything actually went wrong: **`local_residue`** means the target worktree path or branch already existed at the start of dispatch (operator state — manual mkdir, in-flight branch, prior crashed run); the residue is preserved untouched at `residue_path` / `residue_branch`, clean it up by hand and re-queue. **`unknown_post_state`** means claude exited 0 but the post-dispatch Linear state fetch failed transiently; open the issue in Linear and check whether the session actually reached In Review (success) or stopped short (re-queue). Triage `ralph-failed` and `local_residue` issues before kicking off the next ralph run, otherwise the same blockers will keep tainting (or no-op-skipping) their dependents on every dispatch.

## Autonomous mode overrides

Behavioral overrides for autonomous-mode sessions (a `claude -p` session
dispatched by `/ralph-start`). For interactive mode, the rules in
`agent-config/CLAUDE.md` apply as written. Rules in CLAUDE.md marked
`(autonomous: see playbook)` are mapped here.

### The escape hatch

When you would normally STOP and ask Sean, do this instead: **post a Linear
comment to the issue you're implementing describing what's blocking, then
exit clean (no PR, no In Review transition).** The orchestrator records this
as `exit_clean_no_review` in `progress.json`; Sean triages on the next pass.

### Enumerated exit triggers

Exit clean (per above) when you hit any of these:

- **Architectural deviation** — a fundamentally different approach than the
  spec described, or a cross-cutting change (auth, schema, build config) when
  the spec was about a feature.
- **Scope deviation** — adding or removing functionality vs what the spec
  specified.
- **Throwing away or rewriting an existing implementation** beyond what the
  spec directs.
- **Backward compatibility** — any backcompat shim or rename-with-alias.
- **Spec contradicts the code** — the spec describes a state of the world
  that doesn't match what's there, in a way you can't reconcile.
- **Stuck** — same operation tried 3 times without progress, or ≥30 minutes
  of compute on the same subgoal without convergence.
- **Setup gap** — repo isn't initialized, uncommitted changes present, or
  any precondition the orchestrator should have established but didn't.

### Default to exit on uncertainty

When you can't classify a decision as routine vs architectural, treat as
architectural and exit clean. Wasted overnight cycles are cheaper than
wrong-direction overnight cycles.

### Per-rule mapping

Rules in CLAUDE.md flagged with `(autonomous: see playbook)`:

**Exit clean** (per the escape hatch above):

- *Communication*: "speak up when you don't know" / "STOP and ask for
  clarification" / "STOP and ask for help" / "We discuss architectural
  decisions together"
- *Proactiveness*: "Only pause to ask for confirmation when [list]" — every
  condition in the list becomes an exit-clean condition.
- *Writing code*: "NEVER throw away or rewrite implementations" / "approval
  before backward compatibility"
- *Version Control*: "STOP and ask permission to initialize" / "STOP and
  ask how to handle uncommitted changes"
- *Testing*: "raise the issue with Sean [for failing test deletion]"

**Comment and continue:**

- *Testing*: "warn Sean about [mocked-behavior tests]" — leave a Linear
  comment noting the finding; continue with the spec's work (unless the
  spec is about those tests).

**Don't do it in autonomous mode:**

- *Linear authorization*: "confirm before deleting issues or comments" —
  never delete issues or comments in autonomous mode.

### Things that still apply

Linear authorization (edit descriptions, comment, change state, manage
labels, file new issues, set relations on the dispatched issue and judged-
relevant issues) applies fully — the escape hatch leans on this. Codex
usage (codex-rescue, codex-review-gate) applies fully — `/prepare-for-review`'s
codex gate runs from the autonomous session.
