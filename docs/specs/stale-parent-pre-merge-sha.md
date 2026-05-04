# Stale-parent label: check pre-merge parent SHA, not post-rebase integration SHA

Ref: ENG-300

## Problem

`/close-issue`'s Step 6 ("Label In-Review children that built on pre-amendment content") passes `$INTEGRATION_SHA` — the no-ff merge commit produced by `close-branch` — to `close_issue_label_stale_children`. That helper ancestry-checks the supplied SHA against each In-Review child's branch via `is_branch_fresh_vs_sha`.

Because `close-branch` Step 1 always rebases the parent branch onto local `main` before the merge, every commit ID on the parent's branch is rewritten. The post-rebase merge commit (which is what `INTEGRATION_SHA` ends up holding) is therefore almost never an ancestor of any pre-existing child branch — the child's history contains the parent's *pre-rebase* commits, not the post-rebase ones.

The result: the label fires on every close where the parent had to absorb commits from `main` (the common case), regardless of whether the parent received any actual review-time amendments. Operators are trained to dismiss the label as routine, so the signal value of "this child was reviewed against pre-amendment content" is lost — the worst failure mode for any warning system.

The label was meant to flag exactly one condition: **content amendments to the parent during review that the child does not include**. SHA ancestry against a post-rebase tip conflates two separate axes:

- (a) Content amendments to the parent during review — meaningful, this is what the label exists to flag.
- (b) Rebase rewriting commit IDs without changing content — mechanical, irrelevant to review integrity.

Once the parent is rebased, you cannot tell from SHA chains alone whether (a) also occurred. The fix below restores the ability to distinguish the two by ancestry-checking against the parent's tip *before* the rebase.

## Why the post-ENG-279 lifecycle doesn't change the bug

Under ENG-279's per-issue branch lifecycle, the child branch B is created at `/sr-spec` time off `$SENSIBLE_RALPH_DEFAULT_BASE_BRANCH` (`main`). At `/sr-start` dispatch, the orchestrator's reuse path (`skills/sr-start/scripts/orchestrator.sh:417-432`) calls `worktree_merge_parents` to merge any In-Review parent A's branch tip into B. After that merge, B's history contains A's tip-at-dispatch as an ancestor.

When A is later closed via `/close-issue`:

- A's pre-merge tip = A's worktree HEAD just before `close-branch` runs.
- If A had no review amendments after B's dispatch: A's pre-merge tip equals A's tip-at-dispatch, which is in B's history → fresh, no label.
- If A had any review amendments after B's dispatch: A's pre-merge tip is a new commit not in B's history → stale, label correctly applied.

The same property holds in the legacy create path (`worktree_create_at_base "$path" "$branch" "$base_out"`) and in INTEGRATION mode (multi-parent merge at dispatch). The fix's capture point — A's worktree HEAD just before `close-branch` — produces the right semantic across all three orchestrator paths without any special-casing.

## Fix

`/close-issue` captures `PARENT_TIP_PRE_MERGE` from the parent's worktree HEAD just before invoking `close-branch`, and passes both that SHA and `INTEGRATION_SHA` to a 3-arg form of `close_issue_label_stale_children`. The PR-pending skip (no `INTEGRATION_SHA`) moves to the call site as an explicit `if` guard, because `PARENT_TIP_PRE_MERGE` will be non-empty whenever the parent worktree exists.

### Change 1 — capture in `close-issue/SKILL.md`

Insert a new sub-section **between Step 3 (Preserve untracked files) and Step 4 (Invoke close-branch)** titled "Capture parent tip pre-merge". Body:

```bash
PARENT_TIP_PRE_MERGE=$(git -C "$WORKTREE_PATH" rev-parse HEAD)
```

Followed by one short paragraph explaining: this SHA is the parent's branch tip after any review amendments but before `close-branch`'s Step 1 rebase rewrites commit IDs; it is the SHA against which In-Review children's freshness must be checked at Step 6, because a child reviewed against pre-amendment content has the pre-merge tip as an ancestor of its branch. Captured before delegation to `close-branch` so the global skill (which is invariant across projects) owns the value, rather than widening the project-local `close-branch` result-file contract.

### Change 2 — Step 6 call site in `close-issue/SKILL.md`

Replace the existing call:

