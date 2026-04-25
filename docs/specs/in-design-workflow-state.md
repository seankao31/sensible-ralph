# Add "In Design" workflow state between Todo and Approved

**Linear:** ENG-273
**Date:** 2026-04-25

## Goal

Add a new Linear workflow state, **"In Design"**, positioned between
`Todo` and `Approved`. The state signals that a human has picked up an
issue and is actively running an interactive design/spec session
(typically `/ralph-spec`), distinct from autonomous implementation
(`In Progress`, owned by `/ralph-start`).

State machine after this change:

```
Todo → In Design → Approved → In Progress → In Review → Done
```

## Motivation

Today an issue jumps from `Todo` directly to `Approved` when
`/ralph-spec` finishes its dialogue. There is no board-level signal
that an interactive design session is in progress between those two
states. Operators looking at Linear can't tell whether a `Todo` issue
is genuinely idle or whether a human is mid-dialogue on it; running a
second `/ralph-spec` against the same ticket is awkward to detect.

`In Progress` cannot fill this gap because `/ralph-start`'s queue
builder treats `In Progress` as "autonomous implementation in flight";
mixing the two semantics would break dispatch.

## Scope

Four edits across two files in this repo, plus one autonomous Linear
GraphQL mutation per team (ENG and GAM) at implementation time. No
test additions — all four edits are config / prose / Linear-side, none
of them branch the orchestrator scripts.

The `linear-workflow` skill (in chezmoi, **Agent Config** project) is
**out of scope** here and filed as a follow-up issue with
`blocked-by ENG-273`.

### Edit 1 — `.claude-plugin/plugin.json`

Add a `design_state` userConfig entry mirroring the existing
state-name entries:

```jsonc
"design_state": {
  "type": "string",
  "title": "In-Design state name",
  "description": "Linear workflow state while an interactive /ralph-spec session is open (default: In Design)",
  "default": "In Design"
}
```

Place it before `approved_state` to mirror the workflow order.

### Edit 2 — `skills/ralph-start/scripts/lib/defaults.sh`

Add the shell-side default and export, mirroring the existing
state-name defaults:

```bash
: "${CLAUDE_PLUGIN_OPTION_DESIGN_STATE=In Design}"
```

Add the matching `export CLAUDE_PLUGIN_OPTION_DESIGN_STATE` line in
the export block. Update the file's comment block ("The defaults
mirror the plugin.json userConfig defaults — update in lockstep") if
needed; the new entry is part of that lockstep.

### Edit 3 — `skills/ralph-spec/SKILL.md` step 1 (Resolve issue context)

Currently step 1 reads:

> if called with an issue-id argument, set `ISSUE_ID=<arg>` and fetch
> its current description as starting context. Otherwise leave
> `ISSUE_ID` unset; it will be created in step 10.

Extend it so that when `ISSUE_ID` is set and the issue's current state
is in `{Todo, Backlog, Triage}`, the skill transitions the issue to
`$CLAUDE_PLUGIN_OPTION_DESIGN_STATE` immediately, before the dialogue
begins. Concretely, after the existing fetch, run:

```bash
if [ -n "${ISSUE_ID:-}" ]; then
  VIEW=$(linear issue view "$ISSUE_ID" --json)
  STATE=$(echo "$VIEW" | jq -r '.state.name')
  PRIOR=$(echo "$VIEW" | jq -r '.description // empty')

  case "$STATE" in
    Todo|Backlog|Triage)
      linear issue update "$ISSUE_ID" \
        --state "$CLAUDE_PLUGIN_OPTION_DESIGN_STATE" \
        || echo "ralph-spec: failed to transition $ISSUE_ID to '$CLAUDE_PLUGIN_OPTION_DESIGN_STATE'; continuing with dialogue" >&2
      ;;
  esac
fi
```

Behavior notes:

