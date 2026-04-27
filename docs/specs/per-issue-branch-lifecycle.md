# Unify Linear-issue lifecycle on a per-issue branch/worktree

**Linear:** ENG-279
**Date:** 2026-04-27

## Goal

Unify the Linear-issue lifecycle on a single branch and worktree per
issue, from `/sr-spec` through `/sr-start` through
`/prepare-for-review` and the merge ritual. Each issue's branch and
worktree are created exactly once (at `/sr-spec` step 7, lazily) and
torn down only at `/close-issue`. All intermediate phases —
implementation, codex review, handoff — operate inside the same
worktree on the same branch.

This subsumes ENG-231 (retry-flow design): a `ralph-failed` issue's
branch and worktree are exactly the orchestrator's reuse-path target,
so removing the `ralph-failed` label and re-queuing works without a
separate `ralph-retry` label.

It also supersedes ENG-252 (codex-review-gate-on-spec, cancelled): the
gate runs on the issue's own branch — full per-issue isolation, no
temporary worktree, no parent-contamination race.

## Symptoms this resolves

1. **Codex review of specs is contaminated by concurrent main commits**
   (ENG-252's failure mode). Per-issue branch from spec time eliminates
   the contamination — codex `--base "$SPEC_BASE_SHA"` scopes to the
   branch's own commits.
2. **Failed-dispatch retries fight the worktree** (ENG-231). With
   per-issue worktrees as the default, "reuse existing" is the
   always-path. `local_residue` narrows to genuine partial-state
   anomalies (path without branch, or branch without path).
3. **Spec and implementation drift in time.** The branch is pinned at
   spec time, so unrelated `main` movement after spec approval doesn't
   sneak into implementation. (Parent-branch advancement is a separate
   matter; the orchestrator merges in-review parents at dispatch — see
   "Orchestrator reuse path" below.)

## Architecture

```
/sr-spec ENG-NNN
  step 1     resolve issue context, re-entrancy preflight, transition to In Design
  step 2-5   dialogue (operator's existing CWD, no branch yet)
  step 6     present design, get approval
  step 6.5   resolve or create Linear issue (NEW step)
  step 7     create branch + worktree, capture SPEC_BASE_SHA, write spec, commit
  step 8     spec self-review
  step 9     user reviews spec
  step 10    codex review gate (NEW step — was ENG-252)
  step 11    finalize: push spec to Linear description, set blockers, transition Approved
                                              ↓
[overnight: spec lives on the branch, NOT on main]
                                              ↓
/sr-start
  per-issue:
    branch_or_worktree_exists for ENG-NNN?
      YES  →  cd into worktree, merge in-review parents, write base-sha, dispatch
      NO   →  create from dag_base output (today's flow), write base-sha, dispatch
                                              ↓
/sr-implement runs in worktree, adds impl commits
                                              ↓
/prepare-for-review reads .sensible-ralph-base-sha, scopes codex/handoff to impl commits
                                              ↓
/close-issue → close-branch merges branch (spec + impl) to main in one merge commit
```

### `.sensible-ralph-base-sha` lifecycle

Single file, written once. Lifecycle:

- **`/sr-spec` step 7:** captures `SPEC_BASE_SHA` in shell, **does NOT
  write the file.** `SPEC_BASE_SHA` = trunk SHA at branch creation
  (fresh issue) OR prior-spec HEAD (re-run on Approved).
- **`/sr-spec` step 10 codex gate:** `--base "$SPEC_BASE_SHA"` →
  diff = this session's spec commits only.
- **`/sr-start` orchestrator dispatch:** AFTER the merge attempt
  completes (regardless of outcome) and BEFORE `linear_set_state In
  Progress`, writes `.sensible-ralph-base-sha = $(git rev-parse HEAD)`.
  Two sub-cases in the reuse path:
  - **Clean merge:** HEAD = the merge commit. Parent commits are now
    ancestors of base-sha → excluded from `/prepare-for-review` diff.
  - **Single-parent conflict (leave-for-agent):** git is in MERGING
    state; HEAD has NOT advanced — it is still the pre-merge commit
    (the spec's last commit). base-sha = spec HEAD. The agent's
    conflict-resolution commit will therefore be **in scope** for
    `/prepare-for-review`'s codex review and handoff summary. This is
    intentional: resolving merge conflicts is implementation work that
    warrants review, not something to exclude. The fallback create path
    always writes post-create HEAD (no conflict possible at creation).
- **`/prepare-for-review`:** reads the file as today; `--base` scopes
  to impl commits only (parent merges and spec commits are ancestors,
  excluded).
- **`/close-issue` stale-parent detection:** does NOT read the file —
  migrates to `git merge-base --is-ancestor` ancestry check (see
  "close-issue stale-parent migration" below).

This timing shift fixes a latent INTEGRATION-mode bug: today's
orchestrator captures `base_sha` BEFORE parent merges (`git rev-parse
$SENSIBLE_RALPH_DEFAULT_BASE_BRANCH` for INTEGRATION), so codex review
of an INTEGRATION-mode session sees parents' content. Writing
post-merge in all paths makes the contract uniform.

### Orchestrator reuse path

```
_dispatch_issue ENG-NNN:
  branch  = linear_get_issue_branch
  base    = dag_base.sh  →  trunk | <parent> | INTEGRATION ...
  path    = worktree_path_for_issue $branch
  state   = worktree_branch_state_for_issue $branch $path
  case $state in
    both_exist)
      # The reuse path. Common case under ENG-279.
      # 1. cd into the worktree.
      # 2. For in-review parents (parsed from $base output), merge sequentially.
      #    Single-parent conflict: leave for agent (today's behavior).
      #    Multi-parent conflict: abort, setup_failed.
      #    A no-op merge (parent already an ancestor) is fine.
      # 3. .sensible-ralph-base-sha = $(git rev-parse HEAD)  ← post-merge
      # 4. linear_set_state In Progress
      # 5. dispatch /sr-implement
      ;;
    neither)
      # Fallback path. Manual issues, legacy pre-ENG-279 state.
      # Same as today: worktree_create_at_base or _with_integration.
      # Always write base-sha post-merge (INTEGRATION bug fix above).
      ;;
    partial)
      # Genuine local_residue: path without branch, or branch without path.
      # Operator state we cannot interpret. Record local_residue, no Linear
      # mutation, no taint, continue with next issue.
      ;;
  esac
```

## `/sr-spec` SKILL.md changes

### Step 1 — re-entrancy preflight

Replace the current step 1 logic with a state-and-residue matrix. The
shell snippet captures the state, decides on transition, and on
re-entry finds the existing branch+worktree to resume in.

State decision table (note `STATE` is the issue's pre-`/sr-spec` state):

| `STATE` | Branch+worktree existence | Action |
|---|---|---|
| `Todo` / `Backlog` / `Triage` | Should be neither | Transition → `In Design`. If branch and/or worktree exist anyway, refuse with a stale-residue cleanup hint quoting the manual recipe (see "Cancellation cleanup" below). Track the original state for rollback at finalize step 2 (existing pattern). |
| `In Design` | Branch+worktree may or may not exist (depends on whether prior session reached step 7) | Resume. No transition (already in target state). If branch+worktree exist, dialogue continues; step 7 detects existing state and `cd`s in. If they don't exist, normal flow. |
| `$CLAUDE_PLUGIN_OPTION_APPROVED_STATE` | Branch+worktree should exist | Warn user: "this is a re-spec; the prior approved spec on the branch will be appended to and the Linear description will be overwritten." Confirm before proceeding. Transition `Approved → In Design` (re-mark for the new dialogue) — track for rollback at finalize step 2 in case of scope-check abort. Step 7 detects existing branch+worktree and `cd`s in. |
| `$CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE` / `$CLAUDE_PLUGIN_OPTION_REVIEW_STATE` | Branch likely has impl commits | Refuse with: "Issue is in `<state>`; re-speccing on top of implementation commits is a manual unwind. Either revert implementation work first, or cancel this issue and file a new one." Provide manual cleanup recipe. |
| `$CLAUDE_PLUGIN_OPTION_DONE_STATE` | Branch likely already merged | Refuse: "Issue is Done. Open a new issue for follow-up work." |
| `Canceled` | Branch may exist locally | Refuse: "Issue is Canceled. Either reopen it via Linear UI before re-running, or file a new issue." |

Implementation:

```bash
source "$CLAUDE_PLUGIN_ROOT/lib/defaults.sh"
source "$CLAUDE_PLUGIN_ROOT/lib/linear.sh"
source "$CLAUDE_PLUGIN_ROOT/lib/scope.sh"
source "$CLAUDE_PLUGIN_ROOT/lib/worktree.sh"  # NEW location after relocation

if [ -n "${ISSUE_ID:-}" ]; then
  STATE=$(linear issue view "$ISSUE_ID" --json | jq -r '.state.name')
  branch=$(linear_get_issue_branch "$ISSUE_ID")
  path=$(worktree_path_for_issue "$branch")
  residue=$(worktree_branch_state_for_issue "$branch" "$path")  # both_exist | neither | partial

  case "$STATE" in
    Todo|Backlog|Triage)
      if [ "$residue" != "neither" ]; then
        echo "sr-spec: ENG-279 residue check — branch '$branch' or worktree '$path' exists, but issue is in '$STATE' (expected fresh)." >&2
        echo "  This is stale state from a cancelled/interrupted prior session." >&2
        echo "  Manual cleanup: git worktree remove --force \"$path\" 2>/dev/null; git branch -D \"$branch\" 2>/dev/null" >&2
        exit 1
      fi
      linear issue update "$ISSUE_ID" --state "$CLAUDE_PLUGIN_OPTION_DESIGN_STATE" \
        || echo "sr-spec: failed to transition $ISSUE_ID to '$CLAUDE_PLUGIN_OPTION_DESIGN_STATE'; continuing with dialogue" >&2
      # Track in conversation context: original state was $STATE; this invocation transitioned to In Design.
      ;;
    "$CLAUDE_PLUGIN_OPTION_DESIGN_STATE")
      # Resume. No transition. Step 7 will check $residue and cd in if both_exist.
      ;;
    "$CLAUDE_PLUGIN_OPTION_APPROVED_STATE")
      echo "sr-spec: $ISSUE_ID is Approved. Re-spec will append to the existing branch and overwrite the Linear description on finalize." >&2
      echo "  Continue? (yes/no)" >&2
      # Wait for explicit user confirmation.
      # On confirmation, transition Approved → In Design (track for rollback).
      ;;
    "$CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE"|"$CLAUDE_PLUGIN_OPTION_REVIEW_STATE")
      echo "sr-spec: $ISSUE_ID is in '$STATE'; re-speccing on top of implementation work is out of scope." >&2
      echo "  Either revert implementation work first, or cancel this issue and file a new one." >&2
      exit 1
      ;;
    "$CLAUDE_PLUGIN_OPTION_DONE_STATE")
      echo "sr-spec: $ISSUE_ID is Done. Open a new issue for follow-up work." >&2
      exit 1
      ;;
    Canceled)
      echo "sr-spec: $ISSUE_ID is Canceled. Reopen via Linear UI before re-running, or file a new issue." >&2
      exit 1
      ;;
    *)
      # Unknown state — refuse rather than guess.
      echo "sr-spec: $ISSUE_ID has unexpected state '$STATE'." >&2
      exit 1
      ;;
  esac
fi
```

### Step 6.5 — Resolve or create Linear issue (NEW)

Insert between steps 6 and 7. Two cases:

- **`ISSUE_ID` already set** (operator passed an arg): no-op. Issue already verified in step 1.
- **`ISSUE_ID` unset**: run today's finalize-step-3 issue-creation logic now. Specifically:
  1. Source `lib/scope.sh` (if not already sourced).
  2. Resolve `$TARGET_PROJECT` from `$SENSIBLE_RALPH_PROJECTS` (one-project case: use directly; multi-project case: ask the user to pick).
  3. Run the duplicate-prevention scan (`linear issue query --project "$TARGET_PROJECT" --search "<keyword>"`).
  4. Create the Linear issue (`linear issue create --project "$TARGET_PROJECT" --title "<title>" --state "Todo" --no-description`).
  5. Capture `ISSUE_ID` and immediately transition to `$CLAUDE_PLUGIN_OPTION_DESIGN_STATE` (matches step 1's transition for the with-arg case).
  6. Track in conversation context: this invocation created the issue and transitioned it.

Finalize-step-3 becomes a no-op (`ISSUE_ID` already exists by the time finalize runs); the duplicate-prevention scan moves into step 6.5.

### Step 7 — Create branch+worktree, capture SPEC_BASE_SHA, write spec, commit (UPDATED)

Replace the current step 7 (which writes `docs/specs/<topic>.md` with no branch) with the branch-aware variant.

```bash
# Resolve branch + worktree paths.
ISSUE_BRANCH=$(linear_get_issue_branch "$ISSUE_ID")
WORKTREE_PATH=$(worktree_path_for_issue "$ISSUE_BRANCH")

# Either reuse (Approved re-spec or interrupted In Design with prior step-7 commit)
# or create. worktree_branch_state_for_issue distinguishes the cases.
state=$(worktree_branch_state_for_issue "$ISSUE_BRANCH" "$WORKTREE_PATH")
case "$state" in
  both_exist)
    # Re-run path. Branch+worktree from prior /sr-spec session.
    # cd in. SPEC_BASE_SHA = current branch HEAD (= prior-spec HEAD).
    cd "$WORKTREE_PATH"
    SPEC_BASE_SHA=$(git rev-parse HEAD)
    ;;
  neither)
    # Fresh path. Create branch off default base, cd in.
    worktree_create_at_base "$WORKTREE_PATH" "$ISSUE_BRANCH" "$SENSIBLE_RALPH_DEFAULT_BASE_BRANCH" \
      || { echo "sr-spec: worktree create failed for $ISSUE_BRANCH" >&2; exit 1; }
    cd "$WORKTREE_PATH"
    SPEC_BASE_SHA=$(git rev-parse HEAD)
    ;;
  partial)
    echo "sr-spec: partial residue (branch '$ISSUE_BRANCH' or worktree '$WORKTREE_PATH' exists in isolation)." >&2
    echo "  Manual cleanup required:" >&2
    echo "    git worktree remove --force \"$WORKTREE_PATH\" 2>/dev/null" >&2
    echo "    git branch -D \"$ISSUE_BRANCH\" 2>/dev/null" >&2
    exit 1
    ;;
esac

# Write spec doc and commit. The doc is committed on the branch — NOT on
# main. It will arrive on main when /close-issue merges the branch.
TOPIC="<short kebab-case summary, picked from the approved design>"
SPEC_FILE="docs/specs/${TOPIC}.md"

if [ -e "$SPEC_FILE" ] && [ "$state" != "both_exist" ]; then
  # File-exists guard, only on first-time spec creation. On re-spec
  # (both_exist), the file IS expected to exist and will be overwritten.
  echo "sr-spec: $SPEC_FILE already exists. Stop and ask the operator." >&2
  exit 1
fi

# Write the approved spec content. (Model handles the actual content.)
# Then:
git add "$SPEC_FILE"
git commit -m "docs(spec): <verb-first imperative, e.g. 'add per-issue branch lifecycle spec'>

Ref: $ISSUE_ID"
```

`SPEC_BASE_SHA` is consumed by step 10 (codex gate) below; not persisted
to the file. `.sensible-ralph-base-sha` is NOT written by `/sr-spec`.

### Step 8-9 — Spec self-review and user review (unchanged)

If user-review iteration produces additional commits on the branch
(operator requests changes), `SPEC_BASE_SHA` stays the same — the gate
in step 10 sees all spec changes from this session.

### Step 10 — Codex review gate (NEW)

Insert between step 9 and finalize. ENG-252's bucket policy and focus
text carry forward verbatim; ENG-252's temp-worktree wrapper is
dropped because we are already on the issue's own branch.

#### Purpose

The autonomous implementer follows the spec literally with no human
in the loop, so spec-time codex probing is the last chance to catch
mechanism-level defects before dispatch. Adversarial probing of
user-approved decisions IS the value — no escape hatch exists for
findings that contradict prior dialogue. Present findings to the user
honestly; the user decides whether to revise or keep the original
call. A decision that survives adversarial probing is stronger than
one that was never tested.

#### Detection (graceful degradation)

```bash
CODEX_SCRIPT=$(find ~/.claude/plugins -name 'codex-companion.mjs' -path '*/openai-codex/*/scripts/*' 2>/dev/null | head -1)
```

If empty, log this exact warning verbatim and proceed to step 11:

> codex-review-gate not installed — skipping codex spec review.
> Operators relying on this gate for autonomous-safety guarantees
> should install it.

If non-empty, continue.

#### Run the gate (we are already on the branch, in the worktree)

```bash
node "$CODEX_SCRIPT" review --json --base "$SPEC_BASE_SHA" || {
  echo "sr-spec: standard codex review failed; gate aborted" >&2
  exit 1
}
node "$CODEX_SCRIPT" adversarial-review --json --base "$SPEC_BASE_SHA" "<focus text>" || {
  echo "sr-spec: adversarial codex review failed; gate aborted" >&2
  exit 1
}
```

`<focus text>` defaults to:

> Probe this design for: (1) ambiguities an autonomous implementer
> would misinterpret — places where two reasonable readings produce
> different code; (2) mechanism-level claims that don't hold under
> scrutiny — interfaces, return values, side effects, error contracts
> asserted by prose; (3) missing failure modes — what happens when
> the assumed inputs/state don't hold; (4) scope creep or hidden
> coupling — does this spec quietly reach into systems it shouldn't?

Override condition: if the spec has a salient targeted risk
(concurrency, auth, data integrity, integration boundary), write
per-spec focus text naming the mechanism and failure mode per
`codex-review-gate`'s "Targeted-risk prompts" guidance. The default is
a backstop, not a ceiling.

#### Three finding buckets (caller policy)

Same as ENG-252's design:

1. **Trivially actionable** — clear defect, prose tightening,
   ambiguity fix that doesn't change a mechanism, contract, or scope
   boundary.
   *Action:* fix inline → commit (new commit, don't amend) → re-run
   the gate. `SPEC_BASE_SHA` stays the same; new commits accumulate
   on the branch and codex sees the cumulative diff.

2. **Substantial actionable** — mechanism redesign, missed failure
   mode, scope change, contract correction.
   *Action:* loop back to step 7 (rewrite the spec doc, new commit) →
   re-run self-review (step 8) → re-ask user (step 9) → re-run the
   gate (step 10). `SPEC_BASE_SHA` stays the same.

3. **User judgment / contradicts prior dialogue** — finding is
   ambiguous, requires a design call, or pushes back on a decision
   the user already made.
   *Action:* present to the user → user decides → apply as agreed
   (becomes bucket 1 or 2 in size). No escape hatch — adversarial
   probing of user-approved decisions IS the value.

#### Skip criterion (re-runs only)

First-run on an issue: the gate **always** invokes codex.

Re-runs on an issue already in `$CLAUDE_PLUGIN_OPTION_APPROVED_STATE`:
the gate **may** be skipped if the diff against the prior approved
spec is purely cosmetic (typo, formatting, prose clarification with no
change to acceptance criteria, mechanism, scope, or interface). The
prior approved spec is the previous commit on the branch (or the
common ancestor of branch and `$SENSIBLE_RALPH_DEFAULT_BASE_BRANCH` if
the operator force-fetches a different reference); compute via
`git diff <prior-approved> HEAD -- "$SPEC_FILE"`. When in doubt, run.

#### Convergence

No max-iteration count. Trust user judgment. Genuinely-out-of-scope
findings get filed as Linear follow-up issues, not crammed into this
spec.

### Step 11 — Finalize Linear issue (renumbered from current step 10)

Existing finalize-step structure is mostly unchanged. Substantive
differences:

- **Sub-step 1 (load scope loader):** unchanged.
- **Sub-step 2 (preflight target issue):** the state branch on
  `$CLAUDE_PLUGIN_OPTION_DESIGN_STATE` is now the common case
  (re-entrancy-preflight transitioned us there at step 1). Existing
  rollback-on-scope-mismatch logic still applies.
- **Sub-step 3 (resolve target project / create issue):** becomes a
  no-op — issue creation already happened at step 6.5.
- **Sub-step 4 (preserve prior description):** unchanged.
- **Sub-step 5 (push spec, set blockers, verify):** unchanged.
- **Sub-step 6 (transition state to Approved):** unchanged.

The branch and worktree persist after finalize. They are NOT torn
down. `/sr-start` will find them at next dispatch.

## Cancellation cleanup

With lazy step-7 creation, residue only exists if the operator
advances past step 7 (commits a spec doc) and then abandons or cancels
the issue. The recipe is documented in `/sr-spec`'s "Red flags / when
to stop" section:

```bash
# Operator manually cancels the issue in Linear, then:
git worktree remove --force "<repo>/.worktrees/eng-NNN-<slug>" 2>/dev/null
git branch -D eng-NNN-<slug> 2>/dev/null
```

A standalone `/sr-cleanup` skill is **out of scope** for this issue.
Defer until pain is observed.

## `/sr-start` orchestrator changes

Edit `skills/sr-start/scripts/orchestrator.sh::_dispatch_issue` to
implement the reuse-vs-create branching described in "Architecture →
Orchestrator reuse path" above.

### Concrete edits in `_dispatch_issue`

1. After `worktree_path_for_issue` returns `$path`, call new helper
   `worktree_branch_state_for_issue "$branch" "$path"` (added in
   `lib/worktree.sh` — see "Module relocations" below). It returns one
   of: `both_exist`, `neither`, `partial`.
2. Replace the current pre-existence check (which lands `local_residue`
   if either path or branch exists) with a `case` on the helper's
   output:

   - `both_exist`: take the **reuse path**. The orchestrator's own CWD
     stays at the repo root (today's invariant per
     `docs/design/worktree-contract.md` "CWD convention"); all
     worktree-side git operations use `git -C "$path"`. The existing
     dispatch subshell that does `(cd "$path"; claude -p ...)` for
     dispatch is unchanged.
     1. Parse `$base_out` from `dag_base.sh`:
        - `$SENSIBLE_RALPH_DEFAULT_BASE_BRANCH`: no parents to merge;
          fast path.
        - single parent (token without spaces, not `INTEGRATION ...`):
          `git -C "$path" merge "$parent" --no-edit`. Use the same
          conflict policy as `worktree_create_at_base` does for
          fresh-create today (single-parent: leave conflicts for the
          agent; agent's `/sr-implement` Step 2 detects via
          `git status --short` and resolves).
        - `INTEGRATION <p1> <p2> ...`: sequential `git -C "$path"
          merge "$p_i" --no-edit`. Use `worktree_merge_parents` (NEW
          helper — see below) which mirrors today's
          `worktree_create_with_integration` conflict semantics:
          single-parent leave-for-agent, multi-parent abort + return
          non-zero. On non-zero return: `_record_setup_failure
          "$issue_id" "worktree_merge_parents" "$timestamp"`.
        - For each parent, ref resolution accepts both `refs/heads/$p`
          and `refs/remotes/origin/$p` (today's behavior in
          `worktree_create_at_base`). A parent already an ancestor of
          the branch's HEAD merges as a no-op.
     2. Write `.sensible-ralph-base-sha = $(git -C "$path" rev-parse
        HEAD)`. In the clean-merge case HEAD = the merge commit. In
        the single-parent conflict (leave-for-agent) case HEAD = the
        pre-merge spec commit (MERGING state, no merge commit yet).
        Both cases are correct — see the "`.sensible-ralph-base-sha`
        lifecycle" section in Architecture for the intentional
        semantics of each.
     3. `linear_set_state "$issue_id" "$CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE"`.
     4. Continue to dispatch as today.
   - `neither`: take the **fallback create path** (today's behavior).
     1. `worktree_create_at_base` or `worktree_create_with_integration`.
     2. Write `.sensible-ralph-base-sha`. **Important timing change**:
        for INTEGRATION mode, capture `base_sha = $(git -C "$path"
        rev-parse HEAD)` AFTER the helper returns (post-merge HEAD),
        not before any merges. This fixes today's INTEGRATION-mode bug
        where the base-sha pointed at trunk pre-merge and codex review
        included parents' content. Today's `worktree_create_at_base`
        path already captures post-create HEAD; `worktree_create_with_integration`
        is the one that needs the fix. The orchestrator's surrounding
        code (`if [[ "$base_out" == "main" ]] ... elif INTEGRATION ...
        else ...`) collapses to "create-via-helper, then write base-sha
        from current HEAD" — drop the per-branch `base_sha=` capture
        in the INTEGRATION case.
     3. `linear_set_state In Progress` (unchanged).
     4. Continue to dispatch.
   - `partial`: record `local_residue` (no Linear mutation, no taint —
     today's `_record_local_residue` semantics unchanged), continue
     with next issue. Extract the cause from the helper's tab-separated
     output and include it in the diagnostic so the operator knows
     exactly what to clean up:

     ```bash
     printf 'orchestrator: partial residue for %s — %s exists in isolation. Manual cleanup required.\n' \
       "$issue_id" "$(echo "$cause" | tr '\n' ' ')" >&2
     ```

3. Remove the existing pre-existence check that produces `local_residue`
   on `[[ -e "$path" ]] || git show-ref --verify --quiet "refs/heads/$branch"`.
   Replaced by the new state-based dispatch above.

### `dag_base.sh` is unchanged

`dag_base.sh` continues to emit `<trunk>`, `<parent>`, or `INTEGRATION
<p1> <p2> ...` based on the in-review-blocker count. Under ENG-279 the
output is consumed differently in the reuse path (interpret as "what
to merge in") vs the fallback path (interpret as "what to branch
from"), but the script itself doesn't need to change.

## `.sensible-ralph-base-sha` lifecycle (consolidated)

| Actor | Read | Write |
|---|---|---|
| `/sr-spec` step 7 | no | **no** (only captures shell `SPEC_BASE_SHA`) |
| `/sr-spec` step 10 codex gate | no | no (uses shell `SPEC_BASE_SHA`) |
| `/sr-start` orchestrator (reuse path) | no | yes — `.sensible-ralph-base-sha = $(git rev-parse HEAD)` after merging in-review parents, before `linear_set_state In Progress` |
| `/sr-start` orchestrator (create path) | no | yes — same as today, but for INTEGRATION mode capture post-merge instead of pre-merge (bug fix) |
| `/sr-implement` | no | no |
| `/prepare-for-review` | yes — `--base $(cat .sensible-ralph-base-sha)` for codex and the handoff `git log --first-parent <base>..HEAD` block | no |
| `/close-issue` stale-parent check | **no** (migrates to ancestry check — see below) | no |

## `close-issue` stale-parent migration

Today's `close_issue_label_stale_children` (in
`skills/close-issue/scripts/lib/stale_parent.sh`) calls
`is_branch_fresh_vs_sha` from `lib/branch_ancestry.sh`. Under ENG-279,
the child's `.sensible-ralph-base-sha` is no longer the parent's HEAD
at child-dispatch time — it's the child branch's post-merge HEAD,
which has nothing to do with the parent's HEAD. The SHA-equality check
breaks.

### New helper: `is_parent_landed_in_child` in `lib/branch_ancestry.sh`

```bash
# Returns 0 if $parent_sha is an ancestor of $child_branch's HEAD
# (i.e. the child branch's history contains the parent's pre-close
# state — child is fresh).
# Returns 1 if it is not (child was branched off an earlier parent
# state and the parent has since amended — child is stale).
# Returns 2 on any git error (caller treats as fresh-or-stale-unknown,
# emits a warning, does not label).
is_parent_landed_in_child() {
  local parent_sha="$1"
  local child_branch="$2"

  # Verify both refs exist before testing ancestry. A missing ref is a
  # data anomaly we surface, not a stale signal.
  git rev-parse --verify --quiet "$parent_sha^{commit}" >/dev/null || return 2
  git rev-parse --verify --quiet "refs/heads/${child_branch}^{commit}" >/dev/null || return 2

  if git merge-base --is-ancestor "$parent_sha" "refs/heads/$child_branch"; then
    return 0
  fi
  return 1
}
```

### Update `is_branch_fresh_vs_sha` callers

Replace the call site in
`skills/close-issue/scripts/lib/stale_parent.sh::close_issue_label_stale_children`
with `is_parent_landed_in_child`. The argument shape changes — pass
the child's branch name (already resolved via `resolve_branch_for_issue`)
plus the parent's pre-close HEAD captured in `/close-issue` step 5.

### `is_branch_fresh_vs_sha` retention

Today's `is_branch_fresh_vs_sha` reads the child worktree's
`.sensible-ralph-base-sha` and compares. Under ENG-279 nothing else
calls this helper (it was always a single-callsite helper). **Delete
it** rather than retaining a dead function. Update
`docs/design/shell-helpers.md`'s public-surface table accordingly.

## Module relocations

### `worktree.sh` lifts to plugin-wide `lib/`

Move `skills/sr-start/scripts/lib/worktree.sh` → `lib/worktree.sh`.

Reason: `/sr-spec` step 7 sources it. The `shell-helpers.md` rule of
thumb states: "move when sharing exists, not when sharing might
hypothetically exist." With ENG-279, `/sr-spec` is the second consumer;
sharing exists.

### Update sourcing call sites

| File | Old `source` path | New `source` path |
|---|---|---|
| `skills/sr-start/scripts/orchestrator.sh` | `"$SCRIPT_DIR/lib/worktree.sh"` | `"$PLUGIN_ROOT/lib/worktree.sh"` |
| `skills/sr-start/scripts/dag_base.sh` | (does not source worktree.sh today; no change) | (no change) |
| `skills/sr-spec/SKILL.md` step 7 (NEW) | n/a | `"$CLAUDE_PLUGIN_ROOT/lib/worktree.sh"` |
| `skills/sr-start/scripts/test/*.bats` | path-specific test sourcing | update to plugin-wide path; preserve fallback for harness invocation |

### New helper: `worktree_branch_state_for_issue` in `lib/worktree.sh`

```bash
# Prints one of:
#   both_exist            — branch exists AND worktree at $path is registered
#                           and checked out to $branch
#   neither               — branch absent AND $path absent
#   partial\t<cause>      — any inconsistent state; <cause> is one of:
#     branch-only         branch exists, no registered worktree at $path
#     path-only           $path exists but branch does not
#     path-not-worktree   $path exists but is not a registered git worktree
#     wrong-branch        worktree at $path is checked out to a different branch
#
# Callers split the output:
#   output=$(worktree_branch_state_for_issue "$b" "$p")
#   state="${output%%$'\t'*}"     # "both_exist" | "neither" | "partial"
#   cause="${output#*$'\t'}"      # empty for both_exist/neither; non-empty for partial
#
# Operator sees partial as local_residue (orchestrator) or a refuse-with-cleanup
# error (sr-spec). The cause feeds the diagnostic so the operator knows exactly
# what to clean up.
worktree_branch_state_for_issue() {
  local branch="$1" path="$2"
  local branch_exists=0 worktree_for_branch=0 worktree_at_path_exists=0

  if git show-ref --verify --quiet "refs/heads/$branch"; then
    branch_exists=1
  fi

  # Use `git worktree list --porcelain` to detect both presence of $path
  # as a registered worktree AND whether it is checked out to $branch.
  # A plain `[ -e "$path" ]` check would admit stray directories and
  # worktrees checked out to unrelated branches.
  if [ -e "$path" ]; then
    worktree_at_path_exists=1
    if git worktree list --porcelain 2>/dev/null | awk -v p="$path" -v b="refs/heads/$branch" '
         /^worktree / { wpath = substr($0, 10) }
         $0 == "branch " b { if (wpath == p) { found = 1; exit } }
         END { exit (found ? 0 : 1) }
       '; then
      worktree_for_branch=1
    fi
  fi

  if [ "$branch_exists" -eq 1 ] && [ "$worktree_for_branch" -eq 1 ]; then
    printf 'both_exist\n'
  elif [ "$branch_exists" -eq 0 ] && [ "$worktree_at_path_exists" -eq 0 ]; then
    printf 'neither\n'
  elif [ "$branch_exists" -eq 1 ] && [ "$worktree_at_path_exists" -eq 0 ]; then
    printf 'partial\tbranch-only\n'
  elif [ "$branch_exists" -eq 0 ]; then
    # path exists (either registered worktree or stray dir) but branch is absent
    printf 'partial\tpath-only\n'
  elif [ "$worktree_for_branch" -eq 0 ]; then
    # path exists, branch exists, but the registered worktree at $path is on a
    # different branch (or $path is a stray directory, not a registered worktree)
    if git worktree list --porcelain 2>/dev/null | awk -v p="$path" '
         /^worktree / { if (substr($0, 10) == p) { found = 1; exit } }
         END { exit (found ? 0 : 1) }
       '; then
      printf 'partial\twrong-branch\n'
    else
      printf 'partial\tpath-not-worktree\n'
    fi
  fi
}
```

**Callers** extract state and cause with POSIX parameter expansion
(bash 3.2-compatible, no `read -r` array needed):

```bash
_brwt=$(worktree_branch_state_for_issue "$branch" "$path")
_brwt_state="${_brwt%%$'\t'*}"
_brwt_cause="${_brwt#*$'\t'}"  # empty string when state is not 'partial'
```

### New helper: `worktree_merge_parents` in `lib/worktree.sh`

Mirrors `worktree_create_with_integration`'s sequential-merge logic
but operates on an **already-existing** worktree. Single-parent leaves
conflicts for the agent; multi-parent aborts on conflict so subsequent
parents aren't silently dropped.

```bash
# Merge a list of parent branches into the current HEAD of $path's
# worktree, in order. Skips parents already in ancestry (no-op merge).
# Conflict policy mirrors worktree_create_with_integration.
# $1: path     — worktree path
# $2+: parents — ordered list of parent branch names
worktree_merge_parents() {
  local path="$1"
  shift
  local parents=("$@")
  local parent_count="${#parents[@]}"
  if [ "$parent_count" -eq 0 ]; then
    return 0
  fi

  local resolved_refs=()
  local parent
  for parent in "${parents[@]}"; do
    if git -C "$path" show-ref --verify --quiet "refs/heads/$parent"; then
      resolved_refs+=("$parent")
    elif git -C "$path" show-ref --verify --quiet "refs/remotes/origin/$parent"; then
      resolved_refs+=("origin/$parent")
    else
      printf 'worktree_merge_parents: parent ref not found locally or under origin/: %s\n' "$parent" >&2
      return 1
    fi
  done

  local i merge_ref
  for (( i = 0; i < parent_count; i++ )); do
    merge_ref="${resolved_refs[$i]}"
    # Skip if already an ancestor — no-op merge.
    if git -C "$path" merge-base --is-ancestor "$merge_ref" HEAD 2>/dev/null; then
      continue
    fi
    git -C "$path" merge "$merge_ref" --no-edit && continue
    local unmerged
    unmerged="$(git -C "$path" diff --name-only --diff-filter=U)"
    if [[ -n "$unmerged" ]]; then
      if [[ "$parent_count" -eq 1 ]]; then
        return 0
      fi
      git -C "$path" merge --abort 2>/dev/null || true
      printf 'worktree_merge_parents: multi-parent merge conflict on %s — cannot continue.\n' "$merge_ref" >&2
      return 1
    else
      printf 'worktree_merge_parents: merge failed for parent %s\n' "$merge_ref" >&2
      return 1
    fi
  done
}
```

## Documentation updates

Apply in the same commit as the code changes (per CLAUDE.md "Unit of
Work" rule). Specific edits:

### `docs/design/worktree-contract.md` (HEAVY REWRITE)

- **Naming:** unchanged.
- **Creation:** rewrite entirely. Today's "orchestrator is the **sole
  creator**" is wrong under ENG-279. New text: "`/sr-spec` step 7 is
  the primary creator; orchestrator's create path is the fallback for
  manual issues / legacy state. Both call into `lib/worktree.sh`'s
  `worktree_create_at_base` and `worktree_create_with_integration`
  helpers."
- **`.sensible-ralph-base-sha`:** rewrite the Actor table per the
  consolidated lifecycle above. Drop the "INTEGRATION captures trunk
  SHA pre-merge" note (bug-fixed by ENG-279).
- **CWD convention:** add a `/sr-spec` row. After step 7, CWD is the
  worktree (same as `/sr-implement`).
- **Removal:** add a "Cancellation cleanup" subsection with the manual
  recipe.
- **Contract summary table:** update — `/sr-spec` Creates path: yes;
  Writes `.sensible-ralph-base-sha`: no.

### `docs/design/orchestrator.md` (HEAVY REWRITE)

- **Dispatch loop diagram:** redraw the per-issue setup. The
  pre-existence check splits into `both_exist` / `neither` /
  `partial` cases as in this spec's Architecture section.
- **Per-issue setup:** rewrite step 5 (was: pre-existence check →
  local_residue) per this spec.
- **Multi-parent integration:** delete the paragraph claiming the
  trunk SHA is captured "before any parent merges" — it's now
  captured post-merge (the bug fix).
- **Outcome classification:** update `local_residue` to mean only
  partial-state cases.

### `docs/design/outcome-model.md` (MODERATE REWRITE)

- **Outcome table:** update `local_residue` row's "Classification
  rule" from "target worktree path or branch already existed" to "the
  target worktree path and the target branch are in inconsistent
  states (one exists without the other)."
- **"Why local_residue deliberately leaves Linear untouched"
  subsection:** narrow the rationale to the partial-state case. The
  common-case "pre-existing both" is now the reuse path with normal
  outcomes.

### `docs/design/shell-helpers.md` (MODERATE REWRITE)

- **"Where the helpers live" diagram:** move `worktree.sh` from
  `skills/sr-start/scripts/lib/` to `lib/` row.
- **Module-map table for `lib/`:** add a `worktree.sh` row listing the
  public surface (`worktree_create_at_base`,
  `worktree_create_with_integration`, `worktree_path_for_issue`,
  `_resolve_repo_root`, NEW `worktree_branch_state_for_issue`, NEW
  `worktree_merge_parents`).
- **Module-map table for `skills/sr-start/scripts/lib/`:** remove
  `worktree.sh` row.
- **`branch_ancestry.sh` row:** add NEW `is_parent_landed_in_child`;
  remove `is_branch_fresh_vs_sha`.
- **"Move when sharing exists" rule of thumb:** add a "this is exactly
  why ENG-279 lifts `worktree.sh`" cross-reference.
- **Canonical sequence (orchestrator):** update the source path of
  `worktree.sh` from `$SCRIPT_DIR/lib/worktree.sh` to
  `$PLUGIN_ROOT/lib/worktree.sh`.

### `docs/design/linear-lifecycle.md` (LIGHT)

- **Transitions table:** add notes that `/sr-spec` step 1 also
  validates branch+worktree state alongside the issue state, with the
  re-entrancy preflight matrix. Either inline the matrix or link to
  `worktree-contract.md`.
- **Labels:** unchanged. Drop any forward references to `ralph-retry`
  if any exist.

### `docs/design/scope-model.md` (LIGHT)

- **Code-change surface table** entry for `skills/sr-spec/SKILL.md`:
  add a note that scope is loaded at step 6.5 (issue creation) in
  addition to finalize step 1.

### `docs/design/preflight-and-pickup.md` (NONE)

No change. Pickup rule and anomaly set are orthogonal.

### `docs/design/autonomous-mode.md` (NONE)

No change. Preamble still prepended at orchestrator dispatch
unchanged.

### `docs/usage.md` (LIGHT)

- Mention that `/sr-spec` creates a per-issue branch+worktree at step
  7 and the spec doc lives on the branch until merge.
- Update the `local_residue` description: now rare; means partial
  state, not common pre-existence.

### `README.md` (LIGHT — VERIFY DURING IMPLEMENTATION)

If the README's "five pillars" or operator-flow prose references the
old "spec on main" / "orchestrator creates worktree" model, update.

## Out of scope

- Multi-author concurrent operator sessions on the same issue branch
  (one operator per issue at a time).
- Primitive changes to `codex-review-gate` itself (e.g. adding a
  `--head <sha>` flag).
- Changes to Linear state taxonomy or label semantics beyond removing
  forward references to a `ralph-retry` label that was never built.
- A standalone `/sr-cleanup` skill for cancellation cleanup; manual
  recipe in `/sr-spec` notes is sufficient.
- Migration helper for legacy in-flight branches/worktrees.
  Self-healing on first re-dispatch (existing branch+worktree →
  orchestrator reuse path → base-sha gets overwritten with post-merge
  HEAD).
- Automating the operator's "remove `ralph-failed` and re-queue"
  retry. The label-removal step intentionally requires human attention
  per `linear-lifecycle.md`'s "dispatch never silently retries a
  failure" invariant.
- Rebase as an alternative to merge for parent integration on existing
  branches (rejected during dialogue — SHA stability and multi-parent
  composition).

## Alternatives considered

1. **Eager branch creation at `/sr-spec` step 1** (vs lazy at step 7,
   chosen). Eager gives the operator a stable per-issue workspace
   from the first message but requires a cancellation-cleanup ritual
   for every abandoned dialogue. Lazy eliminates the leak surface and
   avoids the concurrent-creation race; the lost benefit (operator
   `cd` into worktree mid-dialogue for ad-hoc exploration) is
   theoretical.

2. **Rebase parents into existing branch** (option (c) in dialogue) vs
   merge (option (a), chosen). Rebase preserves linear history (more
   symmetric with today's single-parent path) but rewrites spec
   commit SHAs, breaks operator-cd'd-into-worktree mid-flight, and
   composes awkwardly across multiple parents. Merge has uniform
   composition and stable SHAs; the cost (merge commit on
   single-parent case) is acceptable.

3. **Single base-sha file written once at `/sr-spec` branch creation**
   (the description's stated proposal) vs orchestrator-overwritten
   post-merge (chosen). Single-write keeps the file's semantics
   simple but makes the impl-phase codex review include parents'
   content (regression from today's single-parent case).
   Orchestrator-overwrite gives each phase a clean diff scope.

4. **`ralph-retry` label as re-pickup signal** (ENG-231's design) vs
   reuse-as-default (chosen). Under ENG-279 "reuse existing
   branch+worktree" is the always-path, so the retry signal is just
   "remove `ralph-failed` and the issue re-enters the queue." No new
   label needed. ENG-231 gets cancelled with a "subsumed by ENG-279"
   comment.

5. **Migration helper for legacy in-flight branches** vs self-healing
   (chosen). Self-healing on first re-dispatch keeps the migration
   surface zero. Legacy `.sensible-ralph-base-sha` gets overwritten
   with post-merge HEAD on first dispatch.

6. **Move issue creation to step 6.5** (chosen) vs other alternatives:
   - drop no-arg `/sr-spec` (regression),
   - branch with a temp name and rename at finalize (rename mid-stream
     is messy and breaks operator references).

## Testing expectations

Bats harnesses already exist at `lib/test/` (plugin-wide) and
`skills/sr-start/scripts/test/` (sr-start). Add tests for:

- **`lib/worktree.sh::worktree_branch_state_for_issue`** —
  `both_exist`, `neither`, `partial\tbranch-only`,
  `partial\tpath-only`, `partial\twrong-branch`,
  `partial\tpath-not-worktree`. Includes detached-HEAD worktree at
  path (appears as `wrong-branch` — no `branch` line in porcelain
  output → awk finds path but not matching branch → falls through to
  "is it a registered worktree at all?" secondary probe → yes → wrong-branch).
- **`lib/worktree.sh::worktree_merge_parents`** — zero parents, single
  parent (clean and conflict cases), multi-parent (clean, conflict on
  first abort, conflict on second abort), parent-already-ancestor
  no-op.
- **`lib/branch_ancestry.sh::is_parent_landed_in_child`** — fresh
  case, stale case, missing-ref case (returns 2).
- **Orchestrator reuse path, clean merge** — synthesize an existing
  branch+worktree and an in-review parent with no conflicts → expects
  merge commit created, `.sensible-ralph-base-sha` = merge commit SHA,
  `linear_set_state In Progress`, dispatch.
- **Orchestrator reuse path, single-parent conflict** — synthesize a
  conflict between the existing branch and the in-review parent →
  expects MERGING state, `.sensible-ralph-base-sha` = pre-merge commit
  SHA (spec HEAD), `linear_set_state In Progress`, dispatch (agent
  resolves on entry).
- **Orchestrator partial-residue path** — path without branch and
  branch without path → expects `local_residue` outcome with no
  Linear mutation.
- **Orchestrator INTEGRATION-mode base-sha post-merge fix** —
  multi-parent fresh-create → asserts written
  `.sensible-ralph-base-sha` equals post-merge HEAD, not pre-merge
  trunk SHA.
- **`/sr-spec` step-7 worktree creation** — fresh-create path and
  reuse path (Approved re-spec) → asserts branch and worktree exist
  after step 7, `SPEC_BASE_SHA` correct in each case.
- **`/sr-spec` re-entrancy preflight** — each row of the state matrix
  → asserts the expected refuse / proceed / resume behavior.

The orchestrator integration tests use the existing test harness
(`skills/sr-start/scripts/test/*.bats`) which already stubs
`linear_*` helpers; extend with stubs for `worktree_branch_state_for_issue`
and `worktree_merge_parents` where needed for isolation.

## Prerequisites

None hard-required. ENG-231 will be cancelled with a "subsumed by
ENG-279" comment after this issue lands; it is not a blocker for
implementation.

## Notes

- The Linear description for ENG-279 retains the original framing
  with the eight open design questions; this spec resolves all of
  them. After finalize, the description on Linear is overwritten with
  this spec's content. The original framing is preserved as a
  comment per the standard `/sr-spec` finalize-sub-step-4 pattern.
- The local repo IS configured as a sensible-ralph consumer
  (`<root>/.sensible-ralph.json` exists, scope = `["Sensible Ralph"]`),
  so the `/sr-spec` finalization flow runs to completion against ENG-279
  itself.
- Implementation is expected to run as a single autonomous session via
  `/sr-start`. Estimated scope: comparable to ENG-278 (persistent
  design-doc layer); a single non-trivial task with broad doc
  surface. The autonomous implementer should follow TDD discipline
  for the new helpers and integration test cases per CLAUDE.md.
