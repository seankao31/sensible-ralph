# Ralph Loop v2: Autonomous Spec-Queue Orchestrator with Branch DAG Awareness

**Linear issue:** ENG-176
**Date:** 2026-04-17
**Supersedes:** ENG-151 (see `2026-04-15-spec-queue-orchestrator-design.md` for point-in-time v1 thinking)

## Problem

Decouple the phases of a development session so that pre-approved work can run while Sean is away from the desk, and review happens interactively on return. v1 established this pattern but made two assumptions that no longer hold:

1. **Each worktree branches from main.** This means an issue can only be dispatched once its blockers are *merged*, not just *ready*. A chain of dependent tickets can't make forward progress overnight — only the root can run; everything else waits for a human review-and-merge in the morning.
2. **Implementation requires heavy scaffolding.** v1 assumed a two-artifact model (durable spec + pre-written plan) and detailed prompting. With Opus 4.7 as the executor, less handholding is warranted — the question is *how much less.*

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

The prompt template given to each `claude -p` invocation is intentionally minimal:

```
You are implementing Linear issue $ISSUE_ID ($ISSUE_TITLE) autonomously.
The PRD is in the issue description — read it via Linear.
Branch: $BRANCH_NAME, worktree: $WORKTREE_PATH.
When implementation is done and tests pass, invoke /prepare-for-review.
```

**Rationale:**
- Opus 4.7 reliably self-invokes skills based on CLAUDE.md conventions and skill descriptions. Duplicating the sequence in the prompt creates drift risk when skills evolve.
- The sequence of wrap-up skills (`update-stale-docs`, `capture-decisions`, `prune-completed-docs`, `codex-review-gate`, `linear-workflow`) lives inside the `prepare-for-review` skill (see Decision 3). The prompt just names the entry point.
- Users who want different behavior (e.g., skip decision capture for trivial fixes) can override via per-run config without touching the core template.

### 3. New skill `prepare-for-review` wraps the handoff checklist

A new global skill, `prepare-for-review`, is the entry point for "implementation is done, ready to hand off to human review." It runs:

1. `update-stale-docs`
2. `capture-decisions`
3. `prune-completed-docs`
4. `codex-review-gate` (iterating on findings, may modify code)
5. `linear-workflow` to move the issue to In Review

**Rationale:**
- Separates *phase-generic polish* (this skill) from *project-specific integration* (branch-closing skills — see Decision 4). The polish sequence is the same across projects; the merge ritual isn't.
- Useful in interactive sessions too — anytime Sean finishes implementing a feature, `/prepare-for-review` ensures docs/decisions/review are complete before handoff.
- The name is deliberately descriptive of its outcome (work becomes review-ready) rather than tied to superpowers' `-ing` gerund convention.

**Creation is out of scope for this ticket.** ENG-176 specifies the contract (what the skill does, what it inputs/outputs); a follow-up ticket creates the skill itself.

### 4. Branch closing moves to project-local skills

The superpowers `finishing-a-development-branch` skill is dropped from Sean's active workflow. Each project defines its own branch-closing skill tailored to that project's merge ritual (main-only vs. dev/staging/main cascade, tag conventions, etc.).

**Rationale:**
- Merge rituals differ per project; a global skill either over-generalizes or picks an arbitrary default. Project-local skills encode exact conventions.
- Closing is a separate *phase* from polishing. Mixing test/review/code-change work into a "finishing" skill conflates completion with integration.

**Restructure / replacement of `finishing-a-development-branch` is out of scope for this ticket.** Spin off as a separate follow-up per project.

### 5. New Linear state: "Approved"

A new state, **Approved**, is added to the ENG team between Todo and In Progress.

**State machine:**

```
Backlog → Todo → Approved → In Progress → In Review → Done
                                              ↓
                                         (Canceled / Duplicate)
```

- **Todo:** actionable, but no PRD yet.
- **Approved:** PRD written into issue description; blockers (if any) are being worked or already merged. Signals "ready for autonomous pickup."
- **In Progress:** orchestrator dispatched a session for this issue.
- **In Review:** session completed `prepare-for-review`; awaiting Sean's interactive review + branch close.
- **Done:** Sean merged via project-local closing skill.

