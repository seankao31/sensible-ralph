---
name: prepare-for-review
description: Use when implementation is complete and tests pass, before handing off for human review. Runs doc/decision updates, codex review (all in one pass), posts a Linear comment with a review summary and QA plan, and moves the issue to In Review. Useful at the tail of autonomous sensible-ralph sessions AND interactive "I just finished this feature" handoffs.
model: sonnet
allowed-tools: Skill, Bash, Read, Glob, Grep, Write, Edit
---

# Prepare for Review

Hand-off checklist for "implementation is done, tests pass, now it needs human review."

## When to Use

- **At the end of an autonomous sensible-ralph session** — the `ralph-implement` skill's terminal step invokes `/prepare-for-review`.
- **At the end of an interactive implementation session** — when the user finishes a feature and wants the handoff polish done consistently.

Do NOT use this skill to cover up an incomplete implementation. If tests fail or the work isn't done, fix that first.

## Companion skills

This skill is a workflow orchestrator — each step delegates to another skill. Steps 1-5 expect the following skills to be installed and discoverable:

- `update-stale-docs` — generic doc-sweep skill (Step 1)
- `capture-decisions` — records non-obvious implementation choices (Step 2)
- `prune-completed-docs` — archives superseded planning docs (Step 3)
- `clean-branch-history` — folds fixups into logical commits (Step 4)
- `codex-review-gate` — cross-model code review before handoff (Step 5)

If any of these is missing at invocation time, skip the step with a brief note and continue. Step 6 (Linear comment) and Step 7 (state transition) are self-contained — they invoke `linear` CLI directly and don't need any other skill.

## Load plugin-option defaults

Before running any state-name comparisons, source the plugin's defaults lib so `$CLAUDE_PLUGIN_OPTION_REVIEW_STATE`, `$CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE`, etc. are populated even if the user skipped the enable-time config dialog:

```bash
source "$CLAUDE_PLUGIN_ROOT/skills/ralph-start/scripts/lib/defaults.sh"
```

## Determine the Linear issue ID

In sensible-ralph sessions, the agent receives the issue ID as the `/ralph-implement` invocation argument and exposes it as `$ISSUE_ID`. In interactive sessions, derive it from the branch name:

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
- **`??` lines** — untracked files. Commit or remove them before running this skill. This includes scratch files in `docs/` or `memory/` — because Step 3.5 stages all new untracked files, any untracked files present at the start of this skill will end up in the docs commit.

Once the working tree is clean, any untracked files that appear during Steps 1–3 are guaranteed to have been created by the skill itself and are safe to stage in Step 3.5.

## Compute base SHA (do this before Step 1)

The base SHA is used in Steps 1, 5, and 6. Compute it once now so all steps stay consistent:

1. If `.ralph-base-sha` exists in the worktree root, read it:
   ```bash
   BASE_SHA=$(cat .ralph-base-sha)
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
       echo "Cannot determine trunk. Set .ralph-base-sha or pass base SHA explicitly." >&2; exit 1
     fi
     BASE_SHA=$(git merge-base HEAD "$TRUNK_REF")
   fi
   ```

   **⚠ Stop if this might be a stacked branch.** For stacked branches (branching from a feature branch, not the trunk), `git merge-base HEAD <trunk>` includes parent-branch commits and scopes the doc sweep and review incorrectly. Provide `BASE_SHA` explicitly — the commit just before your first commit on this branch: `git rev-parse <your-first-commit>^`.

## The Sequence (run in order)

### Step 1: Update stale docs

Invoke the `update-stale-docs` skill with `--base "$BASE_SHA"` so it scopes to committed branch work (`$BASE_SHA..HEAD`) rather than the working tree. The working-tree default is empty on a clean branch and would yield a no-op sweep. Using `$BASE_SHA` (not `main`) is correct for stacked branches too.

If the skill isn't installed, skip with a note: "update-stale-docs not installed — skipping doc sweep".

