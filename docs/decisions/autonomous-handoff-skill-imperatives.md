# Autonomous-handoff skill imperatives: TaskCreate + anti-summary terminal-action contract

## Context

Three autonomous ralph sessions exited cleanly without invoking the
required terminal sub-skill or Linear-state transition:

- **ENG-294 (2026-04-26)** — `/sr-implement` reached Step 5 and invoked
  `/prepare-for-review`. After `/prepare-for-review`'s Step 1
  `update-stale-docs` sub-skill returned, the agent treated the
  sub-skill's "complete" message as overall task completion and exited.
  Steps 2–7 (`capture-decisions`, `prune-completed-docs`, doc-commit,
  codex review, Linear comment, state transition) never ran.
- **ENG-257 and ENG-275 (post-2026-04-26)** — `/sr-implement` Steps 1–4
  ran cleanly. Step 5 said "invoke `/prepare-for-review`" but the agent
  composed a terminal markdown summary message ("Changes",
  "Verification", "Tests Passing", etc.) and the session ended.
  `/prepare-for-review` was never invoked. Neither session posted an
  escape-hatch Linear comment, so the absence wasn't an authorized
  bail-out.

The orchestrator correctly classified all three as
`exit_clean_no_review`, applied `ralph-failed`, and tainted DAG
descendants. The orchestrator and the outcome classifier did the right
thing. The failure is in the agent's terminal behavior inside
`/sr-implement` and `/prepare-for-review`.

The unifying failure mode: **the LLM's natural completion instinct
(write a summary describing what was done) out-competes the skill's
prescriptive Step N wording for the required terminal action.** The
boundary varies — sometimes between sub-skill returns inside
`/prepare-for-review`, sometimes between Steps 4 and 5 inside
`/sr-implement` — but the cause is the same.

