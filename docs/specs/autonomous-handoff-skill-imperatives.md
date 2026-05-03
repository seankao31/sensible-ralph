# Harden autonomous skill flow against summary-as-terminal-action exits

## Problem

Autonomous ralph sessions have exited cleanly without invoking the
required terminal skill / Linear-state transition in three observed
incidents:

- **ENG-294 (2026-04-26)** — `/sr-implement` reached Step 5, invoked
  `/prepare-for-review`, which then ran Step 1's `update-stale-docs`
  sub-skill. After the sub-skill returned, the agent treated its
  "complete" message as overall task completion and exited. Steps
  2–7 of `/prepare-for-review` (capture-decisions, prune-completed-
  docs, doc-commit, codex review, Linear comment, state transition)
  never ran.
- **ENG-257 and ENG-275 (post-2026-04-26)** — `/sr-implement` Steps
  1–4 ran cleanly (PRD read, conflicts checked, implementation
  committed, tests verified). Step 5 said "invoke
  `/prepare-for-review`" but the agent instead composed a terminal
  markdown summary message ("Changes", "Verification", "Tests
  Passing", etc.) and the session ended. `/prepare-for-review` was
  never invoked. Neither session posted an escape-hatch Linear
  comment, so the absence wasn't an authorized bail-out.

The orchestrator correctly classified all three as
`exit_clean_no_review`, applied `ralph-failed`, and tainted DAG
descendants. The orchestrator and the outcome classifier did the
right thing. The failure is in the agent's terminal behavior inside
`/sr-implement` and `/prepare-for-review`.

### Failure mode characterization

All three incidents are manifestations of the same underlying
behavior: **the LLM's natural completion instinct (write a summary
describing what was done) out-competes the skill's prescriptive
Step N wording for the required terminal action.** The boundary
varies — sometimes between sub-skill returns inside
`/prepare-for-review`, sometimes between Steps 4 and 5 inside
`/sr-implement` — but the cause is the same.

