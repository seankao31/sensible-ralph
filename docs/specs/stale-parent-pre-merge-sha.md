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

**Implicit invariant the fix relies on.** The captured SHA — the parent's worktree HEAD just before `close-branch` runs — is treated as the SHA the human reviewer signed off on. The lifecycle convention supports this softly, not via enforcement: `/prepare-for-review` records the handoff revision in the Linear footer and transitions to In Review, and re-running `/prepare-for-review` on subsequent commits is the documented response to mid-review amendments. There is no mechanism in `close-issue` that gates on "HEAD still matches the handoff-comment SHA," so an operator who amends commits in the parent's worktree after handoff and skips re-running `/prepare-for-review` will have a discrepancy between "what was reviewed" and "what gets compared against children." That gap exists today and is not introduced by this fix; importantly, the stale-parent label still fires correctly in that scenario because the post-amendment HEAD is not in the child's history. The broader concern (parent shipping content that was never re-reviewed) is a separate axis of review integrity and out of scope for ENG-300. This fix's only structural assumption is that `close-branch` does not mutate the parent branch *before* its own integration steps (rebase + merge); if a future project-local `close-branch` ever pre-mutates the parent during review, the contract has to be revisited.

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

Empty-arg defensive guard hardens to an explicit `if` block (not the `||`/`&&` shorthand — `&&` and `||` are equal-precedence and left-associative in bash, so the shorthand parses correctly but is easy to misread; for a defensive guard, clarity beats compactness):

```bash
if [ -z "$parent_pre_merge_sha" ] || [ -z "$parent_integration_sha" ]; then
  return 0
fi
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

Replace the existing body in `_close_issue_stale_label_and_comment`. **Note on fences:** the four-backtick outer fence below is a markdown-rendering device used in *this spec doc* to display a template that itself contains a three-backtick block. The actual Linear comment body is **not** wrapped in any outer fence — it's raw markdown that includes one nested triple-backtick code block (for the commits list). The implementer must produce a comment body that opens with `**Stale-parent check**` and ends with the "rebasing here cascades to them." paragraph, with no outer fence.

The current implementation builds the body via an unquoted heredoc in `stale_parent.sh:41-54`, escaping every literal backtick with `\`` so the shell doesn't interpret them as command substitution. Keep that exact mechanism — the new body must use an unquoted heredoc so `${parent_id}`, `${parent_pre_merge_sha}`, `${parent_pre_merge_short}`, `${parent_integration_short}`, `${child_branch}`, `${commits}`, and `${truncated}` all interpolate. Concrete shape:

```bash
body=$(cat <<COMMENT
**Stale-parent check** — parent \`${parent_id}\` closed at \`${parent_integration_short}\`. Pre-merge branch tip was \`${parent_pre_merge_short}\`.

This branch (\`${child_branch}\`) does not have \`${parent_pre_merge_short}\` as an ancestor: \`${parent_id}\` received commits during review that this branch was not rebased onto, so the reviewer signed off on content against an older base.

Commits on the parent not present on this branch:

\`\`\`
${commits}${truncated}
\`\`\`

Recommended: rebase this branch onto the landed parent and re-review. If the diverging commits are content-equivalent to what was already reviewed (e.g. mechanical fixups, amended commit messages), dismiss the label manually. If this branch has its own In-Progress/In-Review descendants, rebasing here cascades to them.
COMMENT
)
```

Rendered template, for visual reference:

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

3. Extend the `is_branch_fresh_vs_sha` stub in the fake `lib/branch_ancestry.sh` to log every invocation's `parent_sha` argument. This converts the "SHA-swap" failure mode from manual-only into automated coverage — the test plan can now verify that the helper feeds the pre-merge SHA to the ancestry check, not the integration SHA:

   ```bash
   export STUB_FRESH_ARG_LOG="$STUB_DIR/fresh_arg_log"
   : > "$STUB_FRESH_ARG_LOG"

   # Inside the existing is_branch_fresh_vs_sha stub, before the rc return:
   printf '%s\t%s\n' "$parent_sha" "$branch_ref" >> "$STUB_FRESH_ARG_LOG"
   ```

**Existing 10 tests — mechanical signature update.** Every `run call_fn close_issue_label_stale_children "ENG-200" "$A_SHA"` becomes `run call_fn close_issue_label_stale_children "ENG-200" "$A_SHA" "$B_SHA"`. The SHAs are opaque to the stubbed `is_branch_fresh_vs_sha`, so no semantic assertions change.

Test #1 (the existing `empty A_SHA → silent no-op` case) is replaced by the two new empty-arg tests below — those provide more specific coverage, one for each guarded SHA.

**Four new tests:**