**Rationale:**
- Clean semantics carried by the state machine, not overloaded labels. Linear's board view makes the queue immediately visible.
- `In Review` already exists (position 1002, "started" type) and maps exactly to the v2 pickup rule's "Review" state.
- Adding one state is a one-time Linear config change.

**Exception labels:**

- `ralph-failed` — autonomous session exited non-zero; Sean decides retry/cancel/debug.
- `stale-parent` — parent branch amended after child dispatched; child may need rebase during review.

### 6. Pickup rule

An issue is pickup-ready when **all** of:

1. State is `Approved`.
2. No `ralph-failed` label (retries are a human decision).
3. All `blocked-by` issues are in `Done`, `In Review`, or `Canceled`.

**Canceled blocker = resolved blocker.** If Sean cancels an issue, it's no longer blocking. The downstream child may still be meaningful (if not, Sean cancels it too); the orchestrator doesn't judge.

### 7. Branch DAG awareness

When dispatching issue `B` whose blockers are `{A1, A2, ...}`:

| Blocker set state | Base branch for B |
|---|---|
| All blockers `Done` (merged to main) | `main` |
| One blocker in `In Review`, rest `Done`/`Canceled` | That blocker's branch |
| Multiple blockers in `In Review` | **Integration merge branch** (see below) |
| No blockers | `main` |

**Multi-parent integration merge:**

When two or more blockers are in `In Review`, the orchestrator creates a throwaway integration branch by merging them in turn, then branches B from it.

```bash
git worktree add .worktrees/eng-B-integration -b ralph-integration-eng-B main
cd .worktrees/eng-B-integration
git merge <branch-A1> <branch-A2> ...
# If merge conflicts: remove worktree, skip B (add comment to Linear issue).
```

On success, B's branch starts from this integration branch. On conflict, B is skipped — autonomous session can't resolve cross-parent conflicts; Sean resolves by merging one parent first.

**Stale-parent detection:**

The orchestrator records each child's parent branch HEADs in `progress.json` at dispatch time. At each subsequent orchestrator run, it re-checks those HEADs for still-in-Review children. If a parent HEAD has advanced, add the `stale-parent` label to the child issue and include a Linear comment noting the old/new SHAs.

Sean sees the label when reviewing and decides whether to rebase.

### 8. Failure handling: skip downstream, continue independents

When a session fails (non-zero exit from `claude -p`):

1. Add `ralph-failed` label to the issue.
2. Leave Linear state as `In Progress` (Sean resolves).
3. Mark the issue's transitive DAG descendants as *blocked* for this run (don't dispatch them).
4. Continue dispatching issues that are **not** downstream of the failure.

**Rationale:**
- v1's stop-on-failure was conservative but contradicts the whole v2 pitch ("let independent work proceed in parallel chains"). If A fails and C is independent of A, there's no reason to stop C.
- Skipping the failed issue's *downstream* is conservative where it matters — we don't blindly build on top of failed work.
- Simple to implement: one DAG traversal to identify "tainted" issues per run.

### 9. Keep-from-v1

These v1 design decisions carry over unchanged:

- **Fresh instance per spec** — each issue gets its own `claude -p` invocation with a clean context window.
- **Local execution** — orchestrator runs locally, not on Anthropic's cloud Routines.
- **Custom bash script** — deterministic orchestration (sort, dispatch, track), not LLM orchestration.
- **Native sandbox** — OS-level sandboxing via `.claude/settings.json`; see v1 spec for recommended config.
- **Sequential dispatch within a DAG layer** — parallelism is a v3 concern.
- **Resumable sessions** — each session named `ENG-XXX: title` for `claude --resume`.
- **Progress file** — `progress.json` per run, read by Sean on return.
- **Plugin with adapter pattern** — Linear adapter in v1; structure allows other task sources later.
- **No PR creation, no automated merging** — the loop stops at "In Review"; closing is human-driven.

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
│    ├─ Query Linear: state=Approved, no ralph-failed  │
│    ├─ Filter by pickup rule (blockers satisfied)     │
│    ├─ Topological sort                               │
│    └─ For each ready spec (sequential):              │
│        ├─ Determine base branch (DAG-aware)          │
│        ├─ If multi-parent: create integration merge  │
│        ├─ claude -p --worktree --name --sandbox      │
│        ├─ Session invokes /prepare-for-review        │
│        ├─ On success:  state → In Review             │
│        ├─ On failure:  label → ralph-failed, skip    │
│        │                downstream this run          │
│        └─ Update progress.json                       │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│                  WHEN BACK                           │
│                                                      │
│  For each In Review issue:                           │
│    cd .worktrees/eng-XXX                             │
│    claude --resume "ENG-XXX: title"                  │
│    Review → Fix → /<project-local-closing-skill>     │
│                                                      │
│  For each ralph-failed issue:                        │
│    cd .worktrees/eng-XXX                             │
│    claude --resume → debug → retry or cancel         │
│                                                      │
│  For each stale-parent-labeled issue:                │
│    Rebase onto parent's current HEAD during review   │
└─────────────────────────────────────────────────────┘
```

### Components

#### 1. Slash command entry point: `/run-queue`

`disable-model-invocation: true` skill. Sean runs before stepping away. Responsibilities:

1. Read config (project, budget, model).
2. Query Linear for pickup-ready issues (state=Approved, blockers satisfied, no `ralph-failed` label).
3. Topological sort by `blocked-by` relations.
4. Dry-run preview: show queue, base-branch choices, multi-parent integration needs.
5. Prompt for confirmation; on yes, start the orchestrator script.

#### 2. Orchestrator script: `orchestrator.sh`

Processes the ordered queue sequentially. For each issue:

```
# Determine base branch
base_branch = dag_base(issue, parent_states)
  # "main" | parent's branch | integration branch | skip

# If skip: log, continue to next issue
# If integration: create throwaway merge branch; on conflict, skip + Linear comment

# Dispatch
claude -p \
    --worktree ".worktrees/$branch_name" \
    --name "$session_name" \
    --dangerously-skip-permissions \
    --max-budget-usd "$budget_per_spec" \
    "$minimal_prompt_template"

# Classify outcome
if exit_code == 0:
    linear.update_state(issue, "In Review")
    progress.append(success)
else:
    linear.add_label(issue, "ralph-failed")
    taint_downstream(issue)  # skip issue's DAG descendants this run
    progress.append(failure)
```

Continues until queue is empty or all remaining issues are tainted/unreachable.

#### 3. Topological sort: `toposort.sh`

Kahn's algorithm over `blocked-by` relations. Output order respects: dependencies first, Linear priority as tiebreaker.

#### 4. DAG base-branch selection: `dag_base.sh`

```
function dag_base(issue):
    blockers = linear.blocked_by(issue)
    review_parents = [b for b in blockers if b.state == "In Review"]

    if not review_parents:
        return "main"   # all blockers Done/Canceled, or no blockers
    if len(review_parents) == 1:
        return review_parents[0].branch_name
    # Multi-parent case
    return integration_merge(review_parents)  # may return "skip" on conflict
```

#### 5. Linear adapter: `adapters/linear.sh`

- **Query:** issues in state=Approved within configured project, filtered by label (exclude `ralph-failed`).
- **Dependencies:** `blocked-by` relations for pickup rule.
- **State transitions:** Approved → In Progress (on dispatch), In Progress → In Review (on success).
- **Labels:** add `ralph-failed` on failure, `stale-parent` on amendment detection.
- **Comments:** optional audit comments on dispatch, stale-parent detection, or integration-merge conflict.
- **Branch names:** use Linear's auto-generated `eng-XXX-slug` convention.

#### 6. Stale-parent scanner (runs at start of each orchestrator run)

For every issue currently in `In Review` with a recorded parent branch HEAD:

```
old_head = progress_history[issue]["parent_head"]
new_head = git rev-parse <parent_branch>
if old_head != new_head:
    linear.add_label(issue, "stale-parent")
    linear.add_comment(issue, f"Parent {parent_issue} moved from {old_head[:8]} to {new_head[:8]}")
