# Ralph Implement: Replace config.json Prompt Template with a Dispatched Skill

**Linear issue:** ENG-206
**Date:** 2026-04-21
**Revises:** `2026-04-17-ralph-loop-v2-design.md` Decision 2 ("Minimal prompt template; trust CLAUDE.md and skill descriptions")

## Problem

The ralph orchestrator dispatches each Linear issue via `claude -p "$prompt"`, where `$prompt` is rendered from the `prompt_template` string in `agent-config/skills/ralph-start/config.json`. Two independent issues with the current shape:

1. **Weak enforcement of the terminal `/prepare-for-review` step.** The template is a natural-language paragraph that *asks* the session to invoke `/prepare-for-review` when implementation is done. The orchestrator's `exit_clean_no_review` outcome exists specifically because this ask sometimes fails — the session exits clean without transitioning Linear state. The existing outcome model labels and taints after the fact, but the root ask is a paragraph in a prompt, not a contract the session is executing against.

2. **The workflow is not per-installation configuration.** Putting the session recipe in `config.json` implies operators should tune it. In practice, the workflow (read PRD → resolve conflicts → implement → tests pass → `/prepare-for-review`) is a fixed recipe that belongs with the orchestrator's source code, not alongside values that legitimately vary per workspace (`project`, state names, `model`). The type confusion shows up ergonomically too: a multi-line markdown-ish paragraph embedded in a JSON string is awkward to edit and review in diffs.

## Design

Replace the `prompt_template` string with a new skill, `ralph-implement`, that encodes the per-session workflow as numbered SKILL.md steps. The orchestrator dispatches the skill via slash-command invocation; the workflow recipe becomes source code rather than configurable data.

### The `ralph-implement` skill

Location: `agent-config/skills/ralph-implement/SKILL.md`. Co-located with `ralph-start` (its natural sibling; both are orchestrator-facing). The `agent-config/skills/` tree is chezmoi-symlinked into `~/.claude/skills/`, making the skill globally discoverable; `disable-model-invocation: true` prevents accidental auto-fire outside orchestrator dispatch.

Frontmatter:

```yaml
---
name: ralph-implement
description: Dispatched by the ralph orchestrator to implement a single Linear issue autonomously inside a pre-created worktree. Do NOT auto-invoke.
disable-model-invocation: true
argument-hint: <issue-id>
allowed-tools: Skill, Bash, Read, Glob, Grep, Write, Edit
---
```

Body — numbered steps:

1. **Read the PRD** — `linear issue view "$ISSUE_ID" --json | jq -r .description`. The description is the spec.
2. **Check for unresolved merge conflicts** — `git status --short`. If the orchestrator pre-merged a parent branch into this worktree, resolve conflicts before implementing the feature.
3. **Implement per the PRD** — follow agent-config conventions: TDD, systematic-debugging on failures, smallest reasonable changes.
4. **Verify tests pass.**
5. **Invoke `/prepare-for-review`** — *only if steps 3–4 are clean*. `prepare-for-review` runs the doc sweep, decisions capture, codex review, posts the handoff comment, and transitions Linear to In Review.