```bash
close_issue_label_stale_children "$ISSUE_ID" "$INTEGRATION_SHA"
```

With:

```bash
if [ -n "$INTEGRATION_SHA" ]; then
  close_issue_label_stale_children "$ISSUE_ID" "$PARENT_TIP_PRE_MERGE" "$INTEGRATION_SHA"
fi
```

Update the prose under Step 6 ("**Skip entirely if `$INTEGRATION_SHA` is empty.**") to describe the explicit `if` guard instead of relying on the helper's internal empty-check. Update the "Known limitations" paragraph: the SHA-ancestry-flags-pure-rebase wording is no longer accurate — pure rebases will not trip the label under the fix. Replace with a concise statement that the residual edge case is content-equivalent amendments (mechanical fixups, message amends), which the operator dismisses manually.

### Change 3 — helper signature in `stale_parent.sh`

`close_issue_label_stale_children` grows a third positional arg. Param renaming inside the helper:

```bash
# Before:
close_issue_label_stale_children() {
  local issue_id="$1"
  local a_sha="$2"
  ...
}

# After:
close_issue_label_stale_children() {
  local issue_id="$1"
  local parent_pre_merge_sha="$2"
  local parent_integration_sha="$3"
  ...
}
```

Empty-arg defensive guard hardens to:

```bash
[ -z "$parent_pre_merge_sha" ] || [ -z "$parent_integration_sha" ] && return 0
```

Both shorts are derived inside the helper:

```bash
local parent_pre_merge_short parent_integration_short
parent_pre_merge_short=$(git rev-parse --short "$parent_pre_merge_sha")
parent_integration_short=$(git rev-parse --short "$parent_integration_sha")
```

The pre-existing `TODO(ENG-236)` note about malformed SHAs aborting the ritual via the caller's `set -e` still applies and stays in place — extend the comment to cover both new SHAs.

The `is_branch_fresh_vs_sha` call inside `close_issue_label_stale_children` (currently `is_branch_fresh_vs_sha "$a_sha" "refs/heads/$child_branch"` at `stale_parent.sh:148`) becomes `is_branch_fresh_vs_sha "$parent_pre_merge_sha" "refs/heads/$child_branch"`. The `list_commits_ahead` call in `_close_issue_stale_label_and_comment` (Change 4) does the equivalent rename. The integration SHA is body-text only — never fed to ancestry helpers.

### Change 4 — inner helper signature

`_close_issue_stale_label_and_comment` grows from 5 to 6 args:

```bash
# Before:
_close_issue_stale_label_and_comment() {
  local child_id="$1" child_branch="$2" parent_id="$3" parent_sha="$4" parent_short="$5"
  ...
}

# After:
_close_issue_stale_label_and_comment() {
  local child_id="$1" child_branch="$2" parent_id="$3"
  local parent_pre_merge_sha="$4" parent_pre_merge_short="$5" parent_integration_short="$6"
  ...
}
```

Inside, `list_commits_ahead "$parent_pre_merge_sha" "refs/heads/$child_branch"` uses the pre-merge SHA. Both shorts feed the comment body template (Change 5).

### Change 5 — comment body template

Replace the existing body in `_close_issue_stale_label_and_comment` with the template below. Note the four-backtick outer fence — the inner code block uses three backticks, so the outer fence is escalated to four to render correctly in Linear and on GitHub.

````
**Stale-parent check** — parent `${parent_id}` closed at `${parent_integration_short}`. Pre-merge branch tip was `${parent_pre_merge_short}`.

This branch (`${child_branch}`) does not have `${parent_pre_merge_short}` as an ancestor: `${parent_id}` received commits during review that this branch was not rebased onto, so the reviewer signed off on content against an older base.

Commits on the parent not present on this branch:

```
${commits}${truncated}
```

Recommended: rebase this branch onto the landed parent and re-review. If the diverging commits are content-equivalent to what was already reviewed (e.g. mechanical fixups, amended commit messages), dismiss the label manually. If this branch has its own In-Progress/In-Review descendants, rebasing here cascades to them.
````

Three deliberate choices preserved from the design dialogue:

1. The lead line carries the integration SHA, not the pre-merge SHA — the operator's first instinct after seeing the label is "where can I look at the parent now," and that's the integration commit on `main`. Pre-merge tip is the diagnostic.
2. The "if the divergence is a pure rebase, dismiss manually" sentence is removed. Under the fix, mechanical rebases no longer trip the label; that hint stops being useful.
3. Base-branch-agnostic wording preserved — no mention of `main` / `origin/main` / the project's trunk name. The existing comment in `stale_parent.sh:38-40` documents this convention.

## Test plan

### Bats coverage updates in `stale_parent.bats`

**Setup harness changes:**

1. Add a second empty commit in `setup()` so we have a second real SHA distinct from `A_SHA`:

   ```bash
   git -C "$TEST_REPO" commit --quiet --allow-empty -m "second"
   B_SHA="$(git rev-parse HEAD)"
   export B_SHA
   ```

2. Extend the `linear_comment` stub in the fake `lib/linear.sh` to also write the body to a second log keyed by child id, leaving the existing `STUB_COMMENT_LOG` (just child ids) intact so existing assertions don't change:

   ```bash
   export STUB_COMMENT_BODY_LOG="$STUB_DIR/comment_body_log"
   : > "$STUB_COMMENT_BODY_LOG"

   # Inside linear_comment, alongside the existing log line:
   printf '=== %s ===\n%s\n=== /%s ===\n' "$child_id" "$body" "$child_id" \
     >> "$STUB_COMMENT_BODY_LOG"
   ```

   Tests extract a child's body via `awk` between markers.

**Existing 10 tests — mechanical signature update.** Every `run call_fn close_issue_label_stale_children "ENG-200" "$A_SHA"` becomes `run call_fn close_issue_label_stale_children "ENG-200" "$A_SHA" "$B_SHA"`. The SHAs are opaque to the stubbed `is_branch_fresh_vs_sha`, so no semantic assertions change.

Test #1 (the existing `empty A_SHA → silent no-op` case) is replaced by the two new empty-arg tests below — those provide more specific coverage, one for each guarded SHA.

**Three new tests:**

1. **Body propagates both short SHAs.**

   - Setup: 1 stale child (`STUB_FRESH_ENG_100=1`), distinct `A_SHA` (pre-merge) and `B_SHA` (integration).
   - Compute the expected shorts via `git rev-parse --short` against the test repo.
   - Extract ENG-100's body block from `STUB_COMMENT_BODY_LOG` between `=== ENG-100 ===` / `=== /ENG-100 ===`.
   - Assert: body contains the literal substring `closed at \`<integration_short>\``.
   - Assert: body contains the literal substring `Pre-merge branch tip was \`<pre_merge_short>\``.
   - Assert: body contains `does not have \`<pre_merge_short>\` as an ancestor` — the ancestor-claim line uses the pre-merge short, not the integration short.

2. **Empty pre-merge SHA → silent no-op.**

   - Call: `run call_fn close_issue_label_stale_children "ENG-200" "" "$B_SHA"`.
   - Assert: status 0, both logs empty, output does not contain `Step 6 notes`.

3. **Empty integration SHA → silent no-op.**

   - Call: `run call_fn close_issue_label_stale_children "ENG-200" "$A_SHA" ""`.
   - Same assertions as test 2. Defensive layer for the (improbable) case that the call-site `if` guard in `close-issue/SKILL.md` is bypassed.

### What bats does NOT cover

The bats harness stubs `is_branch_fresh_vs_sha`, so the SHA-comparison *semantics* (which SHA value gets fed to which check, in real ancestry topology) are not exercised at the unit-test level. Acceptance criteria 1, 2, and 5 are claims about the SKILL.md flow's behavior — which SHA gets passed in, and whether the call site is reached at all — and live in `close-issue/SKILL.md` prose, not in any unit-testable surface.

The autonomous implementer's `/prepare-for-review` handoff comment must explicitly call out that the manual block below is pending human-reviewer execution before merge.

### Manual verification block (for the human reviewer at PR time)

The reviewer constructs three close events using a scratch `Sensible Ralph` issue topology and verifies:

1. **Rebase-only parent close** — parent A is in In Review with no review amendments. A's worktree HEAD = A's tip at the child B's dispatch. Run `/close-issue <A>`. **Expected:** B does NOT receive the `stale-parent` label, and Step 6 emits no notes about B.