```

#### 7. Progress file: `progress.json`

Appends to existing history; supports the stale-parent scanner and gives Sean a summary on return.

```json
{
    "runs": [
        {
            "run_id": "2026-04-17T22:30:00+08:00",
            "dispatched": [
                {
                    "issue": "ENG-190",
                    "branch": "eng-190-foo",
                    "base": "main",
                    "parents": {},
                    "outcome": "in_review",
                    "exit_code": 0
                },
                {
                    "issue": "ENG-191",
                    "branch": "eng-191-bar",
                    "base": "eng-190-foo",
                    "parents": {"ENG-190": "a1b2c3d4..."},
                    "outcome": "in_review",
                    "exit_code": 0
                }
            ],
            "skipped": [
                {"issue": "ENG-192", "reason": "downstream of failed ENG-191"}
            ]
        }
    ]
}
```

#### 8. Configuration: `config.json`

```json
{
    "task_source": "linear",
    "linear": {
        "project": "Agent Config",
        "approved_state": "Approved",
        "review_state": "In Review",
        "failed_label": "ralph-failed",
        "stale_parent_label": "stale-parent"
    },
    "execution": {
        "budget_per_spec_usd": 5.00,
        "model": "opus",
        "worktree_base": ".worktrees"
    },
    "prompt_template": "You are implementing Linear issue $ISSUE_ID ($ISSUE_TITLE) autonomously.\nThe PRD is in the issue description — read it via Linear.\nBranch: $BRANCH_NAME, worktree: $WORKTREE_PATH.\nWhen implementation is done and tests pass, invoke /prepare-for-review."
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
│   ├── orchestrator.sh           # Main dispatch loop
│   ├── toposort.sh               # Topological sort
│   ├── dag_base.sh               # Base-branch selection
│   ├── integration_merge.sh      # Multi-parent merge
│   ├── stale_parent_scan.sh      # Parent-amendment detection
│   └── adapters/
│       └── linear.sh             # Linear CLI wrapper
└── config.example.json
```

## Contract summary (for ENG-177 / ENG-178 consumption)

Upstream tools (brainstorming, plan-writing) must produce:

1. **A Linear issue** in the configured project, in state `Approved`.
2. **A PRD written into the issue description.** Format is not rigidly prescribed — any markdown that gives Opus 4.7 enough context to implement without further human input. Experiments on what makes a "good" PRD (ENG-177, ENG-178) decide the recommended shape.
3. **Explicit `blocked-by` relations** for any prerequisite issues. The orchestrator uses these for DAG ordering and base-branch selection.

That's the entire input contract. Everything downstream (branch name, worktree path, session name) is derived by the orchestrator from the Linear issue.

## Out of scope for this ticket

- **Creating the `prepare-for-review` skill.** Follow-up ticket.
- **Refactoring / replacing `finishing-a-development-branch`** into project-local closing skills. Follow-up ticket(s) per project.
- **Parallel dispatch within a DAG layer.** v3 extension.
- **Retry logic.** Human-driven after `ralph-failed`.
- **PR creation / automated merging.** Explicit non-goal.
- **Cost reporting.** `--max-budget-usd` provides per-spec caps; no aggregate reporting.
- **Remote / cloud execution.** Local-only for v2.
- **Non-Linear task sources.** Adapter pattern allows it; only Linear ships.

## Follow-up tickets (to file after approval)

1. **Implement ralph loop v2** (the plugin itself) — consumes this design.
2. **Create `prepare-for-review` skill** — contract defined in Decision 3.
3. **Replace `finishing-a-development-branch`** with a project-local closing skill for chezmoi (and one per other active project).
4. **Add "Approved" state to ENG team in Linear** (one-time config, can be done any time).

ENG-177 and ENG-178 are already filed as the upstream-tool experiments; they consume the contract defined in this ticket.

## Open questions (to resolve during implementation)

1. **`claude --worktree` flag behavior.** Does the native flag use `.worktrees/` when set, or does it ignore our preference? Affects whether we call `git worktree add` first and pass the path, or let `--worktree` create it. Needs live verification.

2. **`--max-budget-usd` exit behavior.** On budget exhaustion: does `claude -p` exit non-zero, or exit 0 with incomplete work? If the latter, the orchestrator would mark the spec complete when it isn't. Needs live test.

3. **Session output capture.** Should stdout be captured per-spec to `.worktrees/<branch>/orchestrator-output.log`? Useful for debugging failures without resuming; adds I/O. Lean toward yes, behind a config flag.

4. **Integration-merge cleanup.** The throwaway integration branch created for multi-parent dispatch — does it live on after the child's session, or get cleaned up? Affects disk usage on long chains; no correctness impact.

5. **Stale-parent check frequency.** Detection runs at start of each orchestrator invocation. If Sean runs the loop infrequently, stale detection is infrequent. Could also run via post-commit hook on parent branches — but that's extra machinery.