Red flags that stop the session WITHOUT invoking `/prepare-for-review`:
- PRD is empty or clearly malformed (orchestrator's pre-flight should have caught this; belt-and-suspenders).
- Merge conflicts from pre-merged parents that can't be resolved confidently.
- Tests fail and can't be fixed within the session.
- `linear` CLI is unreachable (can't read PRD).

On any stop condition, do NOT invoke `/prepare-for-review`. Leave the Linear issue in `In Progress`. The orchestrator's post-dispatch state check classifies this as `exit_clean_no_review`, labels `ralph-failed`, and taints downstream issues — which is the correct signal to the operator.

### Orchestrator dispatch change

`scripts/orchestrator.sh` lines 449–452 (the template-render block) become a single-line dispatch prompt:

```bash
local prompt="/ralph-implement $issue_id"
```

The `claude -p` invocation itself (line 464) is unchanged — same flags, same `--name`, same tee-to-log plumbing. Only the content of `$prompt` changes.

The orchestrator still computes `issue_id`, `title`, `branch`, `path` the same way and still `cd`s into the worktree before dispatch. The title, branch, and worktree variables stop flowing into the dispatch string because they aren't functionally used — the agent reads title from Linear, derives branch from `git`, and runs in the worktree as cwd. This matches the precedent set by `/close-feature-branch ENG-NNN`.

### Config and loader changes

- `config.json` and `config.example.json`: drop the `prompt_template` key.
- `scripts/lib/config.sh`: drop the `"RALPH_PROMPT_TEMPLATE:prompt_template"` entry from the `keys` array and update the exports list in the header comment.
- `agent-config/skills/ralph-start/SKILL.md` prerequisites section: drop `prompt_template` from the "Required keys" sentence.

### Test changes

- `scripts/test/config.bats`: drop the assertion that the loaded template contains `"prepare-for-review"` (and any other `RALPH_PROMPT_TEMPLATE` / `prompt_template` assertions).
- `scripts/test/orchestrator.bats`: update any expected-prompt assertion to match `/ralph-implement <issue-id>` (the claude stub captures argv).

## Validation

1. All bats tests pass under the updated assertions.
2. Manual dogfood: run `/ralph-start` on a low-stakes Approved Linear issue. Verify the dispatched session:
   - invokes `/ralph-implement`,
   - reaches `/prepare-for-review` on success,
   - transitions Linear to `In Review` (classified as `in_review` in `progress.json`).
3. Observation window over the next 3–5 real ralph dispatches. Track the rate of `exit_clean_no_review` outcomes. The bet option A is making: a structured numbered SKILL.md reduces drift past the terminal step vs. a prompt paragraph. Evidence for or against is soft at this sample size, but if the rate clearly doesn't drop, the enforcement argument didn't pay off and a follow-up (tighter skill wording, different dispatch shape) is warranted. The configuration cleanup (concern #2) is independent and stands regardless.

## Files to change

- **New:** `agent-config/skills/ralph-implement/SKILL.md`
- **Modified:** `agent-config/skills/ralph-start/config.json`
- **Modified:** `agent-config/skills/ralph-start/config.example.json`
- **Modified:** `agent-config/skills/ralph-start/SKILL.md` (prereqs list)
- **Modified:** `agent-config/skills/ralph-start/scripts/lib/config.sh`
- **Modified:** `agent-config/skills/ralph-start/scripts/orchestrator.sh`
- **Modified:** `agent-config/skills/ralph-start/scripts/test/config.bats`
- **Modified:** `agent-config/skills/ralph-start/scripts/test/orchestrator.bats`
- **Note added to:** `agent-config/docs/specs/2026-04-17-ralph-loop-v2-design.md` — Decision 2 is superseded; add a brief pointer at the top of that section referencing ENG-206 and this design. The ralph v2 doc is a frozen-in-time decision record and is not rewritten.

## Out of scope

- Any change to how the orchestrator computes `issue_id`, `title`, `branch`, `worktree_path`. The runtime data flow is unchanged; only the destination of the dispatch message changes.
- `prepare-for-review` itself — the terminal step is unchanged; this ticket only changes how a session gets pointed at it.
- Any change to the `exit_clean_no_review` outcome's classification, labeling, or taint semantics. Option A's bet is that the outcome fires *less often* under the new dispatch; the mechanism around it stays as-is.
- Migration for historical `config.json` files. The config loader simply stops requiring/exporting `prompt_template`; a stale key in a user's local config is ignored.
- Parallel dispatch, PR creation, or any other ralph v2 non-goal.

## Follow-ups

None anticipated at design time. If the observation window in Validation shows the `exit_clean_no_review` rate unchanged, file a follow-up to investigate whether tighter skill wording, different dispatch shape, or a mandatory post-implementation `/prepare-for-review` invocation is warranted.
