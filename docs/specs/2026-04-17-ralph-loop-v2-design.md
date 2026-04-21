# Ralph Loop v2: Autonomous Spec-Queue Orchestrator with Branch DAG Awareness

**Linear issue:** ENG-176
**Date:** 2026-04-17 (revised after first review)
**Supersedes:** ENG-151 (see `2026-04-15-spec-queue-orchestrator-design.md` for point-in-time v1 thinking)

## Problem

Decouple the phases of a development session so that pre-approved work can run while the user is away from the desk, and review happens interactively on return. v1 established this pattern but made two assumptions that no longer hold:

1. **Each worktree branches from main.** An issue could only be dispatched once its blockers were *merged*, not just *ready*. A chain of dependent tickets couldn't make forward progress overnight — only the root could run; everything else waited for a human review-and-merge in the morning.
2. **Implementation requires heavy scaffolding.** v1 assumed a two-artifact model (durable spec + pre-written plan) and detailed prompting. With Opus 4.7 as the executor and auto mode available, less handholding is warranted — the question is *how much less.*

v2 addresses both and defines a **load-bearing contract** for what the autonomous session consumes. This contract blocks experimentation on upstream tools (brainstorming, plan-writing) because those tools produce the contract's input.

## Design Decisions

### 1. Single artifact: PRD-style brief in the Linear issue description

The autonomous session consumes **one artifact**: the PRD written into the Linear issue's description field.

**Rationale:**
- Most community workflows (`mattpocock/skills`, `snarktank/ralph`, aider, cursor) use a single artifact. The spec+plan split in superpowers was older-model-era scaffolding.
- The PRD is *ephemeral execution scaffolding* — not a durable design record. It doesn't belong in `docs/specs/` (which is for design thinking and alternatives) or `docs/decisions/` (which is for ADRs). The Linear issue description is its natural home: one canonical location, editable without a worktree, already the issue's source of truth.
- Zero file lifecycle. No temp files to clean up, no branch pollution, no drift between "issue description" and "brief on disk."
- Large architectural work can still produce a durable spec in `docs/specs/`; the issue description then summarizes it or links to it. The orchestrator doesn't need to know which case it's in — it just reads the description.

### 2. Minimal prompt template; trust CLAUDE.md and skill descriptions

> **Superseded by ENG-206** — see `2026-04-21-ralph-implement-skill-design.md`. The prompt template described below was replaced by a dispatched skill, `ralph-implement`, in April 2026. The rationale and tradeoffs captured here remain useful as a point-in-time record.

The prompt template given to each `claude -p` invocation:

```
You are implementing Linear issue $ISSUE_ID ($ISSUE_TITLE) autonomously.
The PRD is in the issue description — read it via Linear.
Branch: $BRANCH_NAME, worktree: $WORKTREE_PATH.
The worktree has been pre-created at the correct base branch. If you see
unresolved merge conflicts from parent branches in `git status`, resolve
them before implementing the feature.
When implementation is done and tests pass, invoke /prepare-for-review.
```

**Branch and worktree are deterministic at prompt-rendering time.** Both are pre-computed by the orchestrator *before* `claude -p` is invoked:

