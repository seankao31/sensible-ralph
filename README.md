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
  /progress.json
  /ordered_queue.txt
  /.worktrees/
  ralph-output.log
  ```
  (The paths match the plugin defaults. If you changed the `worktree_base`
  or `stdout_log_filename` userConfig values, substitute accordingly.)

## Usage

End-to-end operator flow is in [`docs/usage.md`](docs/usage.md).
Architectural designs live in [`docs/specs/`](docs/specs/); decisions
that outlived the designs live in [`docs/decisions/`](docs/decisions/).

Brief summary:

- **`/ralph-spec`** — turn an idea into an Approved Linear issue. Runs
  a brainstorming dialogue, writes a spec to `docs/specs/<topic>.md` in
  your repo, updates the Linear issue, and transitions it to Approved.
- **`/ralph-start`** — dispatch the queue. Collects pickup-ready Approved
  issues, sorts them by blocked-by relations, previews the plan, and
  hands control to the orchestrator. The orchestrator creates worktrees,
  invokes `claude -p` sessions, and classifies outcomes.
- **`/ralph-implement`** — invoked INSIDE a dispatched session; reads the
  Linear issue as its spec and implements it end-to-end up to
  `/prepare-for-review`.

## Design notes

- `/ralph-start` and `/ralph-spec` are **user-triggered** entry points
  (`disable-model-invocation: true`). Don't auto-invoke either.
- `/ralph-implement` runs inside an autonomous session dispatched by
  `/ralph-start`. The orchestrator prepends a preamble to the session
  prompt that overrides your CLAUDE.md rules requiring human input —
  those become "post a Linear comment and exit clean" instead. See
  `skills/ralph-start/scripts/autonomous-preamble.md`.
- The plugin assumes a handful of general-purpose skills are available:
  `linear-workflow`, `codex-review-gate`, `prepare-for-review`,
  `clean-branch-history`, `using-git-worktrees`. Install those from
  their own plugins; sensible-ralph doesn't bundle them.

## Version

`0.1.0` — evolving. The workflow design has stabilized through several
iterations, but expect breaking changes before `1.0.0`.

## License

MIT. See [`LICENSE`](LICENSE).
