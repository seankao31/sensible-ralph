# `close-branch`: guard Step 1's rebase against silent exit-code drop

## Problem

`.claude/skills/close-branch/SKILL.md` Step 1 runs `git rebase main` in
the worktree without checking the exit code. When rebase fails with
conflicts, the skill's example snippet shows no guard, so the LLM
following the snippet proceeds to Step 2 with the worktree mid-rebase.
The cascade observed during ENG-241's `/close-issue` run:

1. Worktree's `git rebase main` exits non-zero with conflicts; SKILL.md
   has no guard, so the next bash command runs.
2. `git merge --no-ff "$FEATURE_BRANCH"` on the main checkout fails with
   conflicts (worktree's branch tip is mid-rebase).
3. `git push origin main` reports `Everything up-to-date` because no
   merge commit landed.
4. `INTEGRATION_SHA=$(git rev-parse HEAD)` captures `main`'s pre-merge
   SHA — a previous issue's merge commit.
5. `git -C "$WORKTREE_PATH" checkout --detach` fails (branch is mid-
   rebase, can't detach).
6. `git branch -d "$FEATURE_BRANCH"` fails (worktree still holds the
   branch).
7. `.close-branch-result` is written with the wrong `INTEGRATION_SHA`,
   which `close-issue` then uses for stale-parent labeling against the
   wrong commit.

After the cascade, both checkouts are dirty (worktree mid-rebase, main
mid-merge). The operator must `git rebase --abort` and `git merge
--abort` manually. ENG-241's actual recovery required exactly that.

The root cause is in the SKILL.md text, not in any executable script:
close-branch is a Skill, so the LLM follows the snippet verbatim. A
missing exit-code check in the snippet is a missing exit-code check in
practice.

## Goal

Add an explicit exit-code guard to Step 1's `git rebase main` so a
rebase conflict aborts close-branch cleanly instead of cascading into
a corrupt merge. Update the surrounding prose so the new flow
(close-branch exits → caller resolves outside → caller re-invokes
`/close-issue`) is unambiguous.

The Goal is **scoped to the rebase**, not Step 1 in general. The
preceding `git fetch origin main` stays unguarded by design — Step
1's rebase is against *local* main (per line 76 of close-branch
SKILL.md: "Rebase onto **local** `main`, not `origin/main`"), so a
fetch failure is non-fatal here. The fetch is advisory for Step 2's
`git pull --ff-only`, where origin/main freshness *does* matter; that
guard is deferred to the follow-up issue (see Out of scope).

## Scope

Edit exactly one file: `.claude/skills/close-branch/SKILL.md`.

### Edit 1 — Step 1 snippet

Replace lines 70-73 (the `### Step 1: Rebase onto latest main` snippet):

```bash
# before
git -C "$WORKTREE_PATH" fetch origin main
git -C "$WORKTREE_PATH" rebase main
```

with:

```bash
# after
git -C "$WORKTREE_PATH" fetch origin main
rebase_rc=0
git -C "$WORKTREE_PATH" rebase main || rebase_rc=$?
if [ "$rebase_rc" -ne 0 ]; then
  echo "close-branch: rebase failed (exit $rebase_rc). Resolve conflicts and re-run, or abort with:" >&2
  echo "  git -C \"$WORKTREE_PATH\" rebase --abort" >&2
  exit "$rebase_rc"
fi
```

This is the canonical "capture rc, branch on it, exit with the captured
code" idiom — preferred over `if ! git rebase main; then ... exit 1;
fi` because the diagnostic preserves the actual rebase exit code (git's
rebase emits 1 for content conflicts, 128 for fatal errors, etc.; we
pass that through to `close-issue`).

### Edit 2 — Step 1 prose

The current prose at lines 79-93 reads:

> **If rebase fails with conflicts:** resolve them yourself when the
> right answer is mechanical, then `git -C "$WORKTREE_PATH" add
> <files>` and `git -C "$WORKTREE_PATH" rebase --continue`. The goal
> is minimal human intervention *when the decision is mechanical*.
>
> Mechanical resolutions (resolve, don't escalate):
>
> - Unrelated edits in adjacent regions (formatting, nearby lines,
>   imports) — keep both.
> - Same logical change landed on both sides — drop the feature-branch
>   duplicate; take main's version.
> - Both sides appended different items to the same list, changelog,
>   or docs section — merge the content.
>
> Abort (`git rebase --abort`) and exit non-zero only when:
>
> - Both sides made substantive, contradicting changes to the same
>   logic.
> - A file was deleted on one side and modified on the other.
> - The right answer isn't obvious without user context.
>
> Silently picking a side on ambiguous logic is worse than stopping —
> the "minimal intervention" principle applies only when the decision
> is obvious.

This implies the "resolve+continue" happens inside close-branch's run.
With Edit 1's guard, that's no longer true — the guard exits as soon
as rebase fails. Rewrite so the *flow* is explicit, the *taxonomy*
(mechanical vs ambiguous) is preserved as caller decision criteria:

> **When the guard fires** (rebase failed with conflicts), close-branch
> has already exited non-zero. The worktree is mid-rebase; the main
> checkout is untouched. close-branch did NOT write
> `.close-branch-result`, so close-issue's existing fallback handling
> kicks in (see line 213 below: "treats an absent file as empty
> values, which correctly skips stale-parent labeling and falls back
> to a generic final message") — no new contract between close-branch
> and close-issue is introduced by this guard. The caller (operator
> running `/close-issue`, or an autonomous session that dispatched it)
> decides what to do next:
>
> *Mechanical conflict — resolve outside close-branch, then re-run.*
> In the worktree, edit the conflicted files, `git -C "$WORKTREE_PATH"
> add <files>`, `git -C "$WORKTREE_PATH" rebase --continue`, then
> re-invoke `/close-issue`. On the second run Step 1's `git rebase
> main` is a no-op (branch already on top of main), the guard does not
> fire, and Step 2 proceeds normally.
>
> Mechanical resolutions (the caller can do these without escalation):
>
> - Unrelated edits in adjacent regions (formatting, nearby lines,
>   imports) — keep both.
> - Same logical change landed on both sides — drop the feature-branch
>   duplicate; take main's version.
> - Both sides appended different items to the same list, changelog,
>   or docs section — merge the content.
>
> *Ambiguous conflict — abort and escalate.* In the worktree,
> `git -C "$WORKTREE_PATH" rebase --abort`, then surface the conflict
> to a human (or, in an autonomous session, follow the global
> CLAUDE.md autonomous-mode rules: post a Linear comment describing
> the conflict and exit clean — that's an existing rule, not new
> behavior introduced here). Do not re-invoke `/close-issue` until
> the conflict has a known resolution.
>
> Cases that are NOT mechanical:
>
> - Both sides made substantive, contradicting changes to the same
>   logic.
> - A file was deleted on one side and modified on the other.
> - The right answer isn't obvious without user context.
>
> Silently picking a side on ambiguous logic is worse than stopping —
> the "minimal intervention" principle applies only when the decision
> is obvious.

Two structural changes from the original:

1. The lead-in flips from "do the resolution" to "decide what to do
   next" — making clear that whatever the caller does happens *between*
   close-branch invocations, not inside one.
2. The mechanical-resolution recipe ends with "re-invoke `/close-issue`",
   which the original text omitted. That re-invocation is what closes
   the loop; without it the caller might forget to restart the ritual.

### Edit 3 — Red Flags section (no change)

Line 220 already says: "**Rebase introduces conflicts that need user
context.** `git rebase --abort` and exit non-zero. Mechanical conflicts
are resolved inline; only ambiguous/contradicting ones stop here."

After Edits 1 and 2, the second sentence ("Mechanical conflicts are
resolved inline") is no longer accurate — mechanical conflicts are
resolved *outside close-branch*, not inline. Update this line to:

> **Rebase introduces conflicts that need user context.** The Step 1
> guard exits the skill non-zero. Resolution (mechanical or aborted)
> happens caller-side per Step 1's prose; close-branch itself never
> resolves conflicts.

This is a one-line update, not a section rewrite.

## Verification

After the edits, all of the following must pass:

1. **Snippet contains the guard:**

   ```bash
   grep -nF 'rebase_rc=0' .claude/skills/close-branch/SKILL.md
   ```

   → exactly one match, inside Step 1.

2. **Old un-guarded snippet is gone:**

   ```bash
   grep -nE '^git -C "\$WORKTREE_PATH" rebase main$' .claude/skills/close-branch/SKILL.md
   ```

   → zero matches. (Anchored to start-of-line so it doesn't match the
   inside-the-`||` form `git ... rebase main || rebase_rc=$?`.)

3. **Prose flow update lands:**

   ```bash
   grep -nF 'close-branch has already exited' .claude/skills/close-branch/SKILL.md
   ```

   → exactly one match, in Step 1.

4. **Red Flags update lands:**

   ```bash
   grep -nF 'close-branch itself never resolves conflicts' .claude/skills/close-branch/SKILL.md
   ```

   → exactly one match.

5. **No accidental change to other Step prose:** `git diff main --
   .claude/skills/close-branch/SKILL.md` should show changes only
   inside Step 1 (lines 70-93 region) and the one-line Red Flags
   update (~line 220). Nothing in Steps 2-7, "Inputs on entry",
   "Pre-flight", or "Explicitly out of scope".

These greps are the verification. There is no automated test suite for
close-branch — it's a Skill (markdown), not a script.

## Testing expectations

This is a documentation-only edit to a skill file. No code changes, no
tests to add or update. TDD does not apply.

The acceptance criterion "When `git rebase` exits non-zero, the skill
prints a diagnostic and exits non-zero without touching the main
checkout" is verified by reading the snippet, not by running a test.
The codex adversarial review at `/prepare-for-review` time is the
backstop that catches snippet-level defects (e.g. wrong shell quoting,
wrong exit propagation, accidental `set -e` interactions).

Manual end-to-end verification (running `/close-issue` against a
deliberately-conflicted branch and confirming clean exit) is *not
required* for this fix to ship. If a future incident shows the guard
itself misbehaves, that's a separate spec.

## Out of scope

The same class of "snippet doesn't show exit-code guard, prose says
exit on failure" defect exists in several other steps of close-branch
SKILL.md. None are fixed by ENG-288.

- **Step 2's `git pull --ff-only origin main` and `git merge --no-ff`
  exit-code guards.** Prose at lines 132 and 134 says "exit non-zero"
  on failure, but the example snippets at lines 110-126 don't show
  guards. Step 2 failures cascade less catastrophically than Step 1's
  (a stale main makes the merge fail on its own, and a rejected push
  is caught by Step 3's existing retry/reset logic), but the same
  class of defect exists.
- **Step 3's `git push origin main` exit-code guard.** Lines 146-163
  describe retry and reset paths in detail but the example snippet at
  line 143 is bare.
- **Step 5's `git checkout --detach` and Step 6's `git branch -d` /
  `git push origin --delete` exit-code guards.** Smaller-blast-radius
  failures (a non-fatal cleanup hiccup, not a bad `INTEGRATION_SHA`).
  Lower priority than Step 2/3.

**Required follow-up Linear issue.** Before invoking `/prepare-for-
review`, the implementer must file ONE new issue covering Step 2 and
Step 3 hardening at minimum (the cases that, like ENG-288, can produce
a wrong `INTEGRATION_SHA` or fail to fail loudly). Step 5 and Step 6
guards may be added to the same issue at the implementer's discretion.
Suggested title: `close-branch: guard remaining git operations against
silent exit-code drop`. Body should reference ENG-288 as the precedent
and link this spec.

**Acknowledged residual risk.** Adversarial spec review (codex,
2026-05-04) called out that ENG-288 alone does not eliminate the
wrong-`INTEGRATION_SHA` class of bug. Specifically: between ENG-288
shipping and the follow-up issue landing, the cascade `Step 2 pull
--ff-only fails silently → merge against stale local main succeeds →
push rejected → INTEGRATION_SHA captures a SHA not on origin/main →
wrong stale-parent labeling` is still possible. The cascade is less
likely than Step 1's incident (it requires origin/main to advance
*and* local main to have unpushed commits *and* the merge against
stale main to be conflict-free) and is partially backstopped by Step
3's push-rejection retry/reset prose at lines 146-163, but it is not
fully closed by Step 1's guard. The narrow-scope decision is
deliberate (matches ENG-288's stated scope, keeps the spec/PR review
surface tight, and Step 1's incident class is the one observed in
ENG-241); the trade-off is on the record. Implementer files the
follow-up issue at the start of implementation, not the end, so it
enters the queue immediately.

Other deferrals (no follow-up issue required):

- **Extracting close-branch's bash into a real shell script with
  `set -e`.** Would resolve the whole class at once but changes the
  Skill-vs-script architectural choice and breaks the pattern with
  the rest of the plugin's project-local skills.
- **Bats coverage for close-branch.** Same architectural objection.
- **Adding a `# why` comment near the guard in the SKILL.md.** The
  diagnostic message itself ("rebase failed (exit ...). Resolve
  conflicts and re-run...") is the explanation a reader needs in-
  context; a separate code comment would duplicate it.
- **Extracting close-branch's bash into a real shell script with
  `set -e`.** That would resolve the whole class of bug at once but
  changes the architectural choice (Skill vs script) and breaks the
  pattern with the rest of the plugin's project-local skills. Out of
  scope.
- **Bats coverage for close-branch.** Same architectural objection.
  No automated test for this fix.
- **Adding a comment in the SKILL.md explaining "why the guard."**
  The proposed diagnostic message itself ("rebase failed (exit ...).
  Resolve conflicts and re-run...") is the explanation a reader needs
  in-context. A separate code comment would duplicate it.

## Prerequisites

None. No `blocked-by` relations to set.

## Alternatives considered

1. **Capture-rc-and-branch idiom** (chosen, matches ENG-288's bug body
   verbatim). Verbose but the diagnostic preserves git's actual rebase
   exit code, which is occasionally useful for `close-issue` to
   classify the failure (1 = content conflict, 128 = fatal, etc.).

2. **`if ! git ... rebase main; then ... exit 1; fi`.** Compact and
   idiomatic shell. Loses the actual exit code (`exit 1` always). Not
   used because the bug body's snippet preserves the rc and we have no
   reason to override that choice.

3. **Comprehensive guard pass over Steps 1-3 (or 1-7).** Eliminates
   the whole class of bug in one spec. Rejected for ENG-288 because:
   (a) ENG-241's incident was specifically Step 1, (b) the other
   steps' downstream failures are recoverable in ways Step 1's are
   not, (c) bundling expands the spec's review surface and the
   acceptance criteria are sharper when scoped narrowly. The Step 2/3
   guards are filed as out-of-scope follow-ups instead.

4. **Extract close-branch into a real shell script with `set -e`.**
   Architecturally cleaner but changes the project-local-skills
   pattern. Rejected as a much larger change than the bug warrants,
   and not what the bug body asked for.

5. **Replace the prose taxonomy entirely with "any conflict → exit,
   no advice."** Smallest possible close-branch surface. Rejected
   because the taxonomy is genuinely useful caller-side decision
   support — operators and autonomous sessions both benefit from
   knowing what counts as mechanical vs ambiguous before they decide
   to attempt resolution. Sean confirmed in design dialogue that the
   taxonomy stays.