2. **Amended parent close** — same A/B setup, then commit one new change directly to A's branch in the worktree (simulating a review amendment). Confirm A's HEAD has advanced past A's dispatch tip. Run `/close-issue <A>`. **Expected:** B receives the `stale-parent` label, and B receives a Linear comment whose body contains both expected short SHAs in the positions specified by Change 5 above.

3. **PR-pending close** — substitute (or simulate) a `close-branch` invocation that exits without writing `.close-branch-result`. Run `/close-issue <A>`. **Expected:** Step 6 is skipped entirely — no comment, no label, no Step 6 notes.

These three cases exercise ACs 1, 2, and 5 respectively and complete the testing surface.

## Acceptance criteria

1. A child branch dispatched from parent A's tip-at-dispatch, when A is closed without any review amendments, does NOT receive the `stale-parent` label after `/close-issue <A>`.
2. A child branch dispatched from parent A's tip-at-dispatch, when A receives any commit during review and is then closed, DOES receive the `stale-parent` label, and the Linear comment body contains both A's pre-merge short SHA (in the "Pre-merge branch tip was" line and the ancestor-claim line) and A's integration short SHA (in the lead "closed at" line).
3. The Linear comment body matches the template in Change 5 above — including the removed "pure rebase, dismiss manually" sentence and the retained "content-equivalent amendments" guidance.
4. `stale_parent.bats` adds the three new tests described in the test plan, and every existing test that calls `close_issue_label_stale_children` is updated to the 3-arg signature. All bats tests pass.
5. The PR-pending workflow (no `INTEGRATION_SHA` from `close-branch`) skips Step 6 entirely with no behavioral change. The skip is enforced at the SKILL.md call site by an explicit `if [ -n "$INTEGRATION_SHA" ]; then …` guard, defended in depth by the helper's own empty-arg guard on either SHA.

## Out of scope

- `close-branch`'s rebase-failure handling (covered by ENG-288).
- Any change to `INTEGRATION_SUMMARY` text or the `.close-branch-result` file format.
- Project-local `close-branch` implementations that don't rebase — they automatically get correct behavior because their pre-merge tip equals the post-merge HEAD; no implementation update required.
- The `TODO(ENG-236)` malformed-SHA hardening at `stale_parent.sh:73` — same comment extends to the second SHA, but the hardening itself is signposted to ENG-236 and not in this ticket.
- `prepare-for-review`'s rebase semantics — verified at design time that it does not rebase; the fix's correctness does not depend on prepare-for-review's behavior.

## References

- `skills/close-issue/SKILL.md` — Step 4 ("Invoke close-branch") for the capture-point insertion location; Step 6 ("Label In-Review children that built on pre-amendment content") for the call-site update; "Known limitations" paragraph at the end of Step 6 for the prose update.
- `skills/close-issue/scripts/lib/stale_parent.sh` — `close_issue_label_stale_children` and `_close_issue_stale_label_and_comment` for signature and body changes.
- `skills/close-issue/scripts/test/stale_parent.bats` — `setup()` for harness extension; existing tests for signature update; new tests at the end of the file.
- `skills/close-branch/SKILL.md` (project-local) — Steps 1-2 (rebase + no-ff merge) for context on why pre-merge tip is captured before delegation; no changes to this file.
- `skills/sr-start/scripts/orchestrator.sh:417-466` — reuse and create paths that establish the parent-as-ancestor invariant in child branches at dispatch time.
- `docs/design/linear-lifecycle.md` — `stale-parent` label semantics; this fix preserves the documented "observational, not gating" character.

## Notes for the autonomous implementer

The fix touches two skills and one test file; total change is small (under ~80 lines of code + prose, plus ~50 lines of new test cases). Recommended order: (a) update `stale_parent.sh` signatures and body template; (b) update `stale_parent.bats` setup + existing tests so they pass under the new signature; (c) add the three new bats tests; (d) update `close-issue/SKILL.md` capture point + Step 6 call site + prose. Run `bats skills/close-issue/scripts/test/stale_parent.bats` after each step to catch breakage early.

The `/prepare-for-review` handoff comment must include — under "Known gaps / deferred" — the three-case manual verification block above, marked as "pending human reviewer at PR time." Do not attempt to manually exercise the close ritual against real Linear state from inside the autonomous session; the manual block is reviewer-side.