### Step 2: Capture decisions

Invoke the `capture-decisions` skill. Records any non-obvious implementation choices made during the session — the *why*, not the *what*.

**Note on commits:** `capture-decisions` ends with its own `git commit`. This means this workflow may produce two separate doc commits (one from Step 2, one from Step 3.5 covering prune changes). Both will be in the `$BASE_SHA..HEAD` codex review scope — no action needed.

If the skill isn't installed, skip with a note.

### Step 3: Prune completed docs

Invoke the `prune-completed-docs` skill. Removes or archives now-stale planning docs, decision scratch, superseded specs, etc.

If the skill isn't installed, skip with a note.

### Step 3.5: Commit doc/decisions changes

Steps 1–3 may have modified or created files. Commit them so the history cleanup in Step 4 and codex review in Step 5 see the complete branch (including docs):

```bash
git status --short          # confirm only expected new files from Steps 1-3
git add -u                  # stage modifications to tracked files
NEW_FILES=$(git ls-files --others --exclude-standard)
[ -n "$NEW_FILES" ] && echo "$NEW_FILES" | xargs git add  # stage new files from doc skills (macOS-safe)
git diff --cached --quiet || git commit -m "docs: update stale docs and capture decisions"
```

The pre-flight required a clean working tree, so all untracked files staged here were created by the skill steps (Steps 1–3). The `--quiet` guard skips the commit if nothing changed.

### Step 4: Clean branch history

Invoke the `clean-branch-history` skill with `--base "$BASE_SHA"` to fold feedback-driven fixups, "try X + revert X" pairs, and review-feedback commits into clean logical units. Codex (next step) then reviews coherent history, and the commit list posted in the Linear comment (Step 6) reads clearly for the human reviewer.

