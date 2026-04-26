---
name: close-branch
description: Project-local VCS integration for sensible-ralph. Runs rebase onto local `main`, no-ff merge to `main`, push, HEAD detach, and branch delete for a reviewed feature branch. Invoked ONLY by the global `close-issue` skill — not a user entry point. sensible-ralph specifics: base branch is `main`, direct-to-main push (no PR), `--no-ff` merge so each closed issue lands as a single merge commit, `-d` (safe delete) for branch removal, rebase onto LOCAL main (not `origin/main`) to absorb unpushed direct-to-main commits.
argument-hint: <issue-id>
model: sonnet
allowed-tools: Bash, Read, Glob, Grep
user-invocable: false
---

# Close Branch (sensible-ralph)

The VCS integration half of the close ritual. The global `close-issue` skill handles Linear state preflight, untracked-file preservation, stale-parent labeling, the Done transition, and worktree removal; this skill handles every project-specific git decision: base branch, rebase policy, merge strategy, push model, branch-delete semantics.

## When to Use

Only via `Skill(close-branch)` invoked from `close-issue`. Never a direct user entry point.

`user-invocable: false` hides this skill from the `/` menu so a human can't accidentally type `/close-branch` instead of `/close-issue`. The description is phrased to discourage autonomous description-based auto-pick — `close-branch` should only be entered via explicit dispatch from `close-issue`.

## Inputs on entry

`close-issue` hands off three values via a file at `$MAIN_REPO/.close-branch-inputs` (single-quoted `KEY='VALUE'` format, sourceable):

- `ISSUE_ID` — Linear issue identifier (for logging).
- `FEATURE_BRANCH` — local branch name resolved by `close-issue`.
- `WORKTREE_PATH` — absolute worktree path resolved by `close-issue`.

Shell variables from `close-issue`'s Bash calls don't reliably propagate to this skill's Bash calls — each call is a fresh shell, and the spec calls out that exports don't cross Skill-tool invocation boundaries. File-based handoff is symmetric with the result-file return channel.

These preconditions are also guaranteed:

- CWD is the main checkout (`close-issue` verified `.git` is a directory).
- Linear issue is in `$CLAUDE_PLUGIN_OPTION_REVIEW_STATE` with all `blocked-by` parents in `$CLAUDE_PLUGIN_OPTION_DONE_STATE`.
- Untracked files in `$WORKTREE_PATH` have been preserved or explicitly discarded.

Source the inputs and derive `MAIN_REPO`:

```bash
MAIN_REPO=$(git rev-parse --show-toplevel)
if [ ! -f "$MAIN_REPO/.close-branch-inputs" ]; then
  echo "Error: $MAIN_REPO/.close-branch-inputs is missing — close-issue must write it before invoking close-branch." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$MAIN_REPO/.close-branch-inputs"
rm -f "$MAIN_REPO/.close-branch-inputs"

if [ -z "$ISSUE_ID" ] || [ -z "$FEATURE_BRANCH" ] || [ -z "$WORKTREE_PATH" ]; then
  echo "Error: one or more of ISSUE_ID/FEATURE_BRANCH/WORKTREE_PATH is empty after sourcing .close-branch-inputs." >&2
  exit 1
fi
```

All subsequent commands reference `$FEATURE_BRANCH`, `$ISSUE_ID`, `$WORKTREE_PATH`, and `$MAIN_REPO`. The CWD stays at `$MAIN_REPO` throughout; worktree-side operations use `git -C "$WORKTREE_PATH" …`.

## Pre-flight: no uncommitted tracked-file changes in the worktree

```bash
git -C "$WORKTREE_PATH" status --short
```

- **Any line NOT starting with `??`** — uncommitted changes to tracked files (includes ` M`, `MM`, `UU`, `T`, `A`, `D`, `R`, etc.). Exit non-zero with a diagnostic: the operator must commit or discard them before re-running. `git worktree remove` will refuse to clean up a dirty worktree, and `--force` has destroyed work before — never reach for it.
- **Lines starting with `??`** — untracked files. `close-issue` handled these before invoking us; if any remain, something's off. Exit non-zero.
- **No output** — clean; proceed.

## The Ritual (run in order)

### Step 1: Rebase onto latest main

```bash
git -C "$WORKTREE_PATH" fetch origin main
git -C "$WORKTREE_PATH" rebase main
```

Rebase onto **local** `main`, not `origin/main`. Direct commits to local main happen during plugin development (progress notes, doc tweaks) without immediate push; rebasing onto local main absorbs those so Step 2's merge has a clean linear pre-merge history. The `git fetch` is still useful — Step 2's `git pull --ff-only origin main` catches any movement on the remote before the merge.