Possibly aggravated by upstream Claude Code bug
[anthropics/claude-code#17351](https://github.com/anthropics/claude-code/issues/17351),
but the failure shape extends beyond what that bug describes.
Whether or not #17351 is a contributing cause, the mitigation
pattern proposed here applies to the broader class.

## Approach

Apply two interventions to BOTH `/sr-implement` and
`/prepare-for-review`, plus a frontmatter widening that the first
intervention depends on.

### Intervention 1 — TaskCreate imperative at the top

Mirror `/sr-spec`'s `## Checklist` pattern: an explicit imperative
at the start of the operational sequence requiring the agent to
materialize each step as a task before any action. Persistent task
state competes with the summary instinct **on every turn** — when
the agent considers "should I emit and end," `TaskList` shows
pending items pulling against that decision. This is the strongest
available intervention; `/sr-spec` works under this discipline.

### Intervention 2 — Anti-summary terminal-action contract

A bold callout near the top of each skill that:

1. Names the failure mode explicitly ("agents have ended sessions
   with a summary message instead of the required terminal
   tool/skill call").
2. Specifies the only legal terminal actions for the skill.
3. Prohibits summary messages as terminal output.
4. States the consequence (orchestrator classifies as
   `exit_clean_no_review`, taints descendants).

This is direct counter-instruction targeting the observed failure
mechanism. Format-prominent (bold) so it stands distinct from list
items. Precedent: superpowers'
`finishing-a-development-branch/SKILL.md` line 85
(`**Don't add explanation** beyond what's shown.`).

### Why these two, why not announcement / dot graph / etc.

`TaskCreate` is the structural mechanism (persistent state). The
anti-summary contract is the explicit countermand at terminal-output
time. Together they cover the failure mode at two different decision
points (during execution loop, and at terminal-output time).
Alternatives considered and rejected:

- **Announcement pre-commitment** ("Announce: 'I'm now invoking
  X'") — text commitment is read-once and doesn't structurally
  prevent following the announcement with a summary and exit.
- **Dot graph** — descriptive, not prescriptive. Low marginal
  value for linear sequential skills. Adds maintenance overhead.
- **Bold `**REQUIRED TERMINAL ACTION:**` marker as a step prefix**
  — formatting alone is weak; folding bold into the explicit
  anti-summary instruction is the same idea, more direct.
- **Orchestrator-level dispatch-prompt tightening** — additive
  defense at a different layer; out of scope here, file as
  follow-up if Interventions 1+2 prove insufficient.

### Self-obsolescence and residual risk

This is **not** a structural recovery mechanism. Once the
bug-shape fires (agent has emitted a final message and the harness
is about to terminate), there is no post-failure resumption path.
The interventions are **prophylactic**: they reduce the probability
of the failure firing in the first place, not eliminate it.
Acceptance criteria do not gate on a behavioral guarantee.

**Confidence varies by failure boundary.** The two boundaries
this spec targets behave differently:

- **`/sr-implement` Step 4→5 boundary (ENG-257, ENG-275).** This
  is a same-skill, between-step boundary — no nested `Skill`
  return is involved when the agent decides whether to invoke
  `/prepare-for-review` versus write a summary. The TaskCreate
  imperative provides persistent state on the agent's normal
  decision turns and the anti-summary contract gives a direct
  counter-instruction at terminal-output time. Higher
  confidence the mitigation applies here.
- **`/prepare-for-review` sub-skill return boundary (ENG-294).**
  Here, the failure happens after a `Skill` tool invocation
  returns. We do **not** have direct evidence that `TaskList`
  state is queryable from the post-`Skill`-return turn — the
  positive `/sr-spec` precedent invokes codex via `Bash`, not
  via the `Skill` tool, so it doesn't exercise the same
  mechanism. If the harness preserves `TaskList` across nested
  `Skill` returns, the mitigation works here too. If not, the
  TaskCreate intervention is *inert* at this boundary and the
  anti-summary contract is the only active defense. **The spec
  does not claim to resolve ENG-294's exact path with
  confidence — only to make it less likely.** Worst case at this
  boundary: the imperative is inert, no regression vs current
  behavior.

If post-implementation incidents recur at meaningful rate at
either boundary, file a follow-up issue to escalate
(orchestrator-level dispatch-prompt tightening, or stronger
structural changes such as inlining companion-skill bodies
directly into `/prepare-for-review`).

When upstream #17351 lands, the imperatives become redundant text
but stay correct guidance for autonomous safety. No removal needed
in this issue's scope; removal is a separate follow-up issue when
upstream resolves. That follow-up should list the implementing
commits introduced under ENG-307, retrievable at filing time via
`git log --grep='Ref: ENG-307'` against `main` (their SHAs do not
exist when this spec is written).

## Scope

In scope:

- `skills/sr-implement/SKILL.md` — both interventions + frontmatter
  widening.
- `skills/prepare-for-review/SKILL.md` — both interventions +
  frontmatter widening.
- `docs/decisions/2026-04-28-autonomous-handoff-skill-imperatives.md`
  — new decision doc.
- Linear ENG-307 title update + upstream-URL attachment.

Out of scope:

- `/sr-spec` and `/close-issue`. `/sr-spec` already has the
  TaskCreate imperative and works; an anti-summary contract there
  is defensible but no incident has been observed and YAGNI.
  `/close-issue` runs in the orchestrator (no `claude -p`
  boundary) so the failure mode does not apply.
- Companion skills (`update-stale-docs`, `capture-decisions`,
  `prune-completed-docs`, `codex-review-gate`) — chezmoi-managed,
  separate repo. Per project CLAUDE.md cross-repo rule, those
  belong in the **Agent Config** Linear project.
- Orchestrator-level dispatch-prompt tightening — additive
  defense, file as follow-up if needed.
- Synthetic skill-instruction test harness or skill-flow simulator.
- Automated revert of the imperatives when upstream lands —
  separate follow-up issue.
- Re-architecting `/prepare-for-review` to use bash scripts in
  place of sub-skill invocations (approach C from the original
  ENG-307 framing) — explicitly rejected.

## Design

### Frontmatter widening (both skills)

Both `/sr-implement` and `/prepare-for-review` currently declare:

```
allowed-tools: Skill, Bash, Read, Glob, Grep, Write, Edit
```

**Widen the allowlist to add the task-tool name(s) the running
Claude Code harness exposes, alongside the existing entries.** Do
NOT remove the field. The narrow-allowlist least-privilege model
is a deliberate safety control in this repo (cf. `/sr-status`'s
SKILL.md and `docs/specs/ralph-status-command.md`'s rationale for
restrictive allowlists in autonomous skills) — removing it would
broaden these autonomous skills to "all tools allowed", a real
trust-boundary expansion beyond what the task-list workaround
needs.

At edit time, the implementer MUST inspect the harness's available
tools in the current session and identify the task tool(s) — the
possible names are `TodoWrite` (older single-tool API) or
`TaskCreate` / `TaskUpdate` / `TaskList` / `TaskGet` (newer
decomposition), or both. Add **only** the names the harness
exposes to `allowed-tools`, alongside the existing entries.

Do NOT speculatively pre-add unknown names. The parser semantics
for unrecognized entries are undocumented in this repo, and a
strict-validation harness would fail-closed and stop loading the
skill — a worse regression than the bug being mitigated. The cost
of being conservative here is that the allowlist is
**harness-version-coupled**: when Claude Code introduces or
renames task tools, the allowlist needs re-editing to reflect
the new names. That re-edit is a separate maintenance task,
filed as a follow-up issue when the harness changes. The decision
doc records this coupling explicitly so future operators have a
retrieval recipe.

Minimum viable result for each skill: the harness's task-state
tool(s) are present in the widened allowed-tools, sufficient to
satisfy the Checklist imperative's "create a task per item"
instruction. Concretely:

- On a harness exposing only `TodoWrite` (older single-tool API
  that handles both write and persistent-list semantics): add
  `TodoWrite`. That single name is sufficient.
- On a harness exposing the decomposed API: add at minimum
  `TaskCreate` (materialize the list) and `TaskList` (enumerate
  it on later turns); add `TaskUpdate` if the harness exposes
  it (needed to mark items completed).
- On a harness exposing both APIs: add the names actually
  present from both.

What matters is that after the widening, the agent can both
materialize the checklist as task state and re-read it on a
subsequent turn.

`/sr-spec` works without an explicit allowlist because its
frontmatter omits `allowed-tools` entirely, defaulting to all
tools allowed. The two skills in this spec retain narrow
allowlists for least-privilege — we widen, not remove.

### `/sr-implement` skill change

Edit `skills/sr-implement/SKILL.md`. Three additions, no removals.

#### A. `## Terminal action contract` — at the top, after the opening description

Insert immediately after the opening description paragraph
(currently around line 12–13: ending with the `/sr-implement
ENG-NNN` example) and before the orchestrator-context paragraph
(currently around line 14–15) — before the first numbered `##
Setup` section.

Use this literal content:

```markdown
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
```

#### B. `## Checklist` — between `Terminal action contract` and `## Setup: Assign the issue ID`

Insert a new `## Checklist` section. Use this literal content
(descriptive titles only; positional mapping to existing `## Step
N` / `## Setup` sections):

```markdown
## Checklist

You MUST create a task for each of these items and complete them in order:

1. **Setup** — assign the invocation argument to `$ISSUE_ID`.
2. **Read the PRD** — `linear issue view "$ISSUE_ID" --json | jq -r .description`.
3. **Check for unresolved merge conflicts** — resolve any pre-merged-parent conflicts before implementing.
4. **Implement per the PRD** — TDD, smallest reasonable changes, scope discipline.
5. **Verify tests pass** — run the project's verification commands fresh and confirm pristine output.
6. **Invoke `/prepare-for-review`** — terminal handoff to the next skill in the autonomous flow. (See Terminal action contract above.)
```

The existing `## Setup: Assign the issue ID`, `## Step 1: Read the
PRD`, …, `## Step 5: Invoke /prepare-for-review (conditional)`
sections remain unchanged — they are the detailed instructions for
each checklist item.

#### C. Reinforce Step 5's terminal nature

Edit the existing `## Step 5: Invoke /prepare-for-review
(conditional)` body. Immediately after the section heading and
before the existing first-line text (currently `If Steps 3–4
succeeded, invoke /prepare-for-review.`), insert this literal
paragraph:

```markdown
**This is the skill's terminal action.** The next thing you emit MUST be the `/prepare-for-review` invocation (or, on a failure path, the escape-hatch Linear comment), NOT a summary message. See the Terminal action contract at the top of this skill.
```

### `/prepare-for-review` skill change

Edit `skills/prepare-for-review/SKILL.md`. Three additions, no
removals.

#### A. `## Terminal action contract` — after `## When to Use`

Insert a new `## Terminal action contract` section immediately
after `## When to Use` (currently ending around line 17) and
before `## Companion skills` (currently line 19).

Use this literal content:

```markdown
## Terminal action contract

This contract addresses one specific failure mode: emitting a
markdown summary as the session's final output **instead of**
performing one of the legal terminal actions below. It does NOT
redefine the skill's failure-handling policy. Hard infrastructure
failures (unreachable Linear CLI, dirty working tree, trunk-base
detection failure, post-comment state-transition failure, etc.)
exit the skill per the existing preflight and Red Flags handlers,
with whatever exit code those handlers specify (currently `exit
1` in several places).

**The legal final actions of this skill are:**

1. **Success path, state change required** — Step 7's `linear issue update --state "$CLAUDE_PLUGIN_OPTION_REVIEW_STATE"` write transitioning the issue to In Review.
2. **Success path, idempotent rerun** — Step 7's idempotency branch when the issue is already in `$CLAUDE_PLUGIN_OPTION_REVIEW_STATE` (skip the write to avoid Linear activity-feed noise on retry, then exit). No Linear state write occurs in this case, but the SHA-based dedup in Step 6 has already done its job.
3. **Objective precondition stop that blocks Step 6 or Step 7** — exit per the existing preflight or Red Flags handlers. The complete list of cases this bucket covers, all enumerated in the existing skill body:
   - Unreachable Linear CLI (idempotency check or Step 6 / Step 7 calls).
   - Unexpected Linear state at the idempotency check (`Any other state — stop and surface to the reviewer`).
   - Dirty working tree at the pre-flight check.
   - Trunk-base detection failure (`Cannot determine trunk` exit 1 path).
   - Post-comment state-transition failure (line 232–237 in the current skill body).
   - Tests failing — do NOT run this skill at all (the skill itself rejects this case before any step runs; included here for completeness so the agent has no doubt that "tests failed → exit per the existing handler" is legal).
   Exit code per those handlers, typically `exit 1`. **Soft content-level cases do NOT belong in this bucket:** codex-review actionable findings must be fixed and re-run per Step 5; codex-review ambiguous findings and substantial PRD deviations must still produce the Step 6 handoff comment so the reviewer sees them; an "In Review" preflight state proceeds with idempotent rerun (legal final action 2). The carve-out is for objective preconditions that block the comment-or-transition path itself, not for content-level review states.

**The illegal final action is: writing a markdown summary**
("Implementation complete", "All steps done", etc.) **as the
session's last output without one of the above actions having
fired.** Sessions that end with a summary and no terminal
tool/skill call are misclassified by the orchestrator as
`exit_clean_no_review` — the issue is labeled `ralph-failed`
and DAG descendants are tainted.

The same rule applies between sub-skill returns inside this skill:
when a sub-skill (Steps 1, 2, 3, or 5's `update-stale-docs`,
`capture-decisions`, `prune-completed-docs`,
`codex-review-gate`) reports completion, the next action MUST be
the next checklist item, NOT a summary of what the sub-skill just
did. The sub-skill's "complete" message is NOT this skill's
terminal signal.
```

#### B. `## Checklist` — before `## The Sequence (run in order)`

Insert a new `## Checklist` section immediately before the existing
`## The Sequence (run in order)` heading (currently at line 109,
following `## Compute base SHA (do this before Step 1)`).

Use this literal content. The first four items are the existing
preflight sections (which sit above `## The Sequence` in the
current skill); the remaining seven items mirror the existing
`### Step N:` subsections positionally. Descriptive titles only —
no `Step N:` prefix.

```markdown
## Checklist

You MUST create a task for each of these items and complete them in order:

1. **Determine the Linear issue ID** — assign `$ISSUE_ID` from the orchestrator-injected env or the branch name.
2. **Idempotency check** — read current Linear state; branch on `$CLAUDE_PLUGIN_OPTION_REVIEW_STATE` (skip Step 7), `$CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE` (proceed full sequence), or any other state (stop and surface to reviewer).
3. **Verify clean working tree** — `git status --short` must be empty before any step runs.
4. **Compute base SHA** — read `.sensible-ralph-base-sha` or detect trunk via `git merge-base HEAD <trunk>`.
5. **Update stale docs** — invoke the `update-stale-docs` skill with `--base "$BASE_SHA"`.
6. **Capture decisions** — invoke the `capture-decisions` skill.
7. **Prune completed docs** — invoke the `prune-completed-docs` skill.
8. **Commit doc/decisions changes** — stage and commit any new files or edits from items 5–7.
9. **Codex review gate** — invoke `codex-review-gate` with `--base "$BASE_SHA"`; address actionable findings inline, capture ambiguous ones for item 10's handoff comment.
10. **Post Linear handoff comment** — write Review Summary + QA Test Plan to a tempfile and post via `linear issue comment add`.
11. **Transition Linear issue to In Review** — `linear issue update "$ISSUE_ID" --state "$CLAUDE_PLUGIN_OPTION_REVIEW_STATE"` (skip if already in that state).
```

The existing `## The Sequence (run in order)` body and all
`### Step N:` subsections remain intact and unchanged. The
Checklist is a re-entry signal and visual outline, not a
replacement for the detailed per-step instructions. Any drift
between Checklist summaries and `### Step N:` bodies must be
resolved by editing the Checklist summary, not the step body.

#### C. Reinforce Step 7's terminal nature

Edit the existing `### Step 7: Transition Linear issue to In
Review` body. Immediately after the section heading and before the
existing first-line text (currently `Check current state, skip the
write if it's already In Review …`), insert this literal
paragraph:

```markdown
**This is the skill's terminal step.** Complete the existing state-read-then-conditional-write sequence below without emitting a markdown summary first. The legitimate terminal output is either the `linear issue update --state "$CLAUDE_PLUGIN_OPTION_REVIEW_STATE"` write or the no-op exit when the state read shows the issue is already in `$CLAUDE_PLUGIN_OPTION_REVIEW_STATE`. A summary message between the state-read and the conditional write — or after either of them — is NOT a legal terminal action. See the Terminal action contract at the top of this skill.
```

### Decision doc

Create
`docs/decisions/2026-04-28-autonomous-handoff-skill-imperatives.md`.
Filename follows the existing `docs/decisions/` convention
(`YYYY-MM-DD-short-title.md`).

Required sections:

- **Context** — three observed incidents (ENG-294, ENG-257,
  ENG-275); unifying failure mode (summary-as-terminal-action,
  the LLM completion instinct out-competing prescriptive Step N
  wording); upstream bug
  [anthropics/claude-code#17351](https://github.com/anthropics/claude-code/issues/17351)
  and its possibly-aggravating role; existing `/sr-spec` pattern
  as positive evidence.
- **Decision** — added two interventions (TaskCreate imperative +
  anti-summary terminal-action contract) plus `allowed-tools`
  widening to BOTH `/sr-implement` and `/prepare-for-review`.
  `/sr-spec` already has the TaskCreate pattern; the anti-summary
  contract is new across the board.
- **Reasoning** — why these two interventions over alternatives.
  Cite the alternatives considered (announcement pre-commitment,
  bold-only markers, dot graphs, orchestrator-level dispatch
  tightening) and why each was rejected or deferred. The two
  chosen interventions target the failure mode at two different
  decision points: TaskCreate creates persistent state competing
  with the summary instinct on every turn; the anti-summary
  contract is a direct counter-instruction at terminal-output
  time. Cost is ~25 lines per skill, self-obsolescing.
- **Consequences** — once upstream lands, the imperatives become
  redundant text. Removal is a separate follow-up issue (file when
  upstream resolves). The follow-up should list the implementing
  commits introduced under ENG-307, retrievable at filing time via
  `git log --grep='Ref: ENG-307'` against `main` (SHAs do not
  exist when this decision doc is written). Residual incidents at
  unrelated boundaries (e.g., `/sr-spec` summary exits, or
  `/close-issue` if its implementation ever moves into `claude -p`)
  should be filed as separate follow-up issues — do NOT silently
  extend these imperatives to other skills under this ticket's
  scope.

### Linear title update

Update the Linear issue title from:

```
Mitigate Claude Code nested-skill context loss in /prepare-for-review
```

to:

```
Harden autonomous skill flow against summary-as-terminal-action exits
```

via:

```bash
linear issue update ENG-307 --title "Harden autonomous skill flow against summary-as-terminal-action exits"
```

Run before the `/sr-spec` finalize step's description-overwrite —
finalize updates the description, not the title, so the title must
be set separately.

### Upstream link as Linear attachment

After `/sr-spec` finalize overwrites the description with this
spec body (which embeds the upstream URL in § Problem and §
References), additionally attach the GitHub URL via:

```bash
linear issue attachment create ENG-307 \
  --url https://github.com/anthropics/claude-code/issues/17351 \
  --title "Upstream: nested-skill context loss"
```

Verify exact CLI syntax against `linear issue attachment create
--help` at invocation time. If the CLI doesn't support attachment
creation, fall back to ensuring the upstream URL stays in the
issue description (it does, via this spec) and note the manual
fallback in the Step 6 handoff comment.

This is **not** a Linear `related` relation: `related` connects two
Linear issues. The attachment is the right Linear primitive for an
external GitHub URL.

## Implementation steps

The autonomous implementer should:

1. Read the current `skills/sr-implement/SKILL.md` and
   `skills/prepare-for-review/SKILL.md` to know exact line counts
   and existing wording.
2. Edit `skills/sr-implement/SKILL.md`:
   - **Widen** the frontmatter `allowed-tools` field by adding
     verified-real task-tool name(s) (alongside the existing
     entries) per § Design / "Frontmatter widening (both skills)".
     Do NOT remove the field; do NOT speculatively add unknown
     names.
   - Insert `## Terminal action contract` per § Design /
     "/sr-implement skill change" / A.
   - Insert `## Checklist` per § Design /
     "/sr-implement skill change" / B.
   - Add the terminal-nature reminder paragraph to Step 5 per
     § Design / "/sr-implement skill change" / C.
3. Edit `skills/prepare-for-review/SKILL.md`:
   - **Widen** the frontmatter `allowed-tools` field by adding
     verified-real task-tool name(s) (alongside the existing
     entries) per § Design / "Frontmatter widening (both skills)".
     Do NOT remove the field; do NOT speculatively add unknown
     names.
   - Insert `## Terminal action contract` per § Design /
     "/prepare-for-review skill change" / A.
   - Insert `## Checklist` per § Design /
     "/prepare-for-review skill change" / B.
   - Add the terminal-nature reminder paragraph to Step 7 per
     § Design / "/prepare-for-review skill change" / C.
4. Create
   `docs/decisions/2026-04-28-autonomous-handoff-skill-imperatives.md`
   per § Design / "Decision doc".
5. Update Linear title via `linear issue update ENG-307 --title
   "Harden autonomous skill flow against summary-as-terminal-action
   exits"`.
6. Attach upstream URL via `linear issue attachment create ENG-307
   --url https://github.com/anthropics/claude-code/issues/17351
   --title "Upstream: nested-skill context loss"` (or corrected
   equivalent — verify syntax). On unsupported-CLI fallback, skip
   and surface the manual-attachment recommendation in the Step 6
   handoff comment.
7. Commit both skill edits and the decision doc together with a
   single conventional-commits message:

   ```
   docs(skills): harden /sr-implement and /prepare-for-review against summary-as-terminal-action exits

   Add `## Checklist` and `## Terminal action contract` sections to
   both /sr-implement and /prepare-for-review, plus widen their
   allowed-tools to include verified-real task tools. Mitigates the
   summary-as-terminal-action failure mode observed in ENG-294,
   ENG-257, and ENG-275 — the LLM's natural completion instinct
   out-competing the skill's prescriptive Step N wording for the
   required terminal sub-skill / Linear-state transition.

   Self-obsolescing prophylactic mitigation; not a structural
   recovery path. See docs/decisions/2026-04-28-autonomous-handoff-skill-imperatives.md
   for the full rationale and rejected alternatives.

   Ref: ENG-307
   ```

8. Continue through `/prepare-for-review` — this issue's *own* run
   will be the first autonomous exercise of the new patterns at
   both `/sr-implement` and `/prepare-for-review`, providing a
   useful smoke test. If the new contracts work, this run
   completes cleanly. If not, the orchestrator catches the failure
   as `exit_clean_no_review`.

## Acceptance criteria

1. `skills/sr-implement/SKILL.md`:
   - Frontmatter `allowed-tools` retains the existing entries
     (`Skill, Bash, Read, Glob, Grep, Write, Edit`) AND adds the
     task-state tool name(s) per § Design / "Frontmatter widening
     (both skills)" matrix:
     - On `TodoWrite`-only harness: `TodoWrite` is added.
     - On decomposed-API harness: at minimum `TaskCreate` and
       `TaskList` are added; `TaskUpdate` is added if the harness
       exposes it.
     - On a harness exposing both APIs: names from both sets
       that are actually present are added.
     The field is NOT removed.
   - Body contains a `## Terminal action contract` section near
     the top, naming the three legal final actions (success
     handoff, blocking failure with `$ISSUE_ID` + escape-hatch
     comment, hard infrastructure failure / Red Flags exit),
     prohibiting markdown-summary-as-final-output, and stating
     the orchestrator-classification consequence.
   - Body contains a `## Checklist` section with the imperative
     wording exact and a 6-item numbered list whose items match
     the literal content in § Design /
     "/sr-implement skill change" / B.
   - Step 5 body contains the terminal-nature reminder paragraph
     per § Design / "/sr-implement skill change" / C.

2. `skills/prepare-for-review/SKILL.md`:
   - Frontmatter `allowed-tools` retains the existing entries
     (`Skill, Bash, Read, Glob, Grep, Write, Edit`) AND adds the
     task-state tool name(s) per § Design / "Frontmatter widening
     (both skills)" matrix (same three rows as for
     `/sr-implement`: `TodoWrite`-only adds `TodoWrite`;
     decomposed-API adds at minimum `TaskCreate` and `TaskList`,
     plus `TaskUpdate` if exposed; both-API adds names from both
     sets that are actually present). The field is NOT removed.
   - Body contains a `## Terminal action contract` section after
     `## When to Use`, naming the three legal final actions
     (success state-change write, success idempotent skip-no-write
     rerun, hard infrastructure failure / preflight or Red Flags
     exit), prohibiting markdown-summary-as-final-output, and
     stating the orchestrator-classification consequence.
   - Body contains a `## Checklist` section immediately before
     `## The Sequence (run in order)`, with the imperative wording
     exact and an 11-item numbered list (4 preflight items + 7
     operational items) whose items match the literal content in
     § Design / "/prepare-for-review skill change" / B.
   - Step 7 body contains the terminal-nature reminder paragraph
     per § Design / "/prepare-for-review skill change" / C.

3. `docs/decisions/2026-04-28-autonomous-handoff-skill-imperatives.md`
   exists with the four sections (Context, Decision, Reasoning,
   Consequences) per § Design / "Decision doc".

4. Linear ENG-307 title is updated to `Harden autonomous skill
   flow against summary-as-terminal-action exits`.

5. The upstream GitHub issue URL is attached to ENG-307 in Linear
   via `linear issue attachment create` — or, if the CLI doesn't
   support that, the URL remains in the issue description and the
   handoff comment notes the manual fallback.

6. All file changes (both `SKILL.md` edits + decision doc) land in
   a single commit on the issue branch with the conventional-
   commits message in § Implementation steps step 7.

7. **Behavioral guarantee — observational, not a completion
   gate.** The next autonomous `/sr-implement` and
   `/prepare-for-review` invocations in the ralph pipeline are
   *more likely* to complete cleanly under the new contracts,
   especially at the `/sr-implement` Step 4→5 boundary
   (ENG-257/275 shape, where no nested `Skill` return is
   involved). The `/prepare-for-review` nested sub-skill boundary
   (ENG-294 shape) is mitigated only if the harness preserves
   `TaskList` state across nested `Skill` returns; if not, the
   anti-summary contract is the only active defense at that
   boundary. **Acceptance does not gate on a behavioral
   guarantee at either boundary.** If a fresh incident surfaces
   post-implementation, file as a separate follow-up rather than
   reopening this issue.

## References

- Upstream bug:
  [anthropics/claude-code#17351](https://github.com/anthropics/claude-code/issues/17351).
- Manifestations:
  - **ENG-294** (`/prepare-for-review` sub-skill boundary) session
    transcript at
    `~/.claude/projects/-Users-seankao-Workplace-Projects-sensible-ralph--worktrees-eng-294-write-docsdesignorchestratormd/723b2dc5-5ffc-414f-a2ab-adfa5cbe2ae4.jsonl`.
  - **ENG-257, ENG-275** (`/sr-implement` Step 4→5 boundary) —
    diagnosed by Sean during the ENG-307 dialogue. Session
    transcripts in `~/.claude/projects/`.
- Sibling pattern: `skills/sr-spec/SKILL.md` § Checklist — the
  TaskCreate imperative pattern this spec replicates.
- Anti-summary precedent: superpowers'
  `~/.claude/skills/finishing-a-development-branch/SKILL.md`
  line 85 (`**Don't add explanation** beyond what's shown.`) — a
  direct instance of the anti-summary class of instruction.
- Companion skills (chezmoi-managed; do NOT edit from this repo):
  `~/.claude/skills/update-stale-docs/SKILL.md`,
  `~/.claude/skills/capture-decisions/SKILL.md`,
  `~/.claude/skills/prune-completed-docs/SKILL.md`,
  `~/.claude/skills/codex-review-gate/SKILL.md`.
- Outcome classifier: `docs/design/outcome-model.md` § "The seven
  outcomes" — `exit_clean_no_review` row defines the failure shape
  this spec mitigates.
