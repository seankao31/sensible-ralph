---
name: prepare-for-review
description: Use when implementation is complete and tests pass, before handing off for human review. Runs doc/decision updates, codex review (all in one pass), posts a Linear comment with a review summary and QA plan, and moves the issue to In Review. Useful at the tail of autonomous sensible-ralph sessions AND interactive "I just finished this feature" handoffs.
model: sonnet
allowed-tools: Skill, Bash, Read, Glob, Grep, Write, Edit, TodoWrite, TaskCreate, TaskGet, TaskList, TaskUpdate
---

# Prepare for Review

Hand-off checklist for "implementation is done, tests pass, now it needs human review."

## When to Use

- **At the end of an autonomous sensible-ralph session** — the `sr-implement` skill's terminal step invokes `/prepare-for-review`.
- **At the end of an interactive implementation session** — when the user finishes a feature and wants the handoff polish done consistently.

Do NOT use this skill to cover up an incomplete implementation. If tests fail or the work isn't done, fix that first.

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
   Exit code per those handlers, typically `exit 1`. **Soft content-level cases do NOT belong in this bucket:** codex-review actionable findings must be fixed and re-run per Step 5; codex-review advisory findings and substantial PRD deviations must still produce the Step 6 handoff comment so the reviewer sees them; codex-review **deliverability-blocking** findings engage the halt path (legal final action 4); an "In Review" preflight state proceeds with idempotent rerun (legal final action 2). The carve-out is for objective preconditions that block the comment-or-transition path itself, not for content-level review states.
4. **Halt path (Step 5 deliverability-blocking finding)** — the full sequence of: reconcile-or-create follow-up Linear issues with provenance keys, idempotent `linear issue relation add ... blocked-by` writes, halt comment post (`linear issue comment add`, gated by the halt-marker dedup which skips the post but never exits the path), and a `linear issue view` state read followed by a conditional `linear issue update --state` that undoes any stale `In Review` left by a prior run. The terminal tool call is whichever of these runs last in the actual execution: on a first-run halt that finds the issue in `In Review` from a prior partial run, the terminal call is the `linear issue update` write; on a first-run halt where the state read shows `In Progress` (the common case), the terminal call is the `linear issue view` read; on a halt-comment-already-posted retry where the state is also already `In Progress`, the terminal call is still the `linear issue view` read. In all cases the issue ends up in `$CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE` *or* in whatever operator-set state the halt path declines to override (see the Halt path execution-order step 4 below for the narrow guard). Exit code is 0; the orchestrator classifies the run as `exit_clean_no_review` when the post-state is `In Progress` and applies `ralph-failed` — that label is the operator triage signal, consistent with the existing classification in `docs/design/outcome-model.md`.

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

## Companion skills

This skill is a workflow orchestrator — each step delegates to another skill. Steps 1, 2, 3, and 5 expect the following skills to be installed and discoverable:

- `update-stale-docs` — generic doc-sweep skill (Step 1)
- `capture-decisions` — records non-obvious implementation choices (Step 2)
- `prune-completed-docs` — archives superseded planning docs (Step 3)
- `codex-review-gate` — cross-model code review before handoff (Step 5)

If any of these is missing at invocation time, skip the step with a brief note and continue. Step 6 (Linear comment) and Step 7 (state transition) are self-contained — they invoke `linear` CLI directly and don't need any other skill.

## Load plugin-option defaults

Before running any state-name comparisons, source the plugin's defaults lib so `$CLAUDE_PLUGIN_OPTION_REVIEW_STATE`, `$CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE`, etc. are populated even if the user skipped the enable-time config dialog:

```bash
source "$CLAUDE_PLUGIN_ROOT/lib/defaults.sh"
```

## Determine the Linear issue ID

In sensible-ralph sessions, the agent receives the issue ID as the `/sr-implement` invocation argument and exposes it as `$ISSUE_ID`. In interactive sessions, derive it from the branch name:

```bash
ISSUE_ID=$(git rev-parse --abbrev-ref HEAD | grep -oiE '[A-Z]+-[0-9]+' | head -1)
```

If the branch name doesn't contain an issue ID (e.g., no `eng-123` slug), you must supply it manually. All subsequent shell commands use `$ISSUE_ID`.

## Idempotency check (run first, before any steps)

Check the current Linear issue state via the Linear CLI:

```bash
linear issue view "$ISSUE_ID" --json 2>/dev/null | jq -r '.state.name'
```

If the CLI fails (exits non-zero or returns empty output), the Linear API is unreachable from this environment. In that case, surface this to the reviewer and stop — do not attempt to complete the handoff without being able to verify state or post the review comment.

Expected states:

- **`$CLAUDE_PLUGIN_OPTION_REVIEW_STATE`** — proceed with the sequence, but skip Step 7 (the issue is already in the right state). The SHA-based dedup in Step 6 handles avoiding duplicate comments for the same HEAD. This allows re-running the skill after new commits are pushed to a branch that's still In Review.
- **`$CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE`** — proceed with the full sequence including Step 7.
- **Any other state** — stop and surface to the reviewer. Something is off with the dispatch lifecycle.

## Pre-flight: verify clean working tree

Before running any steps, verify that all implementation work is committed and no untracked files exist:

```bash
git status --short
```

The working tree must be **completely clean** (no output). Any lines in the output are stop conditions:

- **`M`, `D`, `A`, `R` lines** — uncommitted changes to tracked files. Commit them first.
- **`??` lines** — untracked files. Commit or remove them before running this skill. This includes scratch files in `docs/` or `memory/` — because Step 4 stages all new untracked files, any untracked files present at the start of this skill will end up in the docs commit.

Once the working tree is clean, any untracked files that appear during Steps 1–3 are guaranteed to have been created by the skill itself and are safe to stage in Step 4.

## Compute base SHA (do this before Step 1)

`BASE_SHA` is used in Steps 1, 5, and 6. `CURRENT_SHA` is used in Steps 5 (halt path) and 6; each path sets it at entry time (not here) so it reflects HEAD *after* any commits made by Steps 1–4.

Compute `BASE_SHA` now:

1. If `.sensible-ralph-base-sha` exists in the worktree root, read it:
   ```bash
   BASE_SHA=$(cat .sensible-ralph-base-sha)
   ```

2. Otherwise (interactive session), detect the trunk:
   ```bash
   TRUNK_REF=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)
   if [ -n "$TRUNK_REF" ]; then
     BASE_SHA=$(git merge-base HEAD "$TRUNK_REF")
   else
     # Try local branches first, then remote tracking refs
     TRUNK_REF=""
     git show-ref --verify --quiet refs/heads/main && TRUNK_REF=refs/heads/main
     [ -z "$TRUNK_REF" ] && git show-ref --verify --quiet refs/heads/master && TRUNK_REF=refs/heads/master
     [ -z "$TRUNK_REF" ] && git show-ref --verify --quiet refs/remotes/origin/main && TRUNK_REF=refs/remotes/origin/main
     [ -z "$TRUNK_REF" ] && git show-ref --verify --quiet refs/remotes/origin/master && TRUNK_REF=refs/remotes/origin/master
     if [ -z "$TRUNK_REF" ]; then
       echo "Cannot determine trunk. Set .sensible-ralph-base-sha or pass base SHA explicitly." >&2; exit 1
     fi
     BASE_SHA=$(git merge-base HEAD "$TRUNK_REF")
   fi
   ```

   **⚠ Stop if this might be a stacked branch.** For stacked branches (branching from a feature branch, not the trunk), `git merge-base HEAD <trunk>` includes parent-branch commits and scopes the doc sweep and review incorrectly. Provide `BASE_SHA` explicitly — the commit just before your first commit on this branch: `git rev-parse <your-first-commit>^`.

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
9. **Codex review gate** — invoke `codex-review-gate` with `--base "$BASE_SHA"`. Classify each finding into one of three buckets per the location-first rule:
   1. **Actionable** (root-cause fix entirely within touched-code set) — fix inline, commit, re-run gate.
   2. **Advisory** (need human judgment, deliverable still works) — capture in item 10's handoff comment.
   3. **Deliverability-blocking** (root-cause fix lands outside touched-code set AND the finding invalidates acceptance criteria) — engage the halt path:
      - Detect autonomous mode via `${SENSIBLE_RALPH_AUTONOMOUS:-}` (no prompt) vs interactive mode (single Y/n prompt over all bucket-3 findings).
      - For each finding: compute provenance key, reconcile-or-create a follow-up issue, idempotent `blocked-by` relation add.
      - Post the halt-specific comment (gated by `HALT_MARKER` dedup; gate skips post but does NOT exit the path).
      - State-restore step: read current state; only if `In Review`, transition back to `In Progress`.
      - Exit clean (exit 0). Skip items 10 and 11.
10. **Post Linear handoff comment** — write Review Summary + QA Test Plan to a tempfile and post via `linear issue comment add`. Skipped on the halt path.
11. **Transition Linear issue to In Review** — `linear issue update "$ISSUE_ID" --state "$CLAUDE_PLUGIN_OPTION_REVIEW_STATE"` (skip if already in that state). Skipped on the halt path.

## The Sequence (run in order)

### Step 1: Update stale docs