`clean-branch-history` uses the `--base "$BASE_SHA"` computed earlier (protecting against stacked-branch breakage), creates and verifies its own safety ref, checks tree-hash integrity, and has a single-commit early-exit — the invocation is unconditional and self-contained. On re-runs of `/prepare-for-review` (e.g., after review-feedback commits land on a branch that's still In Review), this step folds the new fixes into their corresponding commits so each handoff snapshot stays clean.

If the skill isn't installed, skip with a note.

### Step 5: Codex review gate

Invoke the `codex-review-gate` skill, passing `--base "$BASE_SHA"` (computed above) so the review is scoped to this branch's commits (code + docs after history cleanup).

**Handle findings here, not by escalating to the user mid-flow:**

- **Actionable findings** (clear defect, missing edge case, anything you can address with confidence) — fix them, commit, and re-run the gate. Repeat until no actionable findings remain.
- **Ambiguous findings** (need human judgment — design tradeoff, deferred scope question, anything where the right call isn't obvious) — do NOT ask mid-flow and do NOT block the loop on them. Capture them in Step 6's `## Review Summary` (under "Surprises during implementation" or "Known gaps / deferred" as fits) so the human reviewer sees them with full context. The loop exits once no actionable findings remain; ambiguous ones are expected to persist until Step 6.

**Known limitation:** If the codex fix loop results in behavioral code changes, the doc/decision captures from Steps 1–3 may be slightly stale. For minor fixes (style, error handling) this is acceptable. For behavioral changes, re-run `/prepare-for-review` from the top on the updated branch.

If the `codex-review-gate` skill isn't installed, skip with a note. **Important:** in autonomous sensible-ralph sessions where review-before-merge is load-bearing, operators should install codex-review-gate before relying on the orchestrator; skipping this step silently weakens the safety pillar.

### Step 6: Post Linear handoff comment

First check whether a handoff comment for this specific revision was already posted (handles retries after partial failures, without suppressing re-runs after feedback commits):

```bash
CURRENT_SHA=$(git rev-parse HEAD)
MARKER="<!-- review-sha: $CURRENT_SHA -->"
ALREADY_POSTED=$(linear api 'query($issueId: String!, $marker: String!) { issue(id: $issueId) { comments(filter: { body: { contains: $marker } }, first: 1) { nodes { id } } } }' \
  --variable "issueId=$ISSUE_ID" \
  --variable "marker=$MARKER" 2>/dev/null \
  | jq '((.data.issue.comments.nodes) // []) | length > 0')
```

The `<!-- review-sha: ... -->` marker is unique per HEAD, so the server-side `body.contains` filter returns at most one match regardless of how many comments the issue has. `linear issue comment list` isn't suitable here — it returns only the first ~50 comments with no cursor flag exposed, so a prior handoff comment on a long-running issue could sit on a later page and go undetected.

If `ALREADY_POSTED` is `true`, skip to Step 7.

**If the `linear` CLI is unavailable:** Stop immediately — the handoff cannot complete without the CLI. The comment posting in the next step also requires it, so there's no point continuing.

Include `<!-- review-sha: $CURRENT_SHA -->` as the first line of the `## Review Summary` section in the comment body so the SHA-based dedup check can find it on retry.

Otherwise, post a comment using this template. Fill every section; empty sections signal the skill was run mechanically.

Write the body to a tempfile first (Linear CLI prefers `--body-file` for multi-paragraph markdown), then post. Use `mktemp` for the path so concurrent sensible-ralph sessions don't clobber each other:

```bash
COMMENT_FILE=$(mktemp /tmp/ralph-handoff-XXXXXX)

# Dynamic prefix: heading + dedup marker
printf '## Review Summary\n<!-- review-sha: %s -->\n\n' "$CURRENT_SHA" > "$COMMENT_FILE"

# Static body — quoted heredoc keeps backticks (and $) literal
cat >> "$COMMENT_FILE" <<'COMMENT'
**What shipped:** <1-3 sentence summary of the implementation>

**Deviations from the PRD:** <bulleted list of anything that differs from the issue description; "None" if identical>

**Surprises during implementation:** <bulleted list of things the PRD didn't anticipate; "None" if clean>

**Documentation changes:** <bulleted list of decisions captured and docs pruned this session; "None" if nothing>
- Decision: <file:line or path> — <one-sentence summary>
- Pruned: <path> — <one-sentence reason>

## QA Test Plan

**Golden path:** <specific manual steps to verify the core behavior works>

**Edge cases worth checking:** <bulleted list of risky paths — what was tricky to get right, what boundary conditions exist>

**Known gaps / deferred:** <anything intentionally left unfinished; "None" if complete>
COMMENT

# Dynamic footer: commits section header + actual git log output
printf '\n## Commits in this branch\n\n' >> "$COMMENT_FILE"
git log --oneline "$BASE_SHA"..HEAD >> "$COMMENT_FILE"

linear issue comment add "$ISSUE_ID" --body-file "$COMMENT_FILE"
rm -f "$COMMENT_FILE"
```

Verify the exact CLI syntax against `linear issue comment add --help` at invocation time if uncertain — do not guess flags.

**If the `linear` CLI fails:** Surface the error and stop — this skill cannot complete the handoff without Linear.

### Step 7: Transition Linear issue to In Review

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
- **`codex-review-gate` returns blocking findings.** Fix them, re-run the gate. Do not move to In Review with known blocking issues unsurfaced.
- **The QA test plan is empty or generic.** Stop and actually think about what a reviewer needs to verify — the agent that wrote the code knows the risky paths, and capturing them at handoff is the cheap moment.
- **Deviations from the PRD are substantial enough they need discussion.** Post the comment anyway (the reviewer will see it), but flag loudly in the Review Summary section.
- **Linear state is unexpected** (not `$CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE` and not `$CLAUDE_PLUGIN_OPTION_REVIEW_STATE`). Something is off with the dispatch lifecycle — stop and surface to the reviewer.