- The transition is **best-effort**. If it fails (auth blip, the state
  doesn't exist on this team, etc.), the skill logs to stderr and
  continues. The design dialogue is the load-bearing part; the board
  signal is nice-to-have.
- States outside `{Todo, Backlog, Triage}` get their existing step 10
  preflight treatment with no early transition. In particular, an
  issue already in `In Design` is left in `In Design` (re-running
  `/ralph-spec` to continue an open dialogue is legitimate); an issue
  in `Approved` goes through the existing "warn on overwrite" flow.
- Sourcing `defaults.sh` to make `$CLAUDE_PLUGIN_OPTION_DESIGN_STATE`
  available is already done in step 10's finalization. For step 1 we
  source it at the top of the skill's shell snippet, the same way
  step 10 does.

### Edit 4 — `skills/ralph-spec/SKILL.md` step 10 substep 2 (Preflight)

Update the preflight branching list. The current branches are:

- Equals `$CLAUDE_PLUGIN_OPTION_DONE_STATE` or `Canceled`: stop and ask.
- Equals `$CLAUDE_PLUGIN_OPTION_APPROVED_STATE`: warn (overwriting prior
  spec).
- Equals `$CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE` or
  `$CLAUDE_PLUGIN_OPTION_REVIEW_STATE`: stop and ask.
- Anything else (typically `Todo`, `Backlog`, or `Triage`): proceed.

After the change, the "anything else" bullet reads:

> Anything else (typically `Todo`, `Backlog`, `Triage`, or
> `$CLAUDE_PLUGIN_OPTION_DESIGN_STATE`): proceed.

This is documentation only — the `In Design` state already falls into
"anything else" today; the bullet just names it explicitly so a future
reader knows it's intentional and not an oversight. No code branch
changes.

### Linear state creation (autonomous, idempotent)

Performed once per team at implementation time. The autonomous session
runs the following sequence for each of `ENG` and `GAM`:

1. Resolve the team UUID via `linear team list --json` (no hard-coded
   IDs in any committed file).
2. Query existing states for the team:
   ```graphql
   query($teamId: String!) {
     team(id: $teamId) {
       states(first: 50) {
         nodes { id name type position color }
       }
     }
   }
   ```
3. **Idempotency guard:** if a state named `"In Design"` (case-
   insensitive match) already exists for this team, skip creation for
   this team and log "already present, skipping".
4. Otherwise compute:
   - `position`: midpoint between the existing `Todo` and `Approved`
     states' positions. (Linear renders states in ascending position
     order.) If either is missing, fail with a clear message — this is
     not a state-machine the plugin recognizes.
   - `color`: clone the `Approved` state's color. Operators can adjust
     in the Linear UI later.
   - `description`: `"Interactive design/spec session in progress
     (e.g. /ralph-spec)."`
   - `type`: `"unstarted"`.
5. Create the state via `linear api`:
   ```graphql
   mutation($input: WorkflowStateCreateInput!) {
     workflowStateCreate(input: $input) {
       success
       state { id name type position }
     }
   }
   ```
6. Verify by re-running the team-states query and asserting the new
   state is present with `type: "unstarted"` and `Todo.position <
   "In Design".position < Approved.position`.

If any team's mutation fails after the others have succeeded, the
session leaves a Linear comment on ENG-273 listing which teams landed
the state and which didn't, then exits clean. A follow-up rerun is
idempotent because of step 3.

**Reversibility:** if the state needs to be removed later, archive via
`workflowStateArchive(id: <state-id>)`. Not automated; documented in
the spec for operators.

## Out of scope

Explicitly excluded from this issue:

