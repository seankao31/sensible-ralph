# sensible-ralph

Autonomous overnight execution of Approved Linear issues — with review
gates, worktree isolation, a DAG scope model, and Linear as the state
machine.

A Claude Code plugin that extends the ralph technique
([Geoff Huntley's original](https://ghuntley.com/ralph/)) with five
properties the name is a nod to. Named in ironic contrast with the Ralph
Wiggum character, who famously lacks them.

## The five pillars

1. **Safety** — every session hands off to a review gate before anything
   merges. Worktree isolation keeps parallel sessions from stepping on
   each other. The DAG model won't dispatch two children of the same
   In-Review parent concurrently. *Vanilla ralph ships straight to main.*

2. **Structure** — three phases (spec → plan → impl) with three skills
   (`/ralph-spec`, `/ralph-start`, `/ralph-implement`). A DAG scope model
   instead of a flat checklist. Linear's workflow states are the state
   machine — not a `progress.txt` blob. *Vanilla ralph hands the loop a
   markdown file and walks away.*

3. **Traceability** — every iteration ties to a Linear issue. Decisions,
   specs, progress logs, and dispatch records are durable artifacts in
   the filesystem and in Linear. *Vanilla ralph remembers via a single
   mutable `progress.txt`.*

4. **Composability** — skills are swappable. The orchestrator dispatches
   whichever implementation skill you point it at; the spec skill and
   orchestrator don't care what lives at the end of the pipe. *Vanilla
   ralph is a fixed bash script.*

5. **Deliberation** — idea → PRD → plan → code are separate phases.
   Thinking happens before the loop starts, so the autonomous implementer
   is executing a decided design, not figuring one out. *Vanilla ralph
   hands the LLM a blob and lets it discover the scope as it goes.*

### How this compares to other ralph variants

- [`snarktank/ralph`](https://github.com/snarktank/ralph) is PRD-file-
  centric — a `prd.json` plus a `passes: true/false` terminal gate.
  No dependency graph, no issue-tracker integration, no review phase.
- [`frankbria/ralph-claude-code`](https://github.com/frankbria/ralph-claude-code)
  is ops-heavy — rate-limiting, circuit breakers, tmux monitoring — but
  still drives off a flat task file with no structural deliberation.

Neither has DAG scoping, Linear as the state machine, or a review gate
as the terminal state.

## Installation

This plugin ships as a self-marketplace (the repo is both marketplace
and plugin). Inside Claude Code:

```
/plugin marketplace add seankao31/sensible-ralph
/plugin install sensible-ralph@sensible-ralph
```

At install time Claude Code will prompt for the plugin's userConfig
values (workflow state names, label names, worktree base directory,
model, log filename). All have sensible defaults; accepting them gets
you a working setup.

## Prerequisites

- **Linear CLI** ([`schpet/linear-cli`](https://github.com/schpet/linear-cli))
  authenticated against your workspace (`linear --version` succeeds).
- **`jq`** on PATH.
- **Two workspace-scoped Linear labels**, one-time setup per workspace.
  Names are plugin-configurable; the defaults are `ralph-failed` and
  `stale-parent`:
  ```bash
  linear label create --name ralph-failed --color '#EB5757' \
    --description 'Orchestrator dispatched this issue but it did not reach the review state.'
  linear label create --name stale-parent --color '#F2994A' \
    --description 'In-Review issue whose blocked-by parent was amended after dispatch.'
  ```
- **Per-repo `.ralph.json`** at the repo root declaring which Linear
  projects this repo's sessions drain. Two shapes:
  ```jsonc
  // Explicit — one or more projects
  { "projects": ["Project A", "Project B"] }

  // Shorthand — Linear initiative, expanded to its member projects on every run
  { "initiative": "My Initiative Name" }
  ```
- **`.gitignore` entries** for the runtime artifacts the orchestrator
  writes to your repo root and worktrees:
  ```gitignore
  /.ralph/
  /.worktrees/
  ralph-output.log
  ```
  If you're upgrading from a version that wrote these artifacts at the
  repo root, run `mkdir -p .ralph && mv progress.json ordered_queue.txt .ralph/ 2>/dev/null` once at your consumer repo's root.

  (The paths match the plugin defaults. If you changed the `worktree_base`
  or `stdout_log_filename` userConfig values, substitute accordingly.)

## Usage

End-to-end operator flow is in [`docs/usage.md`](docs/usage.md).
Subsystem design docs live in [`docs/design/`](docs/design/); per-ticket
implementation specs in [`docs/specs/`](docs/specs/); captured decisions
in [`docs/decisions/`](docs/decisions/).

Brief summary:

- **`/ralph-spec`** — turn an idea into an Approved Linear issue. Runs
  a brainstorming dialogue, writes a spec to `docs/specs/<topic>.md` in
  your repo, updates the Linear issue, and transitions it to Approved.
- **`/ralph-start`** — dispatch the queue. Collects pickup-ready Approved
  issues, sorts them by blocked-by relations, previews the plan, and
  hands control to the orchestrator. The orchestrator creates worktrees,
  invokes `claude -p` sessions, and classifies outcomes.
- **`/ralph-status`** — read-only mid-run status. Prints a Done / Running /
  Queued table for the latest ralph run from `.ralph/progress.json` and
  `.ralph/ordered_queue.txt`. Zero side effects, no network calls.
- **`/ralph-implement`** — invoked INSIDE a dispatched session; reads the
  Linear issue as its spec and implements it end-to-end up to
  `/prepare-for-review`.
- **`/prepare-for-review`** — handoff ritual at the end of an
  implementation session (doc sweep, decisions capture, codex review,
  Linear comment, state transition to In Review).
- **`/close-issue`** — Linear-side close ritual after the user reviews
  In-Review work. Delegates VCS integration to a project-local
  `close-branch` skill (not bundled — see below).

## Companion skills

The plugin bundles the four skills that sit in the critical path of
the ralph lifecycle: `ralph-start`, `ralph-spec`, `ralph-implement`,
`prepare-for-review`, and `close-issue`. A few external skills extend
the flow:

**Required for the consumer repo:**

- A project-local **`close-branch`** skill at `.claude/skills/close-branch/`.
  This is the project-specific VCS integration — base branch, rebase policy,
  merge strategy, push model, branch-delete semantics. `close-issue`
  invokes it via `Skill(close-branch)` without a discovery step, so the
  skill name is part of the contract. sensible-ralph intentionally
  doesn't bundle one — every project's merge ritual is different.

**Recommended companions:**

- **Superpowers plugin** ([obra/superpowers](https://github.com/obra/superpowers))
  — provides `test-driven-development`, `systematic-debugging`,
  `verification-before-completion`, `using-git-worktrees`,
  `capture-decisions`, `prune-completed-docs`, `update-stale-docs`,
  `clean-branch-history`. Referenced by `ralph-implement` (for
  implementation discipline) and by `prepare-for-review` (for its doc
  steps). If superpowers isn't installed, those steps degrade gracefully
  (skip with a note, or fall back to manual equivalents).
- **Codex plugin** ([openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc))
  — provides `codex-rescue` and `codex-review-gate`. `codex-review-gate`
  is the review gate that `prepare-for-review` runs before handoff; it's
  a load-bearing piece of the safety pillar in autonomous sessions.
  Install this if you rely on the orchestrator.

## Design notes

- `/ralph-start` and `/ralph-spec` are **user-triggered** entry points
  (`disable-model-invocation: true`). Don't auto-invoke either.
- `/ralph-implement` runs inside an autonomous session dispatched by
  `/ralph-start`. The orchestrator prepends a preamble to the session
  prompt that overrides your CLAUDE.md rules requiring human input —
  those become "post a Linear comment and exit clean" instead. See
  `skills/ralph-start/scripts/autonomous-preamble.md`.

## Version

`0.1.0` — evolving. The workflow design has stabilized through several
iterations, but expect breaking changes before `1.0.0`.

## License

MIT. See [`LICENSE`](LICENSE).