Possibly aggravated by upstream Claude Code bug
[anthropics/claude-code#17351](https://github.com/anthropics/claude-code/issues/17351),
but the failure shape extends beyond what that bug describes. Whether
or not #17351 contributes, the mitigation pattern below applies to the
broader class.

Positive precedent: `/sr-spec` already uses a `## Checklist` imperative
that requires materializing each step as a task before any action.
`/sr-spec` has not exhibited this failure mode.

## Decision

Apply two interventions to BOTH `/sr-implement` and
`/prepare-for-review`, plus a frontmatter widening that the first
intervention depends on:

1. **TaskCreate imperative at the top** (`## Checklist` section,
   mirroring `/sr-spec`'s pattern). An explicit imperative requiring
   the agent to materialize each step as a task before any action.
   Persistent task state competes with the summary instinct on every
   turn — when the agent considers "should I emit and end," `TaskList`
   shows pending items pulling against that decision.
2. **Anti-summary terminal-action contract** (`## Terminal action
   contract` section). A bold callout that names the failure mode
   explicitly, specifies the only legal terminal actions for the skill,
   prohibits markdown-summary-as-final-output, and states the
   orchestrator-classification consequence
   (`exit_clean_no_review` → `ralph-failed` label → tainted DAG
   descendants).
3. **`allowed-tools` widening** — both skills retain their existing
   narrow allowlists (`Skill, Bash, Read, Glob, Grep, Write, Edit`) and
   add the harness's task-state tool name(s) (`TodoWrite` on the older
   single-tool API, or `TaskCreate`/`TaskList`/`TaskUpdate` on the
   decomposed API). Sufficient to satisfy the Checklist imperative
   without removing the least-privilege control.

`/sr-spec` already has the TaskCreate pattern; the anti-summary
contract is new across the board. `/sr-spec` is out of scope here
(no observed incident, YAGNI). `/close-issue` runs in the orchestrator
(no `claude -p` boundary) so the failure mode does not apply there.

Companion sub-skills (`update-stale-docs`, `capture-decisions`,
`prune-completed-docs`, `codex-review-gate`) live in chezmoi-managed
agent config and are tracked in the **Agent Config** Linear project,
not Sensible Ralph.

## Reasoning

The two interventions target the failure mode at two different decision
points: `TaskCreate` creates persistent state competing with the
summary instinct on every turn during the execution loop; the
anti-summary contract is a direct counter-instruction at terminal-
output time. Together they cover both the during-execution and at-the-
end decision points where the bug fires.

Alternatives considered and rejected:

- **Announcement pre-commitment** ("Announce: 'I'm now invoking X'") —
  text commitment is read-once and doesn't structurally prevent
  following the announcement with a summary and exit.
- **Dot graph** of the skill's state machine — descriptive, not
  prescriptive. Low marginal value for linear sequential skills. Adds
  maintenance overhead.
- **Bold `**REQUIRED TERMINAL ACTION:**` marker as a step prefix** —
  formatting alone is weak; folding bold into the explicit anti-summary
  instruction is the same idea, more direct.
- **Orchestrator-level dispatch-prompt tightening** — additive defense
  at a different layer; out of scope here, file as follow-up if
  Interventions 1+2 prove insufficient.
- **Re-architecting `/prepare-for-review` to inline sub-skill bodies**
  (replacing nested `Skill` invocations with bash) — explicitly
  rejected; too disruptive relative to the lighter-weight intervention.

`allowed-tools` widening rather than removal: removing the field would
broaden these autonomous skills to "all tools allowed", a real trust-
boundary expansion beyond what the task-list workaround needs. The
narrow-allowlist least-privilege model is a deliberate safety control
in this repo (cf. `/sr-status`'s SKILL.md and
`docs/specs/ralph-status-command.md`).

Cost: ~25 lines per skill, self-obsolescing.

Confidence varies by failure boundary:

- `/sr-implement` Step 4→5 boundary (ENG-257, ENG-275). Same-skill,
  between-step boundary — no nested `Skill` return is involved.
  TaskCreate provides persistent state on the agent's normal decision
  turns and the anti-summary contract gives a direct counter-
  instruction at terminal-output time. Higher confidence.
- `/prepare-for-review` sub-skill return boundary (ENG-294). Failure
  happens after a `Skill` tool invocation returns. We do not have
  direct evidence that `TaskList` state is queryable from the post-
  `Skill`-return turn — the positive `/sr-spec` precedent invokes codex
  via `Bash`, not via `Skill`, so it doesn't exercise the same
  mechanism. If the harness preserves `TaskList` across nested `Skill`
  returns, the mitigation works here too. If not, the TaskCreate
  intervention is inert at this boundary and the anti-summary contract
  is the only active defense. Lower confidence — but worst case, no
  regression vs current behavior.

This is a **prophylactic** mitigation, not a structural recovery
mechanism. Once the bug-shape fires (agent has emitted a final message
and the harness is about to terminate), there is no post-failure
resumption path. The interventions reduce probability, not eliminate
it. Acceptance criteria for ENG-307 do not gate on a behavioral
guarantee.

## Consequences

- The `allowed-tools` allowlist is now **harness-version-coupled**:
  when Claude Code introduces or renames task tools, the allowlist
  needs re-editing to reflect the new names. That re-edit is a
  separate maintenance task, filed as a follow-up issue when the
  harness changes. The retrieval recipe is `git log --grep='Ref:
  ENG-307'` against `main` to find the implementing commits.
- When upstream
  [anthropics/claude-code#17351](https://github.com/anthropics/claude-code/issues/17351)
  lands, the imperatives become redundant text but stay correct
  guidance for autonomous safety. No removal needed in ENG-307's
  scope; removal is a separate follow-up issue when upstream
  resolves. That follow-up should list the implementing commits
  introduced under ENG-307, retrievable at filing time via
  `git log --grep='Ref: ENG-307'` against `main` (their SHAs do not
  exist when this decision doc is written).
- Residual incidents at unrelated boundaries (e.g., `/sr-spec` summary
  exits, or `/close-issue` if its implementation ever moves into
  `claude -p`) should be filed as separate follow-up issues — do NOT
  silently extend these imperatives to other skills under ENG-307's
  scope.
- If post-implementation incidents recur at meaningful rate at either
  boundary covered here, file a follow-up issue to escalate
  (orchestrator-level dispatch-prompt tightening, or stronger
  structural changes such as inlining companion-skill bodies directly
  into `/prepare-for-review`).