- Branch name comes from Linear's auto-generated slug (`eng-190-foo`) — known from the issue.
- Worktree path is `<repo>/.worktrees/<branch>` — matches chezmoi's existing convention and the primary preference of `superpowers:using-git-worktrees` (project-local, `.gitignore`d). The orchestrator does **not** use `claude --worktree`; see the dispatch detail below.
- The orchestrator runs `git worktree add <path> -b <branch> <base>` with the DAG-chosen base (main, parent's branch, or integration-merge branch) *before* dispatch. `claude -p` is then invoked with the worktree as its cwd (via subshell `cd`), not via `--worktree`. The `--worktree` flag is a *create* flag that branches off `HEAD` into `<repo>/.claude/worktrees/<name>/` — it can't accept a pre-created path and has no DAG/integration-merge awareness, so it does not fit this orchestrator's needs.
- For dependent tickets this is the same mechanism — the base branch changes (parent's branch instead of main), but the substitution still happens before the prompt is rendered.

**Rationale for minimal prompt:**
- Opus 4.7 reliably self-invokes skills based on CLAUDE.md conventions and skill descriptions. Duplicating the sequence in the prompt creates drift risk when skills evolve.
- The wrap-up sequence (`update-stale-docs`, `capture-decisions`, `prune-completed-docs`, `codex-review-gate`, `linear-workflow`) lives inside `prepare-for-review` (Decision 3). The prompt just names the entry point.

### 3. New skill `prepare-for-review` wraps the handoff checklist

A new global skill, `prepare-for-review`, is the entry point for "implementation is done, ready to hand off to human review." It runs, in order:

1. `update-stale-docs`
2. `capture-decisions`
3. `prune-completed-docs`
4. `codex-review-gate` (iterating on findings, may modify code)
5. **Post a Linear comment** containing:
   - A **review summary** — what was done, any surprises or deviations from the PRD.
   - A **QA test plan** — the manual checks that matter for this work: what to click, what to verify, which edge cases the agent worked around. This closes a review-time gap — the agent that wrote the code knows the risky paths; capturing them at handoff is the cheap moment.
6. Move the issue via `linear-workflow`: `In Progress → In Review`.

**Rationale:**
- Separates *phase-generic polish* (this skill) from *project-specific integration* (branch-closing skills — see Decision 4). The polish sequence is the same across projects; the merge ritual isn't.
- Useful in interactive sessions too — anytime the user finishes implementing a feature, `/prepare-for-review` ensures docs/decisions/review are complete before handoff.
- The name is deliberately descriptive of its outcome, not tied to superpowers' `-ing` gerund convention.

**Creation is out of scope for this ticket.** ENG-176 specifies the contract (what the skill does, what it inputs/outputs); a follow-up ticket creates the skill itself.

### 4. Branch closing moves to project-local skills

The superpowers `finishing-a-development-branch` skill is dropped from the user's active workflow. Each project defines its own branch-closing skill tailored to that project's merge ritual (main-only vs. dev/staging/main cascade, tag conventions, etc.).

**Rationale:**
- Merge rituals differ per project; a global skill either over-generalizes or picks an arbitrary default. Project-local skills encode exact conventions.
- Closing is a separate *phase* from polishing. Mixing test/review/code-change work into a "finishing" skill conflates completion with integration.

**Restructure / replacement of `finishing-a-development-branch` is out of scope for this ticket.** Spin off as per-project follow-ups. An example `close-feature-branch` skill may eventually serve as a reference.

### 5. New Linear state: "Approved"

A new state, **Approved**, is added to the ENG team between Todo and In Progress.

**State machine:**

```
Backlog → Todo → Approved → In Progress → In Review → Done
                                              ↓
                                         (Canceled / Duplicate)
```

- **Todo:** actionable, but no PRD yet.
- **Approved:** PRD written into issue description; signals "ready for autonomous pickup."
- **In Progress:** orchestrator dispatched a session for this issue.
- **In Review:** session completed `prepare-for-review`; awaiting the user's interactive review + branch close.
- **Done:** the user merged via project-local closing skill.

**Rationale:**
- Clean semantics carried by the state machine, not overloaded labels. Linear's board view makes the queue immediately visible.
- `In Review` already exists and maps exactly to the v2 pickup rule's "Review" state.
- Adding one state is a one-time Linear config change.

**Exception label:**

- `ralph-failed` — autonomous session exited non-zero; the user decides retry/cancel/debug.

(Stale-parent detection moves out of the orchestrator and into a separate post-commit-hook mechanism — see Follow-up Tickets. It's a review-time concern, not a dispatch-time one.)

### 6. Pickup rule (strict) + pre-flight sanity scan

An issue is **strictly pickup-ready** when **all** of:

1. State is `Approved`.
2. No `ralph-failed` label.
3. Every `blocked-by` issue is either (a) in `Done` or `In Review`, OR (b) in `Approved` AND a member of this run's queue. **Canceled blockers are *not* counted as resolved.**

**Why exclude Canceled:** Cancellation is a judgment call — something was deemed not worth doing. An issue whose parent was canceled shouldn't silently proceed; the dependency relationship may no longer be meaningful. The user's intervention is warranted.

**Why same-run Approved blockers count:** A depth-N chain of Approved issues should run end-to-end in a single overnight session — otherwise only the chain root makes progress per run, defeating v2's stated goal of keeping chains moving. Rule 3b evaluates blocker state *anticipating post-dispatch transitions*: toposort guarantees an Approved parent dispatches before its child, and the parent's session transitions it to `In Review` via `/prepare-for-review` before the child's dispatch begins. By the time `dag_base` actually runs for the child, the parent is effectively `In Review`. An Approved blocker that is NOT in the run's queue (ralph-failed-labeled, in another project, or otherwise filtered out) cannot clear this run and does NOT satisfy rule 3b.

**Pre-flight sanity scan** — before entering the dispatch loop, `/run-queue` looks for anomalies and asks the user to clarify before proceeding. Anomalies include:

- Issue has a `Canceled` blocker (warrants human re-evaluation — keep, cancel, or edit dependencies?).
- Issue has a `Duplicate` blocker (similar — resolve the duplication relationship first).
- Blocker is itself Approved but not yet In Review/Done, and no chain resolves it — circular or deeply stuck dependency.
- Issue is marked Approved but lacks a PRD in the description. Operationalized as `< 200 non-whitespace characters`; the threshold is a heuristic, tune if we see false positives (short-but-valid PRDs) or false negatives (long-but-empty descriptions).

On each anomaly, the scan pauses with a description and asks the user what to do. Only after the scan passes does the dispatch loop begin.

### 7. Branch DAG awareness

When dispatching issue `B` whose blockers are `{A1, A2, ...}`:

| Blocker state | Base branch for B |
|---|---|
| No blockers, or all blockers merged (`Done`) | `main` |
| One blocker in `In Review`, rest `Done` | That blocker's branch |
| Multiple blockers in `In Review` | **Integration merge** (see below) |

The table reads blocker state *at B's dispatch time*, not queue-construction time. An Approved-blocker-in-queue (rule 3b of Decision 6) has already transitioned to `In Review` by the time B is dispatched — toposort guarantees parents go first, and the parent's session runs `/prepare-for-review` before exiting. So the three rows above cover every pickup-ready case; no separate Approved-blocker row is needed.

**Multi-parent integration merge:**

The orchestrator attempts to merge the in-review parents sequentially in B's pre-created worktree. Outcomes differ by parent count:

- **Clean merge (single or multi-parent):** worktree is ready; agent implements the feature normally.
- **Single-parent conflict:** worktree has unresolved conflicts; agent resolves during dispatch (the prompt template tells it to check `git status` first). Opus 4.7 with auto mode can reason about standard merge conflicts — it has access to both parent branches via git log/diff.
- **Multi-parent conflict:** orchestrator aborts the merge and records `setup_failed` (see `docs/decisions/2026-04-20-ralph-v2-multi-parent-integration-abort.md`). Git's MERGING state forbids continuing through the parent list after a first conflict — the only tractable implementation is fail-fast. Operator resolves manually (merge one parent to main, re-sequence, etc.) before re-queuing.

```bash
# Orchestrator:
git worktree add .worktrees/eng-B-slug -b eng-B-slug main
cd .worktrees/eng-B-slug
git merge <parent-A1-branch>  # single parent: may conflict (agent resolves)
git merge <parent-A2-branch>  # multi-parent: abort on any conflict (see decision doc)
# Clean: proceed directly to feature work.
```

**Rationale for agent-resolution (single-parent case):**
- The orchestrator can't reason about conflicts (it's a bash script); an agent can.
- v1 would have skipped B and blocked progress; v2's whole point is keeping chains moving.
- The worst case is the agent gets the merge wrong — which then surfaces during the user's review, same as any merge done by a developer.

For the multi-parent case, v2 accepts a partial regression to v1-like "skip on conflict" behavior. Conflicts between two already-approved parents are rare in practice; when they occur, the structural problem (overlapping scope) deserves human resolution, not an agent's best guess across parents it can't fully see.

### 8. Failure handling: skip downstream, continue independents

When a session fails (non-zero exit from `claude -p`):

1. Add `ralph-failed` label to the issue.
2. Leave Linear state as `In Progress` (the user resolves).
3. Mark the issue's transitive DAG descendants as *blocked* for this run (don't dispatch them).
4. Continue dispatching issues that are **not** downstream of the failure.

**Rationale:**
- v1's stop-on-failure was conservative but contradicts the whole v2 pitch ("let independent work proceed in parallel chains"). If A fails and C is independent of A, there's no reason to stop C.
- Skipping the failed issue's *downstream* is conservative where it matters — we don't blindly build on top of failed work.

### 9. Auto mode (not `--dangerously-skip-permissions + sandbox`)

Each dispatched `claude -p` invocation runs in **auto mode** (Opus 4.7's autonomous-execution capability). Auto mode proceeds on low-risk work without permission prompts but still declines destructive or high-risk operations.

**Rationale:**
- Auto mode replaces v1's `--dangerously-skip-permissions` + OS-level sandbox combo. It's risk-aware (respects a high-risk-confirmation contract) where the sandbox was uniformly-permissive-but-isolated. Trade-off: no OS-level isolation, but a much more considered permission model.
- No `--max-budget-usd` — sessions run to completion. Budget enforcement via monitoring, not mid-session kill.
- No sandbox config needed — auto mode's permission model handles risk gating.

**New failure class: permission-prompt deadlock.** If the agent asks permission on an action auto mode doesn't auto-approve and the user isn't at the desk, the session blocks. This is a real operational risk; resolution options are in Open Questions.

### 10. Carried over from v1 (unchanged)

- **Fresh instance per spec** — each issue gets its own `claude -p` invocation with a clean context window.
- **Local execution** — orchestrator runs locally, not on Anthropic's cloud Routines.
- **Custom bash script** — deterministic orchestration (sort, dispatch, track); no LLM-driven orchestration.
- **Sequential dispatch within a DAG layer** — parallelism is a v3 concern.
- **Resumable sessions** — each session named `ENG-XXX: title` for `claude --resume` when the user reviews.
- **`progress.json` per run** — human-readable audit trail.
- **Plugin with slash-command entry point** — `/run-queue` is the user's trigger.
- **No PR creation, no automated merging** — the loop stops at "In Review"; closing is human-driven.

**Removed from v1:** sandbox flag (replaced by auto mode), `--max-budget-usd` (no budget cap), adapter-pattern abstraction (YAGNI — inline Linear calls).

## Architecture

### Workflow

```
┌─────────────────────────────────────────────────────┐
│                  WHILE AT DESK                       │
│                                                      │
│  Brainstorm (ENG-178 tool)                           │
│    → PRD written into Linear issue description       │
│    → Issue state moves to Approved                   │
│  (repeat; set blocked-by dependencies explicitly)    │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│                  WHILE AWAY                          │
│                                                      │
│  /run-queue                                          │
│    ├─ PRE-FLIGHT SANITY SCAN                         │
│    │   ├─ Canceled-parent anomalies → ask the user       │
│    │   ├─ Missing PRD on Approved issues             │
│    │   └─ Circular/stuck dependencies                │
│    ├─ Query: state=Approved, no ralph-failed,        │
│    │         every blocker Done / In Review / same-  │
│    │         run Approved (Decision 6 rule 3)        │
│    ├─ Topological sort                               │
│    ├─ Show dispatch plan; confirm                    │
│    └─ For each ready spec (sequential):              │
│        ├─ dag_base() → main | parent | integration   │
│        ├─ git worktree add .worktrees/<branch>       │
│        ├─ For integration: sequential git merges     │
│        │   single-parent conflict → agent resolves   │
│        │   multi-parent conflict → abort + taint     │
│        ├─ Linear: Approved → In Progress             │
│        ├─ (cd $worktree && claude -p --name auto)    │
│        │   • Session reads PRD from Linear           │
│        │   • Session implements, runs TDD            │
│        │   • Session invokes /prepare-for-review     │
│        │   • /prepare-for-review runs polish chain,  │
│        │     posts QA-plan comment, moves to Review  │
│        ├─ On non-zero exit: label ralph-failed,      │
│        │   taint downstream this run                 │
│        └─ Append to progress.json                    │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│                  WHEN BACK                           │
│                                                      │
│  For each In Review issue:                           │
│    Read QA plan (Linear comment)                     │
│    cd .worktrees/eng-XXX                             │
│    claude --resume "ENG-XXX: title" (if available)   │
│    Manual review per QA plan                         │
│    Iterate → /<project-local-closing-skill>          │
│                                                      │
│  For each ralph-failed issue:                        │
│    cd .worktrees/eng-XXX                             │
│    Debug interactively → retry or cancel             │
│                                                      │
│  (stale-parent-labeled issues, if any, surfaced by   │
│   the post-commit hook — see Follow-up Tickets)      │
└─────────────────────────────────────────────────────┘
```

### Components

#### 1. Slash command entry point: `/run-queue`

`disable-model-invocation: true` skill. The user runs before stepping away. Responsibilities:

1. Read config (project, model, worktree base).
2. **Pre-flight sanity scan** (see Decision 6). Find anomalies, stop and ask the user before proceeding.
3. Query Linear for strict pickup-ready issues; topological sort.
4. Dry-run preview: show queue, base-branch choices, where integration merges will happen.
5. Ask the user to confirm.
6. Invoke `orchestrator.sh` with the approved queue.

The queue is **fixed at invocation time**. New Approved issues added mid-run are not pulled in until the next `/run-queue`. The "run" in "run-queue" captures this — one invocation processes one queue.

#### 2. Orchestrator script: `orchestrator.sh`

Processes the ordered queue sequentially. Per issue:

```
base       = dag_base(issue)           # "main" | parent-branch | {integration, parents}
worktree   = .worktrees/$branch        # relative to repo root (orchestrator cwd)
session    = "$ISSUE_ID: $ISSUE_TITLE"

# Pre-create worktree at correct base. Setup-step failures (branch lookup,
# dag_base, worktree creation, .ralph-base-sha write, Linear state transition)
# are caught per-issue and recorded as outcome: "setup_failed" with a
# failed_step identifier, then the loop continues with the next queued issue.
# Pre-existing worktree path or branch at the target location emits
# outcome: "local_residue" WITHOUT mutating Linear — the issue is healthy;
# only the local environment needs operator cleanup.
if base is integration:
    git worktree add $worktree -b $branch main
    for parent_branch in base.parents:
        git -C $worktree merge $parent_branch
        # Single parent with conflict: leave in-place; agent resolves.
        # Multi-parent with conflict: abort + record setup_failed. See
        # `docs/decisions/2026-04-20-ralph-v2-multi-parent-integration-abort.md`
        # for why git semantics forbid "leave and continue" across multiple parents.
else:
    git worktree add $worktree -b $branch $base

# Linear: Approved → In Progress
linear issue update $issue --state "In Progress"

# Dispatch (auto mode) — cwd = worktree; NOT --worktree (that flag is create-only).
(cd $worktree && claude -p \
    --name "$session" \
    --permission-mode auto \
    "$prompt" \
    2>&1 | tee ralph-output.log)

# Classify outcome (see Outcome Model below and the decision doc for
# `local_residue` + `unknown_post_state` rationale).
post_state, state_fetch_ok = linear_get_issue_state(issue)  # may fail transiently

if exit_code == 0 and not state_fetch_ok:
    outcome = "unknown_post_state"          # no label, no taint
elif exit_code == 0 and post_state == review_state:
    outcome = "in_review"                   # success
elif exit_code == 0:
    outcome = "exit_clean_no_review"        # auto mode refused something; taint
    linear issue label add $issue ralph-failed
    tainted.add_transitive_descendants_of(issue)
else:
    outcome = "failed"                      # non-zero exit; taint
    linear issue label add $issue ralph-failed
    tainted.add_transitive_descendants_of(issue)

progress.append({issue, branch, base, outcome, exit_code, duration, run_id, ...})

# Skip any issue whose id is in `tainted`
```

Continues until the queue is empty or all remaining issues are tainted.

##### Outcome model

Six outcomes. The spec's original two-outcome model (`in_review` / `failed`) proved insufficient once implementation surfaced three ambiguities: (a) `claude -p --permission-mode auto` can exit 0 without transitioning state when it refuses a permission-gated operation; (b) pre-dispatch setup can fail in ways that are distinct from session failures; (c) local environment residue and transient Linear read failures must not be collapsed to `failed`, because they'd mutate Linear state for issues the orchestrator never actually touched or successfully dispatched.

| Outcome | Classification rule | `ralph-failed` label | Taints descendants |
|---|---|---|---|
| `in_review` | exit 0 AND post-state == review_state | no | no |
| `exit_clean_no_review` | exit 0 AND post-state != review_state | yes | yes |
| `failed` | exit != 0 | yes | yes |
| `setup_failed` | pre-dispatch setup step failed (branch lookup, dag_base, worktree create, base-sha write, Linear state transition) | yes | yes |
| `local_residue` | target path or branch pre-existed at start of dispatch | **no** | **no** |
| `unknown_post_state` | exit 0 AND post-state fetch failed transiently | **no** | **no** |

`local_residue` and `unknown_post_state` are the only outcomes that deliberately leave Linear untouched and descendants un-tainted. Rationale in `docs/decisions/2026-04-20-ralph-v2-ambiguous-outcome-handling.md` — briefly, in both cases the orchestrator cannot distinguish a real failure from operator state (residue) or a transient API blip (unknown), so mutating Linear would destroy correct work in the false-positive direction.

#### 3. Topological sort: `toposort.sh`

Kahn's algorithm over `blocked-by` relations. Output order respects: dependencies first, Linear priority as tiebreaker.

#### 4. DAG base-branch selection: `dag_base.sh`

```
function dag_base(issue):
    blockers = linear blocked-by relations
    review_parents = [b for b in blockers if b.state == "In Review"]

    if not review_parents:
        return "main"
    if len(review_parents) == 1:
        return review_parents[0].branch_name
    return {"type": "integration", "parents": review_parents}
```

Integration bases trigger the in-worktree sequential merges shown in Component 2.

#### 5. Linear interaction (inline, no adapter)

Linear CLI calls are inline in `orchestrator.sh` and `/run-queue`. YAGNI on the adapter pattern — hard-code Linear until a second task source appears.

Operations:

- **Query** pickup-ready issues: `linear issue query --state Approved --project "$PROJECT" ...`.
- **Read blockers**: `linear_get_issue_blockers "$ID"` (in `scripts/lib/linear.sh`) — uses `linear api` (GraphQL); `linear issue view --json` does not expose relations.
- **State transitions**:
  - Orchestrator: `Approved → In Progress` at dispatch.
  - Session (via `/prepare-for-review` → `linear-workflow`): `In Progress → In Review` on success.
- **Labels**: orchestrator adds `ralph-failed` on non-zero exit.
- **Comments**: pre-flight anomalies noted as comments; QA plan + review summary posted by `/prepare-for-review`.
- **Branch names**: Linear's auto-generated `eng-XXX-slug`.

**Note:** The `/linear-workflow` skill currently assumes human-in-the-loop invocation. Using it inside an autonomous session may conflict with the orchestrator's state changes. Audit and adjustment is filed as a follow-up ticket (see Follow-up Tickets).

#### 6. Progress file: `progress.json`

Human-readable run summary. Not used by the orchestrator for resumption (queues are fresh each run).

Each orchestrator invocation appends one record per issue to a flat JSON array at the repo root. Records from the same run share a `run_id` (ISO 8601 UTC timestamp captured once at orchestrator start); consumers group by `run_id` for per-run analysis. The flat layout (rather than a nested `{"runs":[{...}]}` wrapper) keeps append-only writes trivial to implement atomically via `jq ... | mv` and keeps the schema stable across orchestrator versions.

```json
[
    {
        "issue": "ENG-190",
        "branch": "eng-190-foo",
        "base": "main",
        "outcome": "in_review",
        "exit_code": 0,
        "duration_seconds": 2710,
        "timestamp": "2026-04-17T22:30:00Z",
        "run_id": "2026-04-17T22:30:00Z"
    },
    {
        "issue": "ENG-192",
        "outcome": "skipped",
        "timestamp": "2026-04-17T22:45:00Z",
        "run_id": "2026-04-17T22:30:00Z"
    }
]
```

Outcome-specific fields carried on each record:

- `in_review`, `exit_clean_no_review`, `failed`, `unknown_post_state`: `branch`, `base`, `exit_code`, `duration_seconds`.
- `setup_failed`: `failed_step` (the setup step that failed — `linear_get_issue_branch`, `dag_base`, `worktree_create_at_base`, `write_base_sha`, `linear_set_state`, etc.).
- `local_residue`: `residue_path`, `residue_branch`.
- `skipped`: no extra fields — `issue`, `outcome`, `timestamp`, `run_id` only.

No parent-HEAD tracking — staleness detection is a post-commit-hook concern, not the orchestrator's.

#### 7. Configuration: `config.json`

```json
{
    "project": "Agent Config",
    "approved_state": "Approved",
    "review_state": "In Review",
    "failed_label": "ralph-failed",
    "worktree_base": ".worktrees",
    "model": "opus",
    "stdout_log_filename": "ralph-output.log",
    "prompt_template": "You are implementing Linear issue $ISSUE_ID ($ISSUE_TITLE) autonomously.\nThe PRD is in the issue description — read it via Linear.\nBranch: $BRANCH_NAME, worktree: $WORKTREE_PATH.\nThe worktree has been pre-created at the correct base branch. If you see unresolved merge conflicts from parent branches in `git status`, resolve them before implementing the feature.\nWhen implementation is done and tests pass, invoke /prepare-for-review."
}
```

### Plugin structure

```
spec-queue/
├── PLUGIN.md
├── skills/
│   └── run-queue/
│       └── SKILL.md              # /run-queue entry point
├── scripts/
│   ├── orchestrator.sh           # Dispatch loop
│   ├── toposort.sh               # Topological sort
│   ├── dag_base.sh               # Base-branch selection
│   └── preflight_scan.sh         # Pre-flight anomaly detection
└── config.example.json
```

## Contract summary (for ENG-177 / ENG-178 consumption)

Upstream tools (brainstorming, plan-writing) must produce:

1. **A Linear issue** in the configured project, in state `Approved`.
2. **A PRD written into the issue description.** Format is not rigidly prescribed — any markdown that gives Opus 4.7 enough context to implement without further human input. ENG-177 and ENG-178 experiment with the recommended shape.
3. **Explicit `blocked-by` relations** for any prerequisite issues. The orchestrator uses these for DAG ordering and base-branch selection. **v2 scope limit:** blocker relations are resolved only within the configured project. Cross-project `blocked-by` edges are returned by Linear but fail the "Approved blocker must be in this run's queue" membership check, so cross-project parents appear stuck in preflight. Multi-project dispatch is designed in `2026-04-21-ralph-scope-model-design.md` (ENG-205) and implemented via ENG-215; once ENG-215 lands, the scope is a project list (or initiative shorthand) declared in per-repo `.ralph.json`, and blockers within any in-scope project resolve automatically. ENG-203 was canceled as subsumed.

That's the entire input contract. Everything downstream (branch name, worktree path, session name) is derived by the orchestrator from the Linear issue.

## Out of scope for this ticket

- **Creating the `prepare-for-review` skill.** Follow-up ticket.
- **Refactoring / replacing `finishing-a-development-branch`** into project-local closing skills. Follow-up tickets per project.
- **Post-commit hook for stale-parent detection.** Review-time concern, not a ralph-loop concern. Follow-up ticket.
- **Auditing `/linear-workflow` for autonomous-session compatibility.** Follow-up ticket.
- **Parallel dispatch within a DAG layer.** v3 extension.
- **Retry logic.** Human-driven after `ralph-failed`.
- **PR creation / automated merging.** Explicit non-goal.
- **Remote / cloud execution.** Local-only for v2.
- **Non-Linear task sources.** Inline Linear calls; add an adapter when a second source materializes.

## Follow-up tickets (to file after approval)

1. **Implement ralph loop v2** (the plugin itself) — consumes this design.
2. **Create `prepare-for-review` skill** — includes QA-test-plan generation and Linear comment posting (Decision 3).
3. **Add "Approved" state to ENG team in Linear** (one-time config, can happen independently).
4. **Audit `/linear-workflow` skill** for autonomous-session compatibility (Component 5 note).
5. **Post-commit hook for stale-parent detection** — fires on parent branch amendment during review; labels any In-Review children with `stale-parent`. Not ralph-loop scope.
6. **Project-local `close-feature-branch` skill** (per active project; example in chezmoi as reference).

ENG-177 and ENG-178 are already filed as upstream-tool experiments; they consume the contract defined here.

## Open questions (resolved during implementation)

All five open questions below were resolved as ENG-184 landed. Resolutions are preserved inline so a reader of this spec can trace the design's uncertain branches without cross-referencing the plan/progress docs.

1. **Auto-mode CLI flag for `claude -p`.** **Resolved:** `claude --permission-mode auto`. `claude auto-mode defaults` prints the built-in classifier rules as JSON. Reference: https://code.claude.com/docs/en/permission-modes#eliminate-prompts-with-auto-mode.

2. **Permission-prompt deadlock in auto mode.** **Resolved empirically (ENG-184):** `--permission-mode auto` *refuses and continues* rather than blocking. A prohibited operation surfaces as a tool-result denial; the session reports and exits 0 with the work incomplete. Implication: exit code alone does NOT imply success — the orchestrator classifies by exit code AND post-dispatch Linear state. The `exit_clean_no_review` outcome (see Component 2's outcome model) captures the "exit 0 but never reached In Review" case, labels the issue `ralph-failed`, and taints descendants — same treatment as a non-zero exit.

3. **Session persistence horizon.** **Resolved:** `~/.claude/projects/` persists conversation history indefinitely with no GC; `claude --resume` remains available for any prior session. `progress.json` needs no expiration guards. The review-time diff + Linear QA comment + worktree context are still the primary review inputs; session resume is a convenience that happens to always be available.

4. **`/run-queue` naming.** **Resolved:** `/ralph-start`. Skill lives at `agent-config/skills/ralph-start/`. The "start" framing emphasizes the user's action (kick off an overnight run) over the loop's internal queue semantics.

5. **Integration-merge cleanup.** **Resolved:** No cleanup needed — the merge happens inside B's real worktree (not a throwaway one). If B ships, parent merges are absorbed into main; if B is abandoned, normal worktree hygiene removes it.