Invoke the `update-stale-docs` skill with `--base "$BASE_SHA"` so it scopes to committed branch work (`$BASE_SHA..HEAD`) rather than the working tree. The working-tree default is empty on a clean branch and would yield a no-op sweep. Using `$BASE_SHA` (not `main`) is correct for stacked branches too.

If the skill isn't installed, skip with a note: "update-stale-docs not installed — skipping doc sweep".

### Step 2: Capture decisions

Invoke the `capture-decisions` skill. Records any non-obvious implementation choices made during the session — the *why*, not the *what*.

**Note on commits:** `capture-decisions` ends with its own `git commit`. This means this workflow may produce two separate doc commits (one from Step 2, one from Step 4 covering prune changes). Both will be in the `$BASE_SHA..HEAD` codex review scope — no action needed.

If the skill isn't installed, skip with a note.

### Step 3: Prune completed docs

Invoke the `prune-completed-docs` skill. Removes or archives now-stale planning docs, decision scratch, superseded specs, etc.

If the skill isn't installed, skip with a note.

### Step 4: Commit doc/decisions changes

Steps 1–3 may have modified or created files. Commit them so the codex review in Step 5 sees the complete branch (including docs):

```bash
git status --short          # confirm only expected new files from Steps 1-3
git add -u                  # stage modifications to tracked files
NEW_FILES=$(git ls-files --others --exclude-standard)
[ -n "$NEW_FILES" ] && echo "$NEW_FILES" | xargs git add  # stage new files from doc skills (macOS-safe)
git diff --cached --quiet || git commit -m "docs: update stale docs and capture decisions"
```

The pre-flight required a clean working tree, so all untracked files staged here were created by the skill steps (Steps 1–3). The `--quiet` guard skips the commit if nothing changed.

### Step 5: Codex review gate

Invoke the `codex-review-gate` skill, passing `--base "$BASE_SHA"` (computed above) so the review is scoped to this branch's commits (code + docs).

**Handle findings here, not by escalating to the user mid-flow.** Each finding falls into exactly one of three buckets:

1. **Actionable** — a clear defect within scope, where the root-cause fix lies *entirely* within files in the touched-code set. Fix inline, commit, and re-run the gate. Repeat until no actionable findings remain.
2. **Advisory** — needs human judgment but the deliverable still works (design tradeoff, deferred scope question, stylistic concern, non-blocking edge case). Do NOT ask mid-flow and do NOT block the loop on them. Capture them in Step 6's `## Review Summary` (under "Surprises during implementation" or "Known gaps / deferred" as fits) so the human reviewer sees them with full context. The loop exits once no actionable findings remain; advisory ones are expected to persist until Step 6.
3. **Deliverability-blocking** — the finding's root-cause fix requires editing a file *outside* the touched-code set, AND a reviewer reading the issue description would conclude the feature does not deliver what was promised. **Halt path engages** (see "Step 5 halt path" below). Concrete examples:
   - Codex shows the new endpoint silently returns the wrong shape because of a bug in a shared serializer this ticket didn't touch.
   - Codex shows the new feature relies on a config flag that's never set anywhere — code reads it but no caller writes it.
   - The spec promised behavior X but X requires a missing helper that this ticket's scope didn't add.

**The classification rule.** Apply the steps in order; the *first* match wins:

1. **Does the root-cause fix lie *entirely* within files in the touched-code set?** That is, would all required modifications to make the feature meet its acceptance criteria edit only files already in `git diff --name-only $BASE_SHA..HEAD`? If yes — bucket 1 (actionable; fix inline, the active spec covers these files by the user-global `CLAUDE.md` "current task's scope" definition).
2. **Else, does the finding invalidate the feature's acceptance criteria?** I.e. would a reviewer reading the issue description conclude the feature does not deliver what was promised? If yes — bucket 3 (deliverability-blocking; halt).
3. **Else** — bucket 2 (advisory; capture in Step 6 summary, proceed).

