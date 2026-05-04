# Bats coverage for close-issue Step 3.5 (stale-parent labeling)

**Linear issue:** ENG-236
**Date:** 2026-04-25
**Status:** Implemented

## Motivation

`skills/close-issue/SKILL.md` Step 3.5 (originally added by ENG-208 in the
pre-extraction `close-feature-branch` skill) labels In-Review children of a
parent whose branch was amended during review. The logic is ~140 lines of
bash with non-trivial error accounting (per-child rc tracking, label-existence
guard, blocker-fetch failure handling) and has no automated coverage today.

The QA plan attached to ENG-208 is six scenarios that take meaningful manual
effort against a live Linear workspace each time the step changes. This issue
eliminates that recurring cost by porting the QA plan to `bats` tests using
the harness landed by ENG-235.

ENG-235 deliberately scoped Step 3.5 coverage *out* of its own work (calling
out that ENG-208 was already Done and Step 3.5 coverage could be a clean
follow-up). This issue is that follow-up: harness in place, this issue
exercises it on the next, more complex unit of close-issue.

## Scope

Two files added, one file edited. No behavior change beyond two structural
transforms (function-local scoping for `WARN`/`stale_count`, nested helper
lifted to module level) that are necessary for the extraction.

### Files added

- `skills/close-issue/scripts/lib/stale_parent.sh` — defines
  `close_issue_label_stale_children` and the module-private helper
  `_close_issue_stale_label_and_comment`.
- `skills/close-issue/scripts/test/stale_parent.bats` — covers the new
  function via Pattern 2 (STUB_DIR mirrored layout) per ENG-235's spec.

### Files edited