1. **Body propagates both short SHAs and expands every interpolation.**

   - Setup: 1 stale child (`STUB_FRESH_ENG_100=1`), distinct `A_SHA` (pre-merge) and `B_SHA` (integration). Set `STUB_COMMITS_ENG_100="abc1234 sentinel commit"` so the test has a known string to look for in the expanded `${commits}` slot.
   - Compute the expected shorts via `git rev-parse --short` against the test repo.
   - Extract ENG-100's body block from `STUB_COMMENT_BODY_LOG` between `=== ENG-100 ===` / `=== /ENG-100 ===`.
   - Assert: body contains the literal substring `closed at \`<integration_short>\``.
   - Assert: body contains the literal substring `Pre-merge branch tip was \`<pre_merge_short>\``.
   - Assert: body contains `does not have \`<pre_merge_short>\` as an ancestor` — the ancestor-claim line uses the pre-merge short, not the integration short.
   - Assert: body contains the literal substring `abc1234 sentinel commit` — proves `${commits}` expanded.
   - Assert: body does NOT contain any literal `${...}` placeholder. Any leftover `$\{` substring would mean the heredoc rewrite suppressed expansion (e.g., implementer accidentally quoted the heredoc tag or escaped a `$`). Implementation: `! grep -q '\${' <body-tempfile>`.
   - Assert: body contains the literal three-backtick fence lines bracketing the commits block (i.e., a line whose content is exactly ``` ``` ``` followed later by another such line). Catches a malformed rewrite that drops the inner fence.

2. **Empty pre-merge SHA → silent no-op.**

   - Call: `run call_fn close_issue_label_stale_children "ENG-200" "" "$B_SHA"`.
   - Assert: status 0, both logs empty, output does not contain `Step 6 notes`.

3. **Empty integration SHA → silent no-op.**

   - Call: `run call_fn close_issue_label_stale_children "ENG-200" "$A_SHA" ""`.
   - Same assertions as test 2. Defensive layer for the (improbable) case that the call-site `if` guard in `close-issue/SKILL.md` is bypassed.

4. **Ancestry check receives pre-merge SHA, not integration SHA.**

   - Setup: 1 In-Review child whose freshness rc doesn't matter (use `STUB_FRESH_ENG_100=0` for a clean log — the test inspects `STUB_FRESH_ARG_LOG`, which captures the call regardless of return code).
   - Call: `run call_fn close_issue_label_stale_children "ENG-200" "$A_SHA" "$B_SHA"`.
   - Assert: `$STUB_FRESH_ARG_LOG` contains a line whose first column is `$A_SHA` (the pre-merge SHA was passed).
   - Assert: `$STUB_FRESH_ARG_LOG` does NOT contain a line whose first column is `$B_SHA` (the integration SHA was never fed to the ancestry helper). Catches the "implementer accidentally swapped which SHA goes to `is_branch_fresh_vs_sha`" regression — the core semantic this ticket exists to fix.

### What bats does NOT cover

The bats harness stubs `is_branch_fresh_vs_sha`, so the SHA-comparison *semantics* against a real ancestry topology are not exercised at the unit-test level. Test 4 above asserts which SHA is *passed* to the ancestry helper (the load-bearing argument), but it cannot verify what `is_branch_fresh_vs_sha` would have returned given a real branch graph. Acceptance criteria 1 and 2 are claims about the close-issue SKILL.md flow's *capture-point* behavior — that the variable being passed at the call site is in fact the parent's worktree HEAD before close-branch ran. AC#5 is similarly a SKILL.md-prose concern (the explicit `if` guard at the call site).

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
4. `stale_parent.bats` adds all four new tests described in the test plan — body-propagation, empty-pre-merge-SHA no-op, empty-integration-SHA no-op, and ancestry-receives-pre-merge-SHA — and every existing test that calls `close_issue_label_stale_children` is updated to the 3-arg signature. All bats tests pass. Test 4 (ancestry-receives-pre-merge-SHA) is load-bearing — it is the only automated guard against the SHA-swap regression this ticket exists to fix.
5. The PR-pending workflow (no `INTEGRATION_SHA` from `close-branch`) skips Step 6 entirely with no behavioral change. The skip is enforced at the SKILL.md call site by an explicit `if [ -n "$INTEGRATION_SHA" ]; then …` guard, defended in depth by the helper's own empty-arg guard on either SHA.

## Out of scope

- `close-branch`'s rebase-failure handling (covered by ENG-288).
- Any change to `INTEGRATION_SUMMARY` text or the `.close-branch-result` file format.
- Project-local `close-branch` implementations of any flavor (rebase + no-ff merge, fast-forward only, PR-pending, multi-step cascade) — none need to expose a new value or modify their implementation. The capture happens in `close-issue` *before* delegation, so the global skill always has the parent's worktree HEAD at handoff regardless of what `close-branch` does internally afterwards. Earlier wording in this spec is precise: the captured SHA is "the parent's worktree HEAD just before `close-branch` runs", not "the post-merge HEAD". Note that in a fast-forward-only close-branch flow, `PARENT_TIP_PRE_MERGE` and `INTEGRATION_SHA` may end up identical at runtime; the helper still receives both, ancestry-checks against pre-merge, and renders both shorts in the comment body (which will display as the same value in that flow). The bats fixture intentionally uses two distinct git SHAs (`A_SHA = HEAD~1`, `B_SHA = HEAD`) so the SHA-routing assertions remain meaningful regardless of the production close-branch flavor a project ships.
- The `TODO(ENG-236)` malformed-SHA hardening at `stale_parent.sh:73` — same comment extends to the second SHA, but the hardening itself is signposted to ENG-236 and not in this ticket.
- `prepare-for-review`'s rebase semantics — verified at design time that it does not rebase; the fix's correctness does not depend on prepare-for-review's behavior.
- `close-branch`'s mechanical-conflict-resolution policy. close-branch's project-local `SKILL.md` permits inline mechanical conflict resolution during its rebase step (`.claude/skills/close-branch/SKILL.md` Step 1). If a resolution materially changes content beyond mechanical, that's a close-branch policy bug, not a stale-parent labeling defect — children are checked against the pre-rebase tip (= the reviewed content), and any divergence introduced during rebase belongs to the close-branch contract. The "content-equivalent amendments, dismiss manually" hint in the comment body covers the residual case if a mechanical resolution does sneak through and trips a label.
- Enforcing that the parent's HEAD at `/close-issue` time still matches the SHA recorded in `/prepare-for-review`'s Linear handoff comment. That tripwire would close the soft-contract gap described in "Implicit invariant" above, but it's a separate review-integrity feature spanning prepare-for-review and close-issue, not a stale-parent-label fix.
- Persisting `PARENT_TIP_PRE_MERGE` to a durable artifact for retry recovery. Tracing the close-issue flow: after `close-branch` succeeds, the parent's branch is deleted in `close-branch` Step 6, which means a re-invocation of `/close-issue` cannot resolve the branch in Step 1 and exits before reaching the capture point. So "retry the stale-parent check after close-branch landed but the worktree is gone" is not a reachable code path — it's a manual-recovery scenario governed by the existing "Red Flags / When to Stop" section in `close-issue/SKILL.md`. The capture-point capture is correctly transient: re-runnable on `close-branch`-failure retries (where worktree + branch still exist) and unreachable in completed-merge retries (where the branch is already gone, blocking re-entry).

## References

- `skills/close-issue/SKILL.md` — Step 4 ("Invoke close-branch") for the capture-point insertion location; Step 6 ("Label In-Review children that built on pre-amendment content") for the call-site update; "Known limitations" paragraph at the end of Step 6 for the prose update.
- `skills/close-issue/scripts/lib/stale_parent.sh` — `close_issue_label_stale_children` and `_close_issue_stale_label_and_comment` for signature and body changes.
- `skills/close-issue/scripts/test/stale_parent.bats` — `setup()` for harness extension; existing tests for signature update; new tests at the end of the file.
- `skills/close-branch/SKILL.md` (project-local) — Steps 1-2 (rebase + no-ff merge) for context on why pre-merge tip is captured before delegation; no changes to this file.
- `skills/sr-start/scripts/orchestrator.sh:417-466` — reuse and create paths that establish the parent-as-ancestor invariant in child branches at dispatch time.
- `docs/design/linear-lifecycle.md` — `stale-parent` label semantics; this fix preserves the documented "observational, not gating" character.

## Notes for the autonomous implementer

The fix touches two skills and one test file; total change is small (under ~80 lines of code + prose, plus ~70 lines of new test cases including test 4's stub-log extension). Recommended order: (a) update `stale_parent.sh` signatures and body template; (b) update `stale_parent.bats` setup harness (both stub extensions: `STUB_COMMENT_BODY_LOG` and `STUB_FRESH_ARG_LOG`); (c) update existing tests so they pass under the new signature; (d) add all four new bats tests; (e) update `close-issue/SKILL.md` capture point + Step 6 call site + prose. Run `bats skills/close-issue/scripts/test/stale_parent.bats` after each step to catch breakage early.

The `/prepare-for-review` skill itself is **not modified by this ticket** — its code, prose, and references stay as they are. The implementer's responsibility is only to *populate* the Linear handoff comment that `/prepare-for-review` posts at session end: under that comment's "Known gaps / deferred" section, include the three-case manual verification block from this spec, marked as "pending human reviewer at PR time." That is a comment-body content choice the implementer makes for this ticket, not a change to the prepare-for-review skill. Do not attempt to manually exercise the close ritual against real Linear state from inside the autonomous session; the manual verification block is reviewer-side.