**Scope is defined at file granularity.** The touched-code set is the file paths returned by `git diff --name-only $BASE_SHA..HEAD`. Region-level distinctions (which lines of `foo.ts` were touched vs which weren't) are out of scope for this rule.

The "*entirely*" qualifier in step 1 is load-bearing for mixed-scope findings. A finding can manifest in a touched file (an in-ticket test fails, an in-ticket wrapper exposes the bug) while the actual fix requires editing an *additional* file the ticket did not touch (a shared helper outside the touched set). In that mixed case, **the finding is bucket 3 (halt), not bucket 1**, because some required edit lands outside the touched-code set. A fix that lands partly out-of-ticket cannot honestly be called "in scope," and silently editing the shared helper in a ticket's branch hides cross-cutting changes from the reviewer.

The same-file caveat: if a finding requires editing a different *region* of a file the ticket already touched, the file is in the touched set, so step 1 says bucket 1. That is intentional. A ticket's branch "owns" the files it touches at the file-path level. If the ticket genuinely should not be touching that file at all, the reviewer can flag it at PR time.

The simplest implementer test: write down, in one sentence, the file paths the fix has to edit. If any of those paths is NOT in `git diff $BASE_SHA..HEAD --name-only`, the answer is bucket 3.

**When uncertain at any step, escalate to the higher-numbered bucket.** Specifically:

- Uncertain between bucket 1 and bucket 3 — default to bucket 3. This matches the user-global `CLAUDE.md` rule "when uncertain, treat as out of scope," and silently fixing off-ticket code conflates in-scope and out-of-scope work in a single commit, which the reviewer cannot easily separate.
- Uncertain between bucket 2 and bucket 3 — default to bucket 3. A false-positive halt costs operator triage time. A false-negative ship of a broken feature costs more — the DAG advances, descendants dispatch onto bad work, and the orchestrator's post-dispatch checks have no way to recover.

**Known limitation:** If the codex fix loop results in behavioral code changes, the doc/decision captures from Steps 1–3 may be slightly stale. For minor fixes (style, error handling) this is acceptable. For behavioral changes, re-run `/prepare-for-review` from the top on the updated branch.

If the `codex-review-gate` skill isn't installed, skip with a note. **Important:** in autonomous sensible-ralph sessions where review-before-merge is load-bearing, operators should install codex-review-gate before relying on the orchestrator; skipping this step silently weakens the safety pillar.

#### Step 5 halt path

The halt path engages once per run if any finding from the current codex pass is classified bucket 3. It files each blocking finding as a follow-up Linear issue, sets `blocked-by` relations on the parent, posts a halt-specific comment, and exits clean — skipping Step 6's regular handoff comment and Step 7's `In Review` transition. The orchestrator's existing classifier sees `exit 0 + In Progress` and treats the run as `exit_clean_no_review` (label `ralph-failed`, taint downstream); no new outcome class is introduced.

The halt path is a small idempotent state machine. A run that completes brings the parent issue from "halt decided" to "halt fully recorded" via three durable artifacts: (A) one follow-up issue per bucket-3 finding with a per-finding **provenance key** in its description; (B) one `blocked-by` relation per follow-up; (C) exactly one halt comment on the parent. A run that interrupts after some subset of A/B/C reconciles (does not duplicate) the existing artifacts on retry.

##### Autonomous-mode detection

The skill detects autonomous mode via the `SENSIBLE_RALPH_AUTONOMOUS` env var the orchestrator exports at dispatch time (see `docs/design/autonomous-mode.md`):

```bash
if [ "${SENSIBLE_RALPH_AUTONOMOUS:-}" = "1" ]; then
  AUTONOMOUS=1
else
  AUTONOMOUS=0
fi
```

This is a hard contract, not an inferred behavior. The agent does NOT infer autonomous-vs-interactive from preamble presence in context — that inference can fail silently: the agent might prompt anyway, the autonomous session has no stdin to receive an answer, the prompt sits as the session's last text without a tool call, and the orchestrator classifies the run as `exit_clean_no_review` (same final classification as a clean halt, but without the halt comment having posted). The env var collapses that failure mode to a deterministic branch.

##### Autonomous mode (`AUTONOMOUS=1`)

No prompt. The agent's bucket-3 judgment is final and the halt path engages immediately. This matches the autonomous preamble's escape-hatch pattern (`docs/design/autonomous-mode.md`): when human input would normally be required, the autonomous session takes the deterministic exit path.

##### Interactive mode (`AUTONOMOUS=0`)

Collect all bucket-3 findings from the current codex pass, present them together, and ask once:

> I'm classifying the following codex finding(s) as
> deliverability-blocking:
>
> - *<one-sentence why for finding 1>*
> - *<one-sentence why for finding N>*
>
> Halt? `[Y/n]`

Default Y. If the user answers `n`, all listed findings move to bucket 2 (advisory) and Step 5 continues. If the user answers `y` (or default), the halt path engages once with all listed findings folded into the single halt comment's "Blocking discoveries" section.

##### Provenance key (per-finding dedup)

Each bucket-3 finding gets a stable provenance key derived from a canonical tuple of identity-bearing fields. The body component is mandatory in the tuple (it's the *tail*, not a fallback): when codex emits structured metadata (file, line, rule id, title) those disambiguate near-collisions cheaply; when those fields are absent and the placeholders match across findings, the body component still distinguishes independent findings.

```bash
# Codex's review JSON exposes title, file, line_start, line_end, body,
# and (when present) a stable rule/category id. Body is normalized
# (whitespace collapsed, leading/trailing whitespace trimmed) before
# hashing so trivial reformatting doesn't change the key.
FINDING_BODY_NORMALIZED=$(printf '%s' "$FINDING_BODY" \
  | tr -s '[:space:]' ' ' \
  | sed -e 's/^ *//' -e 's/ *$//')
# Length-prefix each field (len:value) before joining with '|' to prevent
# ambiguity when field values themselves contain '|'. Two tuples that differ
# only in how '|' falls across a field boundary cannot collide under this
# encoding because the field lengths differ.
lf() { printf '%d:%s' "${#1}" "$1"; }
CANONICAL=$(printf '%s|%s|%s|%s|%s|%s' \
  "$(lf "${FINDING_FILE:-_}")" \
  "$(lf "${FINDING_LINE_START:-_}")" \
  "$(lf "${FINDING_LINE_END:-_}")" \
  "$(lf "${FINDING_RULE_ID:-_}")" \
  "$(lf "${FINDING_TITLE:-_}")" \
  "$(lf "$FINDING_BODY_NORMALIZED")")
FINDING_KEY=$(printf '%s' "$CANONICAL" | shasum -a 256 | cut -c1-16)
PROVENANCE_TAG="<!-- halt-finding: ${ISSUE_ID}/${FINDING_KEY} -->"
```

`$ISSUE_ID` is the parent (the ticket prepare-for-review is running on); `$FINDING_KEY` is the per-finding 16-hex truncated SHA-256 (64 bits of collision resistance — ample for the per-issue scale of single-digit findings). `$PROVENANCE_TAG` is embedded in the follow-up's description; this spec relies only on the substring being searchable via Linear's API, not on the HTML-comment rendering. If Linear ever renders the tag literally, UX degrades but correctness holds.

##### Reconcile-or-create algorithm (run for each bucket-3 finding)

```text
For each bucket-3 finding:
  Compute FINDING_KEY and PROVENANCE_TAG.
  Search for an existing follow-up issue whose description contains
    PROVENANCE_TAG.
  If found:
    Capture its issue ID as $blocker_id.
    Skip create.
  Else:
    Create the follow-up. Capture the new ID as $blocker_id.
    Embed PROVENANCE_TAG in the description (and the body the agent
    wrote per linear-workflow conventions).
  Append $blocker_id to $BLOCKER_ISSUE_IDS.
  linear issue relation add "$ISSUE_ID" blocked-by "$blocker_id"
```

The `relation add` call is idempotent on the Linear side: re-adding an existing `blocked-by` relation does not create a duplicate and exits 0. (The CLI prints "Created" on both first-add and re-add — misleading if you treat output as a truthful signal — but the underlying state is correct either way. Trust the post-condition, not the CLI's return surface; if a separate verification is needed elsewhere, query `linear_get_issue_blockers "$ISSUE_ID"`.) The relation step needs no pre-check for partial-failure retry.

Linear API search query for the existing-follow-up check:

```bash
linear api 'query($q: String!) { issues(filter: { description: { contains: $q } }, first: 5) { nodes { identifier } } }' \
  --variable "q=$PROVENANCE_TAG" \
  | jq -r '.data.issues.nodes[].identifier' | head -1
```

Reconciling existing follow-ups is what makes the halt path safely re-runnable. A retry after partial-failure re-discovers the already-filed issues by their provenance keys, fills in missing relations idempotently, and proceeds without duplicating Linear state.

##### Halt path execution order

Run these in order. Each step is idempotent per the algorithm above; on retry, completed steps no-op.

Before starting the sequence, capture the current revision:

```bash
CURRENT_SHA=$(git rev-parse HEAD)
```

This must be captured at halt-path entry — after Steps 1–4 may have committed docs or inline fixes — so the HALT_MARKER and halt comment footer reference the correct SHA.

1. **Reconcile-or-create the follow-up issues** (loop above). Output: `$BLOCKER_ISSUE_IDS` populated with one ID per bucket-3 finding.
2. **Reconcile-or-add `blocked-by` relations** (also handled by the loop above; the relation add is idempotent on Linear).
3. **Post the halt-specific comment** (template below) via `linear issue comment add --body-file` from a `mktemp` tempfile, gated by the halt-marker dedup:

   ```bash
   HALT_MARKER=$(printf 'Posted by `/prepare-for-review` halt path for revision `%s`' "$CURRENT_SHA")
   HALT_ALREADY_POSTED=$(linear api 'query($issueId: String!, $marker: String!) { issue(id: $issueId) { comments(filter: { body: { contains: $marker } }, first: 1) { nodes { id } } } }' \
     --variable "issueId=$ISSUE_ID" \
     --variable "marker=$HALT_MARKER" 2>/dev/null \
     | jq '((.data.issue.comments.nodes) // []) | length > 0')
   if [ "$HALT_ALREADY_POSTED" = "true" ]; then
     echo "halt comment for $CURRENT_SHA already posted; skipping repost" >&2
     # Fall through to step 4. Do NOT exit — see below.
   else
     linear issue comment add "$ISSUE_ID" --body-file "$COMMENT_FILE"
   fi
   ```

   **The halt-path dedup gates the comment post only. It MUST NOT short-circuit the halt path's exit.** Step 4 must run on every halt-path execution, including retries where the halt comment was already posted in a prior run that died before step 4 ran. An early `exit 0` here would skip step 4, leaving the issue in whatever state the prior partial-failure left it in (potentially `In Review` from a regular Step 7 that fired before the halt was decided), and the orchestrator's post-dispatch state read would misclassify the run as `in_review` (success).
4. **Undo a stale `In Review` post-state, if present.** Read the issue's current state. If — and *only if* — it is `$CLAUDE_PLUGIN_OPTION_REVIEW_STATE`, transition it back to `$CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE`:

   ```bash
   current_state=$(linear issue view "$ISSUE_ID" --json | jq -r '.state.name')
   if [ "$current_state" = "$CLAUDE_PLUGIN_OPTION_REVIEW_STATE" ]; then
     linear issue update "$ISSUE_ID" --state "$CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE"
   fi
   ```

   This step exists for one specific case: the halt path fires from a re-run of `/prepare-for-review` after the *prior* run had already transitioned the issue to `In Review` (e.g., user demoted bucket-3 findings interactively in the prior run, then changed their mind in this run; or codex review surfaces new findings on a re-invocation at the same SHA). Without this undo, the orchestrator's post-dispatch state read would see `In Review` and classify the run as `in_review` (success), defeating the halt mechanism.

   The guard is narrow on purpose: only `In Review` is undone. If an operator manually moved the issue to a different state (`Canceled`, `Done`, a custom holding state, etc.) between the two runs, the halt path leaves it alone — operator state wins. The orchestrator's classification will then read whatever state the operator chose; outside of `In Review`, the `exit_clean_no_review` outcome won't fire, but the halt comment and follow-ups have still been recorded for the operator to see. In the common case (Step 5 firing during a first-run prepare-for-review where Step 7 has not run yet) the read shows `In Progress` and the conditional skips entirely.
5. **Exit clean** with exit code 0. Do NOT run the regular Step 6 (handoff comment) or Step 7 (state transition). The issue's post-state depends on what the conditional in step 4 found:
   - If the read showed `In Review` → step 4 wrote `In Progress`. Orchestrator classifies as `exit_clean_no_review` (the intended outcome).
   - If the read showed `In Progress` → step 4 was a no-op. Orchestrator still classifies as `exit_clean_no_review`.
   - If the read showed any other state (operator manually moved to `Canceled`/`Done`/holding state between runs) → step 4 was a no-op, the operator's state is preserved, and the orchestrator's classification follows from that state per `docs/design/outcome-model.md` rather than necessarily reading as `exit_clean_no_review`. The halt comment and follow-up issues have been recorded regardless, so the operator still sees the halt context on the issue.

The halt path is the skill's terminal path for this invocation. Per the "Terminal action contract" section, the skill's last operation must be a tool call (typically the halt comment post or the `In Progress` restore; on a fully-reconciled retry where step 3's dedup hits and step 4's read shows the issue already in `In Progress`, the terminal tool call is the state read itself), not a markdown summary.

##### Halt comment template

Posted via `linear issue comment add --body-file`. Body:

```markdown
## Halt — deliverability blocked

`/prepare-for-review` halted because a discovery during the codex
review indicates the feature does not meet its acceptance criteria.
The issue remains in `In Progress`; do NOT merge.

**Blocking discoveries:**

- *<one-paragraph description of finding 1>* — filed as
  [ENG-AAA](<linear url>) (`blocked-by` set on this issue)
- *<one-paragraph description of finding N>* — filed as
  [ENG-NNN](<linear url>) (`blocked-by` set on this issue)

**Why these block deliverability:** <one-paragraph reasoning the
agent applied to classify the finding(s) as bucket 3 — one
paragraph total, not one per finding>

**Resume conditions:** <what needs to land before this ticket can
be re-attempted — typically "all listed follow-ups merged" but may
include caveats>

## Commits in this branch

<git log --oneline $BASE_SHA..HEAD output>

---
_Posted by `/prepare-for-review` halt path for revision `<SHA>`_
```

For the single-finding case, the "Blocking discoveries" list still renders correctly with one bullet — no separate single-finding template variant.

The footer `` _Posted by `/prepare-for-review` halt path for revision `<SHA>`_ `` is the dedup marker for the halt comment, disjoint from the regular handoff comment's `` _Posted by `/prepare-for-review` for revision `<SHA>`_ ``. Neither is a substring of the other, so each dedup query matches exactly one comment type.

##### Same-SHA path transition behavior

With disjoint markers AND the halt path's state-restore step (execution-order step 4), the dedup interaction is well-defined for the case where the same SHA sees both decisions across separate invocations:

- **Run A at SHA X posts a regular handoff comment and transitions the issue to `In Review`** (e.g., user demoted bucket-3 findings interactively; full normal Step 6/Step 7 path): `REGULAR_MARKER` matches on retry of Step 6. `HALT_MARKER` does NOT match. Issue state is `In Review`.
- **Run B at SHA X engages the halt path:** `HALT_MARKER` does not match the regular comment, so the halt path proceeds, posts the halt comment, then runs the state-restore step. The state read shows `In Review`, so the conditional write transitions back to `In Progress`. The issue now carries both comments and is in `In Progress`. Operator sees the halt comment as the most recent. The orchestrator's post-dispatch state read sees `In Progress` and classifies the run as `exit_clean_no_review`.
- **Run B's earlier reconcile-or-create loop** finds the previously filed follow-ups (by provenance key) — even if Run A had filed none (because A demoted to advisory), Run B's loop creates them cleanly.
- **Run C at SHA X is another retry of the halt path:** `HALT_MARKER` matches → step 3 skips repost. Step 4's state read shows `In Progress` (Run B already restored), so step 4's conditional write is also skipped. Exit clean. The reconcile loop's existing-issue check finds the already-filed follow-ups and no-ops.

The transition from advisory to halt at the same SHA is allowed, recorded by both comments existing on the issue, and the post-state contract holds because of the explicit state restore. The reverse transition (halt → advisory at the same SHA) is not supported in autonomous mode, because once the halt path has filed follow-ups and posted the halt comment, the run is terminal. In interactive mode, if the user changes their mind after a halt comment was posted, manual cleanup is required (delete the halt comment, cancel the follow-up issues, remove the `blocked-by` relations) — out of scope for this skill; file separately if it becomes a real workflow.

### Step 6: Post Linear handoff comment

First check whether a handoff comment for this specific revision was already posted (handles retries after partial failures, without suppressing re-runs after feedback commits):

```bash
CURRENT_SHA=$(git rev-parse HEAD)
REGULAR_MARKER=$(printf 'Posted by `/prepare-for-review` for revision `%s`' "$CURRENT_SHA")
ALREADY_POSTED=$(linear api 'query($issueId: String!, $marker: String!) { issue(id: $issueId) { comments(filter: { body: { contains: $marker } }, first: 1) { nodes { id } } } }' \
  --variable "issueId=$ISSUE_ID" \
  --variable "marker=$REGULAR_MARKER" 2>/dev/null \
  | jq '((.data.issue.comments.nodes) // []) | length > 0')
```

The marker (the regular handoff comment's footer substring) is unique per HEAD AND disjoint from the halt path's footer (see "Halt path" below — its marker contains the extra `halt path` token), so the server-side `body.contains` filter returns at most one match for the regular handoff comment regardless of how many comments the issue has. `linear issue comment list` isn't suitable here — it returns only the first ~50 comments with no cursor flag exposed, so a prior handoff comment on a long-running issue could sit on a later page and go undetected.

If `ALREADY_POSTED` is `true`, skip to Step 7.

**If the `linear` CLI is unavailable:** Stop immediately — the handoff cannot complete without the CLI. The comment posting in the next step also requires it, so there's no point continuing.

Include the revision footer as the last line of the comment body so the SHA-based dedup check can find it on retry.

Otherwise, post a comment using this template. Fill every section; empty sections signal the skill was run mechanically.

Write the body to a tempfile first (Linear CLI prefers `--body-file` for multi-paragraph markdown), then post. Use `mktemp` for the path so concurrent sensible-ralph sessions don't clobber each other:

```bash
COMMENT_FILE=$(mktemp /tmp/ralph-handoff-XXXXXX)

# Heading
printf '## Review Summary\n\n' > "$COMMENT_FILE"

# Static body — quoted heredoc keeps backticks (and $) literal
cat >> "$COMMENT_FILE" <<'COMMENT'
**What shipped:** <1-3 sentence summary of the implementation>

**Deviations from the PRD:** <bulleted list of anything that differs from the issue description; "None" if identical>

**Surprises during implementation:** <bulleted list of things the PRD didn't anticipate; "None" if clean>

**Known gaps / deferred:** <anything intentionally left unfinished; "None" if complete>

**Documentation changes:** <bulleted list of decisions captured and docs pruned this session; "None" if nothing>
- Decision: <file:line or path> — <one-sentence summary>
- Pruned: <path> — <one-sentence reason>

## QA Test Plan

**Golden path:** <specific manual steps to verify the core behavior works>

**Edge cases worth checking:** <bulleted list of risky paths — what was tricky to get right, what boundary conditions exist>
COMMENT

# Dynamic: commits section header + actual git log output
printf '\n## Commits in this branch\n\n' >> "$COMMENT_FILE"
git log --oneline "$BASE_SHA"..HEAD >> "$COMMENT_FILE"

# Revision footer (visible dedup marker + provenance)
printf '\n---\n\n_Posted by `/prepare-for-review` for revision `%s`_\n' "$CURRENT_SHA" >> "$COMMENT_FILE"

linear issue comment add "$ISSUE_ID" --body-file "$COMMENT_FILE"
rm -f "$COMMENT_FILE"
```

Verify the exact CLI syntax against `linear issue comment add --help` at invocation time if uncertain — do not guess flags.

**If the `linear` CLI fails:** Surface the error and stop — this skill cannot complete the handoff without Linear.

### Step 7: Transition Linear issue to In Review

**This is the skill's terminal step.** Complete the existing state-read-then-conditional-write sequence below without emitting a markdown summary first. The legitimate terminal output is either the `linear issue update --state "$CLAUDE_PLUGIN_OPTION_REVIEW_STATE"` write or the no-op exit when the state read shows the issue is already in `$CLAUDE_PLUGIN_OPTION_REVIEW_STATE`. A summary message between the state-read and the conditional write — or after either of them — is NOT a legal terminal action. See the Terminal action contract at the top of this skill.

Check current state, skip the write if it's already In Review (avoids activity-feed noise on retry), otherwise transition:

```bash
current_state=$(linear issue view "$ISSUE_ID" --json 2>/dev/null | jq -r '.state.name')
if [ "$current_state" != "$CLAUDE_PLUGIN_OPTION_REVIEW_STATE" ]; then
  linear issue update "$ISSUE_ID" --state "$CLAUDE_PLUGIN_OPTION_REVIEW_STATE" || {
    echo "prepare-for-review: failed to transition $ISSUE_ID to $CLAUDE_PLUGIN_OPTION_REVIEW_STATE" >&2
    echo "  The handoff comment has already been posted; retry the transition by hand:" >&2
    echo "    linear issue update $ISSUE_ID --state \"$CLAUDE_PLUGIN_OPTION_REVIEW_STATE\"" >&2
    exit 1
  }
fi
```

Direct `linear` CLI call. The `--json`-then-branch pattern preserves the "don't write if already there" guarantee that keeps Linear's activity feed clean on retry after partial failures.

## Red Flags / When to Stop

- **Tests are failing.** Do NOT run this skill. Fix tests first.
- **`codex-review-gate` returns actionable findings.** Fix them, re-run the gate. Do not move to In Review with known blocking issues unsurfaced.
- **`codex-review-gate` returns deliverability-blocking findings.** Engage the halt path (legal final action 4) — this is a *legitimate* exit, distinct from the precondition failures listed here. The terminal tool call is whichever of comment-post / state-read / state-update ran last for the invocation (see "Terminal action contract" → action 4 and the "Step 5 halt path" subsection). Exit code is 0; the orchestrator's post-dispatch state read typically sees the issue in `In Progress` and classifies the run as `exit_clean_no_review` — same operator triage path as a hard failure, but reached deliberately. If an operator manually moved the issue to a state other than `In Review` between runs, the halt path preserves that state (step 4 of the halt path is `In Review`-only) and the classification follows from whatever state the operator chose.
- **The QA test plan is empty or generic.** Stop and actually think about what a reviewer needs to verify — the agent that wrote the code knows the risky paths, and capturing them at handoff is the cheap moment.
- **Deviations from the PRD are substantial enough they need discussion.** Post the comment anyway (the reviewer will see it), but flag loudly in the Review Summary section.
- **Linear state is unexpected** (not `$CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE` and not `$CLAUDE_PLUGIN_OPTION_REVIEW_STATE`). Something is off with the dispatch lifecycle — stop and surface to the reviewer.