- `skills/close-issue/SKILL.md` — Step 3.5's inline bash block becomes a
  single `close_issue_label_stale_children` call; the "Source sr-start
  libs" block adds one source line for the new lib. All Step 3.5 prose
  (opening "Ralph v2 dispatches multi-level DAGs…", the "Skip entirely if
  `$INTEGRATION_SHA` is empty" rationale, the "Known limitations" closing)
  is retained verbatim.

### Not edited

No edits to `skills/sr-start/scripts/lib/*.sh`. Every helper Step 3.5
calls (`linear_label_exists`, `linear_get_issue_blocks`, `linear_comment`,
`linear_add_label`, `is_branch_fresh_vs_sha`, `list_commits_ahead`,
`resolve_branch_for_issue`) is already defined as a sourceable function in
sr-start's libs. If the implementer believes a sr-start change is
needed, stop and surface — the design assumes none are.

## Design

### Function signature and contract

```bash
close_issue_label_stale_children ISSUE_ID A_SHA
```

- `ISSUE_ID`: the parent issue (e.g. ENG-208) whose branch just landed.
- `A_SHA`: the integration SHA (`$INTEGRATION_SHA` from `.close-branch-result`).
- **Always returns 0.** Step 3.5 is observational, not a merge-safety gate —
  every failure path today is a `WARN+=` entry, never an `exit 1`. The
  extraction preserves this contract.
- **Empty `A_SHA` → silent no-op return 0.** Absorbs the current "Skip
  entirely if `$INTEGRATION_SHA` is empty" guard. The SKILL.md prose
  explaining *why* stays at the call site.

### Module structure

New file `skills/close-issue/scripts/lib/stale_parent.sh`:

```bash
#!/usr/bin/env bash
# close-issue stale-parent helpers.
# Sourced (not executed); do NOT call `set` or `exit` at top level.
#
# Dependencies (caller must source before invoking):
#   - lib/linear.sh (sr-start): linear_label_exists, linear_get_issue_blocks,
#     linear_comment, linear_add_label
#   - lib/branch_ancestry.sh (sr-start): is_branch_fresh_vs_sha,
#     list_commits_ahead, resolve_branch_for_issue
#   - $CLAUDE_PLUGIN_OPTION_STALE_PARENT_LABEL
#   - $CLAUDE_PLUGIN_OPTION_REVIEW_STATE
#
# Functions:
#   close_issue_label_stale_children — public entry point (Step 3.5)
#   _close_issue_stale_label_and_comment — module-private; comment+label one child

_close_issue_stale_label_and_comment() {
  # Body copied verbatim from today's nested stale_label_and_comment in
  # skills/close-issue/SKILL.md Step 3.5. No edits to function body. Returns:
  #   0 — both succeeded
  #   1 — comment failed (nothing applied)
  #   2 — comment succeeded but label failed
}

close_issue_label_stale_children() {
  local issue_id="$1"
  local a_sha="$2"

  [ -z "$a_sha" ] && return 0

  local a_short
  a_short=$(git rev-parse --short "$a_sha")
  local WARN=()
  local stale_count=0

  # Copy the body of today's Step 3.5 else-branch in skills/close-issue/SKILL.md
  # (everything between `A_SHA="$INTEGRATION_SHA"` and the final
  # `[ "$stale_count" -gt 0 ] && WARN+=(...)` line, exclusive of the early
  # empty-INTEGRATION_SHA guard which is now handled above) into here. Apply
  # only these renames:
  #   $ISSUE_ID         -> $issue_id
  #   $INTEGRATION_SHA  -> $a_sha
  #   $A_SHA            -> $a_sha
  #   $A_SHORT          -> $a_short
  # Update the inner-function call from stale_label_and_comment to
  # _close_issue_stale_label_and_comment. No other changes.

  if [ "${#WARN[@]}" -gt 0 ]; then
    printf '\n⚠️  Step 3.5 notes:\n'
    printf '  - %s\n' "${WARN[@]}"
  fi

  return 0
}
```

### Two structural changes from today (necessary for extraction; not semantic)

1. The `stale_label_and_comment` nested function (defined inside today's
   `else` branch) lifts to module level as
   `_close_issue_stale_label_and_comment`. Bash nested functions leak to
   global scope after the parent runs — the underscore prefix is the
   module-private convention.
2. `WARN` and `stale_count` become function-local (`local`) instead of
   step-scoped globals. Today they're global by accident of bash semantics;
   Step 3.5 is the only consumer in close-issue today, so localization is
   semantics-preserving.

### One named edge case for the implementer

`a_short=$(git rev-parse --short "$a_sha")` runs under the caller's `set -e`.
A malformed `A_SHA` would abort the entire close-issue ritual today; this
extraction does not change that. Add a short TODO comment near the line so
a future hardening lift is signposted. **Not a fix-while-here for this
issue** — out of scope.

### SKILL.md edits

**Source-block addition.** In the "Source sr-start libs" section (the
same section ENG-235's spec adds to), append:

```bash
source "$CLAUDE_PLUGIN_ROOT/skills/close-issue/scripts/lib/stale_parent.sh"
```

Load order: `defaults → linear → scope → branch_ancestry → preflight →
stale_parent`. `stale_parent.sh` consumes both `linear` and `branch_ancestry`
helpers; loading after both is correct.

**Step 3.5 body replacement.** Replace the entire bash code fence with:

```bash
close_issue_label_stale_children "$ISSUE_ID" "$INTEGRATION_SHA"
```

Surrounding prose untouched: opening "Ralph v2 dispatches multi-level
DAGs…", the "Skip entirely if `$INTEGRATION_SHA` is empty" rationale, the
"Known limitations" closing — all retained verbatim.

**Nothing else.** No edits to other steps. No whitespace changes outside the
replaced fence.

### Test design

**File:** `skills/close-issue/scripts/test/stale_parent.bats`. **Pattern 2**
(STUB_DIR mirrored layout) per ENG-235's spec. The header comment must
explicitly cite both reference patterns:

```
# Tests for skills/close-issue/scripts/lib/stale_parent.sh
# Modeled after skills/sr-start/scripts/test/orchestrator.bats —
# function-level stubbing via STUB_DIR mirrored layout. See linear.bats in
# sr-start for the alternative PATH-stub pattern (used when testing the
# helpers themselves rather than logic that consumes them).
```

#### `setup()` (per test)

- `STUB_DIR=$(mktemp -d); mkdir -p "$STUB_DIR/lib"`.
- Copy real `stale_parent.sh` into `$STUB_DIR/lib/stale_parent.sh`.
- Write fake `$STUB_DIR/lib/linear.sh` defining:
  - `linear_label_exists` — rc from `$STUB_LABEL_EXISTS_RC` (default 0).
  - `linear_get_issue_blocks` — emits `$STUB_BLOCKS_JSON`; rc from
    `$STUB_BLOCKS_RC`.
  - `linear_comment` — appends to `$STUB_COMMENT_LOG`; rc per-child via
    `STUB_COMMENT_FAIL_<id>`.
  - `linear_add_label` — appends to `$STUB_LABEL_LOG`; rc per-child via
    `STUB_LABEL_FAIL_<id>`.
- Write fake `$STUB_DIR/lib/branch_ancestry.sh` defining:
  - `is_branch_fresh_vs_sha` — rc per-child via `STUB_FRESH_<id>` (0 fresh,
    1 stale, 2 lookup-failure).
  - `list_commits_ahead` — emits canned text from `STUB_COMMITS_<id>`.
  - `resolve_branch_for_issue` — emits `STUB_BRANCH_<id>`; rc from
    `STUB_RESOLVE_RC_<id>`.
- Real temp git repo via `mktemp -d` + `git init`; pre-commit one commit so
  `git rev-parse --short "$a_sha"` resolves. `cd` into the repo before
  calling the function (matches `branch_ancestry.bats`'s pattern).
- Export `CLAUDE_PLUGIN_OPTION_STALE_PARENT_LABEL="stale-parent"`,
  `CLAUDE_PLUGIN_OPTION_REVIEW_STATE="In Review"`.
- `call_fn` helper: subshell sources `linear.sh`, `branch_ancestry.sh`,
  `stale_parent.sh` in order, then invokes the function under test with the
  passed args.

#### Test cases (eight total)

1. **Empty A_SHA → silent no-op.** Function returns 0; no stub helpers
   invoked; no output.
2. **No amendments — all three children fresh.** `STUB_FRESH_<each>=0`.
   Status 0; label and comment logs empty; no `⚠️ Step 3.5 notes` header in
   output.
3. **Mixed staleness — two stale, one fresh.** Asserts only the stale ones
   appear in label and comment logs; output contains `applied stale-parent
   label to 2 child(ren)`.
4. **Workspace label missing.** `STUB_LABEL_EXISTS_RC=1`. Output contains
   `workspace label stale-parent does not exist`; no labels, no comments.
5. **Per-child label failure.** Two stale children; `STUB_LABEL_FAIL_<X>=1`.
   Asserts comment posted for X, label NOT applied for X, "apply manually"
   hint in output, Y gets full label+comment, summary count is 1 (only Y
   fully succeeded — matches today's rc=2 path).
6. **Blocker-fetch failure.** `STUB_BLOCKS_RC=1`. Output contains `could not
   query outgoing blocks relations`; no labels, no comments.
7. **`CLAUDE_PLUGIN_OPTION_REVIEW_STATE` parameterization.** Two `@test`
   blocks: one with default `In Review`, one with override `Reviewing`. Same
   blocks JSON contains children in mixed states; assert only
   configured-state children get evaluated. Locks the jq filter to the env
   var (which the original ENG-236 description referred to as
   `SENSIBLE_RALPH_REVIEW_STATE` — that name predates the `CLAUDE_PLUGIN_OPTION_*`
   convention introduced in commit 258e2c2).
8. **Simultaneous failures don't mask each other.** One stale child with
   comment-fail (rc=1), another with label-fail (rc=2), another with
   `resolve_branch_for_issue` rc=1. Three distinct WARN entries appear in
   output with distinct messages; per-child rc cases don't short-circuit.

#### WARN ordering and assertion style

WARN entries are appended in deterministic order (workspace-label-check
first, then per-child in iteration order from `linear_get_issue_blocks`,
then the summary). In tests we control the stub's blocks output, so order
is reproducible.

Assertions use substring containment (`[[ "$output" == *"…"* ]]`), not full
ordered-list equality, to avoid coupling tests to incidental whitespace or
the exact wording of unrelated WARN entries.

#### Runtime budget

All eight tests complete in under 5 seconds total (no Linear network calls,
no remote-git operations; only the local temp repo). Hard requirement per
acceptance criterion #1.

## Out of scope

- **Recursive DAG walk to grandchildren.** Current SKILL.md "Known
  limitations" already calls this out; preserved as-is.
- **Cross-step `WARN` plumbing refactor.** This issue makes `WARN` local to
  the new function as a side effect of extraction. Broader refactoring of
  how warnings flow through the larger ritual is a separate concern.
- **Extraction of Steps 1, 2, 3, 4, 6, 7.** Each is a separate follow-up
  issue; ENG-235 set the pattern of one extraction per issue.
- **CI integration / running bats automatically.** No `.github/` exists in
  the plugin yet; ENG-235's spec already deferred this and the same applies
  here.
- **Hardening the `git rev-parse --short` failure path.** Today a malformed
  `A_SHA` aborts the entire close-issue ritual; the extraction does not
  change that. Flag with a TODO comment but defer the fix.

## Acceptance criteria

1. `bats skills/close-issue/scripts/test/stale_parent.bats` runs green
   non-interactively in under 5 seconds; no Linear network calls and no
   remote-git operations.
2. `skills/close-issue/SKILL.md` Step 3.5 body is a single
   `close_issue_label_stale_children "$ISSUE_ID" "$INTEGRATION_SHA"` call;
   opening prose, the "Skip entirely…" rationale, and the "Known limitations"
   closing are all retained verbatim.
3. `skills/close-issue/SKILL.md` source-block adds `stale_parent.sh` after
   `branch_ancestry.sh` (load order: defaults → linear → scope →
   branch_ancestry → preflight → stale_parent).
4. `skills/close-issue/scripts/lib/stale_parent.sh` does not call `exit` or
   `set` at top level; sourceable.
5. `close_issue_label_stale_children` always returns 0 (preserves the
   observational contract — Step 3.5 is not a merge-safety gate).
6. **Diff between today's Step 3.5 body and the new function body shows
   only:** variable renames (`ISSUE_ID → issue_id`, `INTEGRATION_SHA →
   a_sha`, `A_SHA → a_sha`, `A_SHORT → a_short`); the
   `stale_label_and_comment` inner function lifted to module level as
   `_close_issue_stale_label_and_comment`; `WARN`/`stale_count` declared
   `local`; the summary `printf` block moved inside the function. **No
   other logic changes.** A reviewer should be able to verify this by
   inspection.

## Prerequisites

- **`blocked-by` ENG-235** (Sensible Ralph project, in scope per
  `.sensible-ralph.json`) — establishes the harness pattern and creates
  `skills/close-issue/scripts/{lib,test}/`. Without it, this issue's added
  files have nowhere to land.

## Related (no blocking)

- **ENG-208** (Agent Config) — historical motivation; the QA plan being
  retired. Already `Done`. Out-of-scope per `.sensible-ralph.json`, but `related`
  doesn't trip the cross-project preflight.
- **ENG-213** (Agent Config) — the `close-feature-branch` → `close-issue`
  rename. Already `Done`. Out-of-scope per `.sensible-ralph.json` for the same reason
  as ENG-208.

## Notes for the autonomous implementer

- Run `bats skills/close-issue/scripts/test/preflight.bats` (the harness's
  proof-of-concept test from ENG-235) once **before** any edits to confirm
  the baseline passes locally. If it doesn't, stop and surface — the
  failure isn't yours.
- The two patterns this spec invokes (PATH-stub and STUB_DIR mirrored
  layout) are demonstrated in `skills/sr-start/scripts/test/`. Read
  those files; do not invent new patterns.
- Do not edit `skills/sr-start/scripts/lib/*.sh`. If you believe a
  sr-start change is needed, stop and surface — the design assumes the
  existing helpers cover everything Step 3.5 needs.
- The "lifted verbatim" framing in Acceptance Criterion #6 is load-bearing:
  copy Step 3.5's body into the function and apply only the listed
  transforms. Anything else is a regression.
- Test runtime is capped at 5 seconds total. If you find yourself needing
  real network or remote-git operations, the harness pattern is being
  misapplied — re-read ENG-235's spec.
