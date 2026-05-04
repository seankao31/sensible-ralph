# sensible-ralph

Autonomous overnight execution of Approved Linear issues — with review
gates, worktree isolation, a DAG scope model, and Linear as the state
machine.

A Claude Code plugin that extends the ralph technique
([Geoff Huntley's original](https://ghuntley.com/ralph/)) with five
properties the name is a nod to.

## The five pillars

1. **Safety** — every session hands off to a review gate before anything
   merges. Worktree isolation keeps parallel sessions from stepping on
   each other. The DAG model won't dispatch two children of the same
   In-Review parent concurrently. *Vanilla ralph ships straight to main.*

2. **Structure** — three phases (spec → plan → impl) with three skills
   (`/sr-spec`, `/sr-start`, `/sr-implement`). A DAG scope model
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
- **Three workspace-scoped Linear labels**, one-time setup per workspace.
  Names are plugin-configurable; the defaults are `ralph-failed`,
  `stale-parent`, and `ralph-coord-dep`:
  ```bash
  linear label create --name ralph-failed --color '#EB5757' \
    --description 'Orchestrator dispatched this issue but it did not reach the review state.'
  linear label create --name stale-parent --color '#F2994A' \
    --description 'In-Review issue whose blocked-by parent was amended after dispatch.'
  linear label create --name ralph-coord-dep --color '#9B51E0' \
    --description 'Has at least one coord-dep blocked-by edge auto-added by the /sr-spec scan; cleared on /close-issue.'
  ```
- **Per-repo `.sensible-ralph.json`** at the repo root declaring which Linear
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
  /.sensible-ralph/
  /.worktrees/
  ralph-output.log
  ```
  If you're upgrading from a version that wrote these artifacts at the
  repo root, run `mkdir -p .sensible-ralph && mv progress.json ordered_queue.txt .sensible-ralph/ 2>/dev/null` once at your consumer repo's root.

  (The paths match the plugin defaults. If you changed the `worktree_base`
  or `stdout_log_filename` userConfig values, substitute accordingly.)

## Usage

End-to-end operator flow is in [`docs/usage.md`](docs/usage.md).
Subsystem design docs live in [`docs/design/`](docs/design/); per-ticket
implementation specs in [`docs/specs/`](docs/specs/); captured decisions
in [`docs/decisions/`](docs/decisions/).

Brief summary:

- **`/sr-spec`** — turn an idea into an Approved Linear issue. Runs
  a brainstorming dialogue, lazily creates the issue's per-issue
  branch+worktree after design approval, writes a spec to
  `docs/specs/<topic>.md` on that branch, runs an adversarial codex
  review of the spec, updates the Linear issue, and transitions it to
  Approved. The branch+worktree persist until `/close-issue` merges them.
- **`/sr-start`** — dispatch the queue. Collects pickup-ready Approved
  issues, sorts them by blocked-by relations, previews the plan, and
  hands control to the orchestrator. The orchestrator creates worktrees,
  invokes `claude -p` sessions, and classifies outcomes.
- **`/sr-status`** — read-only mid-run status. Prints a Done / Running /
  Queued table for the latest ralph run from `.sensible-ralph/progress.json` and
  `.sensible-ralph/ordered_queue.txt`. Zero side effects, no network calls.
- **`/sr-implement`** — invoked INSIDE a dispatched session; reads the
  Linear issue as its spec and implements it end-to-end up to
  `/prepare-for-review`.
- **`/prepare-for-review`** — handoff ritual at the end of an
  implementation session (doc sweep, decisions capture, codex review,
  Linear comment, state transition to In Review).
- **`/close-issue`** — Linear-side close ritual after the user reviews
  In-Review work. Delegates VCS integration to a project-local
  `close-branch` skill (not bundled — see below).

## Companion skills

The plugin bundles six skills: `sr-spec`, `sr-start`, `sr-status`,
`sr-implement`, `prepare-for-review`, and `close-issue` (in roughly
the order they show up across an issue's lifecycle). A few external
skills extend the flow:

**Required for the consumer repo:**

- A project-local **`close-branch`** skill at `.claude/skills/close-branch/`.
  This is the project-specific VCS integration — base branch, rebase policy,
  merge strategy, push model, branch-delete semantics. `close-issue`
  invokes it via `Skill(close-branch)` without a discovery step, so the
  skill name is part of the contract. sensible-ralph intentionally
  doesn't bundle one — every project's merge ritual is different.

**Recommended plugin companions:**

- **Superpowers** ([obra/superpowers](https://github.com/obra/superpowers))
  — provides implementation discipline: `test-driven-development`,
  `systematic-debugging`, `verification-before-completion`, and
  `using-git-worktrees`. Referenced by `sr-implement` (for TDD,
  debugging, and verification) and by `close-issue` / the orchestrator
  (for worktree conventions). If superpowers isn't installed, those
  steps degrade gracefully (skip with a note, or fall back to manual
  equivalents).
- **Codex plugin** ([openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc))
  — provides cross-model review primitives: the `codex-rescue` agent
  and the `/rescue` / `/review` commands. The autonomous preamble in
  `sr-start` references `codex-rescue` for stuck-session recovery.
  Install this if you rely on the orchestrator.

**Referenced but not bundled** — these are invoked by name from
inside the bundled skills (specific callers noted per bullet) and
degrade gracefully when missing, but their absence is not free:

- `update-stale-docs`, `capture-decisions`, `prune-completed-docs` —
  the doc-sweep / decision-capture / doc-prune steps inside
  `/prepare-for-review` (Steps 1–3). Skipping them weakens the
  traceability pillar; the handoff still happens, just with thinner
  durable artifacts.
- `codex-review-gate` — the cross-model review gate run by `/sr-spec`
  (adversarial spec review) and `/prepare-for-review` (Step 5, before
  handoff to In Review). Skipping this in autonomous sessions silently
  weakens the safety pillar — the orchestrator will still merge work
  that no second model has looked at. Operators relying on the
  orchestrator should make sure this skill is available.

For reference shapes of these four skills, see Sean's personal
agent-config dotfiles:
[`seankao31/dotfiles/agent-config`](https://github.com/seankao31/dotfiles/tree/main/agent-config).
They're not packaged as an installable plugin; you'll need to
adapt the SKILL.md files into your own `~/.claude/skills/` setup
(or fork them into a project-local `.claude/skills/`).

## Design notes

- `/sr-implement` runs inside an autonomous session dispatched by
  `/sr-start`. The orchestrator prepends a preamble to the session
  prompt that overrides your CLAUDE.md rules requiring human input —
  those become "post a Linear comment and exit clean" instead. See
  `skills/sr-start/scripts/autonomous-preamble.md`.

## License

MIT. See [`LICENSE`](LICENSE).