- **`linear-workflow` skill update** in chezmoi (Agent Config project).
  Filed as a follow-up issue with `blocked-by ENG-273` so it picks up
  automatically once this lands. The chezmoi orchestrator's queue
  builder will skip the follow-up while ENG-273 is mid-flight (because
  `Sensible Ralph` is not in chezmoi's `.ralph.json` scope) and pick it
  up once ENG-273 reaches `In Review` or `Done` — that's the intended
  cross-project blocker behavior, not a bug.
- `/ralph-start`, `/prepare-for-review`, `/close-issue`,
  `/ralph-implement` skill markdown — none of them read or write the
  new state. `build_queue.sh` and `preflight_scan.sh` query for
  `Approved` only; `In Design` issues are deliberately not picked up
  by the orchestrator.
- README and `docs/usage.md` narrative — they describe the pipeline
  using "Approved" as the entry point into automation. That description
  remains accurate after this change.
- Bats tests — none of the changes touch surfaces covered by the bats
  suite. The autonomous run is itself the integration test, with codex
  review at handoff catching edit drift.

## Verification

After the implementation lands, all of the following must hold:

1. `jq . .claude-plugin/plugin.json` exits 0, and
   `jq -e '.userConfig.design_state.default == "In Design"' .claude-plugin/plugin.json`
   exits 0.
2. `bash -c 'set -e; source skills/ralph-start/scripts/lib/defaults.sh; printf "%s\n" "$CLAUDE_PLUGIN_OPTION_DESIGN_STATE"'`
   prints `In Design`.
3. `grep -n "CLAUDE_PLUGIN_OPTION_DESIGN_STATE" skills/ralph-spec/SKILL.md`
   shows the variable referenced in step 1 (the start-of-session
   transition) and in step 10's preflight list.
4. For each of `ENG` and `GAM`, the GraphQL query
   `team(id) { states { nodes { name type position } } }` returns a
   state named `In Design` with `type = "unstarted"` and a `position`
   strictly between the team's `Todo` and `Approved` positions.
5. `linear issue view ENG-273 --json | jq -r '.state.name'`
   returns `In Review` (set by `/prepare-for-review`).

The autonomous session itself runs verification 1-4 inline and aborts
before handoff if any fail.

## Testing expectations

No new automated tests. The four edits are:

- `plugin.json` — JSON, validated by `jq`.
- `defaults.sh` — one variable assignment + one export, validated by
  sourcing in a clean shell.
- `SKILL.md` — markdown, validated by reading.
- Linear states — validated by the GraphQL query in verification 4.

The codex review at `/prepare-for-review` catches any drift on the
markdown edits. TDD does not apply: there is no production-code branch
in the orchestrator scripts that changes here.

## Prerequisites

None. This issue stands alone — it depends on existing ralph plumbing
(`scope.sh`, `defaults.sh`, `/ralph-spec`) which is all in place.

## Alternatives considered

1. **Single autonomous PR — chosen.** One ralph session does the
   GraphQL state creation, the `plugin.json` userConfig, the
   `defaults.sh` export, and the `/ralph-spec` skill edits. Matches the
   plugin's autonomous-overnight ethos; the GraphQL mutation is small
   and idempotent.

2. **Two-phase split.** Operator runs the GraphQL mutations
   interactively (or in the Linear UI), autonomous session does only
   the code edits. Lower autonomy, smaller blast radius for the
   autonomous session. Rejected because the mutations are simple
   enough to automate and the project's stated direction is "more
   autonomous, not less".

3. **Setup-script style.** Autonomous session ships an idempotent
   `scripts/setup-workflow-states.sh`, operator runs it once. Reusable
   for fresh installs. Rejected: introduces permanent surface area
   (a script that lives in the repo forever) for a one-off action,
   and the README's existing setup instructions don't currently use
   that pattern.

4. **Hard-code `"In Design"` in the skill instead of plumbing through
   `plugin.json` userConfig.** Smaller diff. Rejected because it
   breaks the existing pattern (every other workflow state name is
   userConfig-skinnable) and would force a follow-up "make this
   configurable" issue if any operator ever needs a different name.

5. **Use a different state name** ("Speccing", "In Spec", "Drafting",
   etc.). Considered during the design dialogue. "In Design" chosen
   because it's the broadest framing — it covers any interactive
   design work, not just `/ralph-spec`, and matches product-management
   vocabulary.

## Notes

- The `In Design` state already implicitly falls into the "anything
  else / proceed" branch of `/ralph-spec`'s step 10 preflight today,
  before this change lands. Edit 4 names it explicitly only as
  documentation; the runtime behavior of that branch does not change.
- `/ralph-start`'s queue builder reads `Approved` only. `In Design`
  issues will never be picked up by the autonomous orchestrator —
  that's the intended semantics.
- Color and position picked at creation time can be adjusted later in
  the Linear UI without breaking anything: the autonomous session
  reads state names, not colors or positions.