The rebase matters even though Step 2 uses `--no-ff` (which doesn't *require* a fast-forward). Without it, the merge commit's first-parent line on `main` would zigzag through pre-rebase history, and `git log --first-parent main` (the canonical "what landed and when" view) would lose its readable shape.

**If rebase fails with conflicts:** resolve them yourself when the right answer is mechanical, then `git -C "$WORKTREE_PATH" add <files>` and `git -C "$WORKTREE_PATH" rebase --continue`. The goal is minimal human intervention *when the decision is mechanical*.

Mechanical resolutions (resolve, don't escalate):

- Unrelated edits in adjacent regions (formatting, nearby lines, imports) — keep both.
- Same logical change landed on both sides — drop the feature-branch duplicate; take main's version.
- Both sides appended different items to the same list, changelog, or docs section — merge the content.

Abort (`git rebase --abort`) and exit non-zero only when:

- Both sides made substantive, contradicting changes to the same logic.
- A file was deleted on one side and modified on the other.
- The right answer isn't obvious without user context.

Silently picking a side on ambiguous logic is worse than stopping — the "minimal intervention" principle applies only when the decision is obvious.

### Step 2: No-ff merge to main

CWD is already the main checkout. Verify it has no uncommitted tracked-file changes (the user also uses this checkout for ad-hoc edits):

```bash
git status --short --untracked-files=no
```

If this produces any output, exit non-zero. Do not merge into a dirty main checkout — a failed `git pull --ff-only` or merge can leave both the main checkout and the close ritual half-completed.

`--untracked-files=no` suppresses `??` lines so leftover ralph artifacts, stray plan drafts, or any other untracked file in the main checkout don't trip this gate. Only uncommitted changes to *tracked* files threaten the merge.

Once clean, capture a safety ref before the merge so Step 3 can restore main if the push is rejected and retry isn't viable:

```bash
git checkout main
git pull --ff-only origin main
PRE_MERGE_SHA=$(git rev-parse main)
```

Now compose the merge commit message. Follow the project's commit-message convention (top-level `CLAUDE.md` "Commit messages"); two things matter more for the merge commit than for individual commits:

- Because `--no-ff` lands exactly one merge commit per closed issue, `git log --first-parent main` is the project's de facto changelog. The subject describes user-facing behavior — what shipped — not files or mechanics. "update SKILL.md", "refactor helper", "add tests" are fine on the feature commits underneath; the merge subject is the release-log line. Inspect what shipped with `git log --oneline main.."$FEATURE_BRANCH"`.
- `Ref: $ISSUE_ID` always applies here (close-branch is per-Linear-issue). Retrospective lookup is `git log --first-parent main --grep='Ref: <id>'`.

Merge with multiple `-m` flags — each becomes a paragraph separated by a blank line:

```bash
git merge --no-ff "$FEATURE_BRANCH" \
  -m "<composed subject>" \
  -m "Ref: $ISSUE_ID"
```

Add an additional `-m "<body>"` between the subject and the `Ref:` trailer when context is worth recording (non-obvious tradeoff, follow-up needed, surprising scope). Skip the body when the subject is self-explanatory.

`--no-ff` always succeeds when the feature branch is a descendant of `main`, which Step 1's rebase guarantees.

If `git pull --ff-only origin main` fails (origin/main advanced *and* local main has commits not on origin), that's a divergent local main — outside this skill's scope. Exit non-zero and tell the operator to reconcile their local main first.

If the merge itself reports a conflict (extremely rare after a successful rebase, but possible if origin/main moved between Step 1's `git fetch` and Step 2's `git pull`), abort with `git merge --abort` and re-run from Step 1 — the worktree needs to rebase onto the new main.

Never use `--ff-only` here. This project's convention is `--no-ff` so each closed issue lands as a single, identifiable merge commit on main. Squashing the feature commits into the merge would also lose intra-feature history; plain `--no-ff` (no `--squash`) is correct.

### Step 3: Push

Still in the main checkout:

```bash
git push origin main
```

**Invariant:** this skill must not exit while local `main` is ahead of `origin/main`. A rejected push leaves local main with a merge commit that origin doesn't accept — exiting here would leave the main checkout in a state where a stray `git push --force` would rewrite shared history. Two compliant exit paths:

1. **Retry path** (preferred): if a push rejection is recoverable by re-rebasing onto the new origin/main, do the full recovery here:
   1. `git fetch origin main` — a rejected push does not reliably update the local `origin/main` tracking ref. Without an explicit fetch, the subsequent reset would land on the *pre-rejection* origin/main (stale), the worktree rebase would target that stale ref, and Step 2's `git pull --ff-only` would finally advance local main — leaving the worktree branch based on an ancestor of the new HEAD.
   2. `git reset --hard origin/main` on local main (discards the local merge commit; the feature commits are still reachable via `$FEATURE_BRANCH`).
   3. Re-run Step 1 on the worktree (rebase onto the now-fresh local main, which equals the new origin/main).
   4. Re-run Step 2 (capture a fresh `$PRE_MERGE_SHA`, no-ff merge).
   5. Re-run the push.

2. **Reset path** (fallback if retry is not recoverable within this skill): restore local main to its pre-merge state so the operator can investigate without the merge commit in the way, then exit non-zero with a clear diagnostic:

   ```bash
   git reset --hard "$PRE_MERGE_SHA"
   ```

   The feature branch ref still points at the rebased feature commits; nothing is destroyed.

If neither path completes cleanly, escalate to the operator — but **never exit non-zero while local main contains the merge commit and `origin/main` does not.**

### Step 4: Capture return values

Immediately after a successful push, before any cleanup:

```bash
INTEGRATION_SHA=$(git rev-parse HEAD)
INTEGRATION_SUMMARY="merged to main @ $(git rev-parse --short HEAD) (no-ff) and pushed"
```

`HEAD` here is the merge commit, not the feature branch tip — that's the right SHA for `close-issue`'s stale-parent ancestry checks because it's the commit that actually exists on `main`.

### Step 5: Detach HEAD in the worktree

`git branch -d` refuses to delete a branch that is checked out in any worktree. Detach HEAD in the worktree before deleting the branch:

```bash
git -C "$WORKTREE_PATH" checkout --detach
```

The worktree directory stays intact with a detached HEAD; working files are unchanged.

### Step 6: Delete the feature branch

With the branch no longer checked out anywhere, delete it locally. Then delete it on the remote — **but only if it was ever pushed there**. Ralph-dispatched branches are built and merged without ever being pushed to `origin`; the content reaches `main` via Step 2's no-ff merge and Step 3's push of `main`. For those branches the remote feature ref doesn't exist, and `git push origin --delete` would fail. Check with `git ls-remote` and skip the remote delete when the ref is missing.

```bash
git branch -d "$FEATURE_BRANCH"
if git ls-remote --exit-code --heads origin "$FEATURE_BRANCH" >/dev/null 2>&1; then
  git push origin --delete "$FEATURE_BRANCH"
else
  echo "remote ref for $FEATURE_BRANCH does not exist on origin — skipping remote delete (local-only branch)"
fi
```

Use `-d` (safe delete), not `-D` (force delete). With `--no-ff`, `git branch -d` still recognizes the branch as merged because the merge commit has the branch tip as its second parent — so `-d` works without escalation. If `-d` refuses, something went wrong with the rebase/merge — exit non-zero and let the operator investigate before escalating to `-D`.

### Step 7: Write the result file

Last step on success. Write `$MAIN_REPO/.close-branch-result` with the return values; `close-issue` sources this file on return and deletes it.

Values must be single-quoted — `close-issue` uses `source` to read the file, and an unquoted `INTEGRATION_SUMMARY=merged to main @ ...` would parse as `VAR=VALUE cmd args` (env-prefix + `to` as a command), leaving the summary unset and emitting a command-not-found error. `INTEGRATION_SHA` is a hex git SHA (no quoting hazard); `INTEGRATION_SUMMARY` here has no embedded single quotes, so plain single-quoting is sufficient:

```bash
{
  printf "INTEGRATION_SHA='%s'\n" "$INTEGRATION_SHA"
  printf "INTEGRATION_SUMMARY='%s'\n" "$INTEGRATION_SUMMARY"
} > "$MAIN_REPO/.close-branch-result"
```

On failure at any earlier step, do NOT write this file. `close-issue` treats an absent file as empty values, which correctly skips stale-parent labeling and falls back to a generic final message.

`.close-branch-result` is gitignored at the repo root.

## Red Flags / When to Stop

- **Rebase introduces conflicts that need user context.** `git rebase --abort` and exit non-zero. Mechanical conflicts are resolved inline; only ambiguous/contradicting ones stop here.
- **Push is rejected AND neither retry nor reset completes cleanly.** Escalate; never exit while local main is ahead of origin/main.
- **Main has moved during the ritual.** Re-rebase and re-merge via the retry path. Do NOT bridge with an extra merge commit — the convention is "one merge commit per closed issue", not a chain of fix-up merges.
- **`-d` refuses to delete the branch.** The branch isn't merged despite the preceding no-ff merge. Exit non-zero; do NOT escalate to `-D`.

## Explicitly out of scope

- **Linear state transitions, stale-parent labeling, untracked-file preservation, worktree removal, codex broker reap** — all handled by `close-issue`. This skill is pure git.
- **Tests, code review, docs, decision captures** — belong in `/prepare-for-review`, which runs earlier.
- **Tags, release notes** — N/A; this plugin doesn't version with tags.
- **Multi-branch cascades** (dev → staging → main) — N/A; this repo is main-only.
- **PR-based integration** — this skill is direct-to-main. A project that opens PRs instead would ship its own `close-branch` and leave `$INTEGRATION_SHA` empty (a PR-pending signal `close-issue` handles natively).
- **Squash merges** — explicitly rejected. `--no-ff` (without `--squash`) preserves intra-feature history under the merge commit; squashing would hide it.
- **Undoing a close** — if the wrong branch was closed, use git reflog to recover rather than asking this skill to "unclose".
