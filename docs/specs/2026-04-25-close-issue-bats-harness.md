# Close-issue bats harness — proof of concept

**Linear issue:** ENG-235
**Date:** 2026-04-25
**Status:** Approved

## Motivation

`skills/close-issue/SKILL.md` is ~466 lines of prose with bash inline at every
step. Changes to the skill (e.g. ENG-208's Step 3.5 stale-parent labeling,
ENG-207's blocker check) require manual QA against a real Linear workspace
before they can ship. There's no test harness.

`skills/sr-start/scripts/lib/*.sh` already solved this problem and is
covered by ~3,300 lines of bats across nine files. The harness is proven; it
uses two distinct stubbing patterns documented below.

This issue is the proof-of-concept extraction: pick the smallest meaningful
unit of close-issue, lift it into a sourceable function, add bats coverage
using sr-start's existing patterns. Subsequent extractions (Step 3.5
stale-parent, Step 6 transition wrapper, Step 7 codex broker reap) build on
the harness landed here.

## Scope

Two files added, three files edited. No behavior change beyond one
intentional fix-while-here noted in the design.

### Files added

- `skills/close-issue/scripts/lib/preflight.sh` — defines
  `close_issue_check_review_state`.
- `skills/close-issue/scripts/test/preflight.bats` — covers the new function
  via function-level stubbing of `linear_get_issue_state`.

### Files edited

- `skills/close-issue/SKILL.md` — Pre-flight §1's inline `linear issue view`
  block becomes a single `close_issue_check_review_state` call; Step 6's
  `current_state=$(linear issue view ...)` becomes
  `current_state=$(linear_get_issue_state ...)`.
- `skills/sr-start/scripts/lib/linear.sh` — adds
  `linear_get_issue_state`.
- `skills/sr-start/scripts/test/linear.bats` — adds tests for
  `linear_get_issue_state`.

## Design

### `linear_get_issue_state` (sr-start)

Add to `skills/sr-start/scripts/lib/linear.sh` next to
`linear_get_issue_branch`. Same shape as that function — fail loud with a
named-prefix stderr diagnostic, use `--no-comments` for perf:

```bash
# Get the current workflow state name for an issue.
# Outputs: state name string (e.g. "In Review")
linear_get_issue_state() {
  local issue_id="$1"
  local view_json
  view_json="$(linear issue view "$issue_id" --json --no-comments)" \
    || { printf 'linear_get_issue_state: failed to view %s\n' "$issue_id" >&2; return 1; }
  printf '%s' "$view_json" | jq -r '.state.name'
}
```

Update the file's top-of-file `# Functions:` index comment to include the
new helper (matches existing convention).

### `close_issue_check_review_state` (close-issue)

New file `skills/close-issue/scripts/lib/preflight.sh`. Function captures
the entire Pre-flight §1 disposition, fetch + case statement, as one
sourceable unit:

```bash
#!/usr/bin/env bash
# close-issue preflight helpers.
# Sourced (not executed); do NOT call `set` or `exit` at top level.
#
# Dependencies (caller must have these in scope before sourcing):
#   - linear_get_issue_state from sr-start's lib/linear.sh
#   - $CLAUDE_PLUGIN_OPTION_REVIEW_STATE
#   - $CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE
#   - $CLAUDE_PLUGIN_OPTION_DONE_STATE
#
# Functions:
#   close_issue_check_review_state — verify the issue is in the review state

# Verify $1's current state matches $CLAUDE_PLUGIN_OPTION_REVIEW_STATE.
# Returns 0 if so. On any other state (or helper failure), returns non-zero
# with a hint message on stderr explaining what to do next.
close_issue_check_review_state() {
  local issue_id="$1"
  local state
  state="$(linear_get_issue_state "$issue_id")" || return 1

  if [ "$state" = "$CLAUDE_PLUGIN_OPTION_REVIEW_STATE" ]; then
    return 0
  fi

  case "$state" in
    "$CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE")
      printf '%s is in %s — work has not been handed off for review yet. Run /prepare-for-review first.\n' \
        "$issue_id" "$state" >&2
      ;;
    "$CLAUDE_PLUGIN_OPTION_DONE_STATE")
      printf '%s is already in %s — nothing to do. Investigate whether this worktree is leftover and can be removed.\n' \
        "$issue_id" "$state" >&2
      ;;
    *)
      printf '%s is in %s — dispatch lifecycle is off. Stop and surface to the user.\n' \
        "$issue_id" "$state" >&2
      ;;
  esac
  return 1
}
```

**Never calls `exit`** — it's a sourced lib function; exiting kills the
caller's shell. The SKILL.md call site exits.

**One intentional behavior delta from current SKILL.md:** today's inline
call uses `2>/dev/null`, swallowing Linear API errors. A transient failure
makes `jq` see empty input → outputs `null` → falls into "any other state."
The new function fails loud on `linear_get_issue_state` non-zero, surfacing
the helper's diagnostic. This conflated case is a latent bug worth fixing
while we're here. Not a regression — current behavior already considers any
non-recognized state an error case.

### SKILL.md edits

**Source block** (in the "Source sr-start libs" section): add a
sixth source line for the new close-issue-side preflight lib. The
existing block already loads `defaults.sh`, `linear.sh`, `scope.sh`,
`branch_ancestry.sh` from `$SENSIBLE_RALPH_LIB`. Append:

```bash
source "$CLAUDE_PLUGIN_ROOT/skills/close-issue/scripts/lib/preflight.sh"
```

(Define a `CLOSE_ISSUE_LIB="$CLAUDE_PLUGIN_ROOT/skills/close-issue/scripts/lib"`
var first if you want to mirror the `SENSIBLE_RALPH_LIB` style — single source
line either way, so it's an aesthetic call.) The existing
`source "$SENSIBLE_RALPH_LIB/linear.sh"` line is what makes
`linear_get_issue_state` visible to `preflight.sh` at call time.

**Pre-flight §1** (the "Verify the issue is in the review state"
subsection): replace the entire inline `linear issue view` + `case`
block (the bash code fence under that subsection) with a single call:

```bash
close_issue_check_review_state "$ISSUE_ID" || exit 1
```

Prose around the section (the disposition map bullet list, the
explanation of why this check exists) is retained as-is.

**Step 6** (the "Transition Linear issue to Done" section): replace
the inline state-read with the helper, fail-loud on read failure
(same intentional improvement as Pre-flight §1):

```bash
current_state=$(linear_get_issue_state "$ISSUE_ID") || {
  echo "close-issue: failed to read current state for $ISSUE_ID" >&2
  exit 1
}
if [ "$current_state" != "$CLAUDE_PLUGIN_OPTION_DONE_STATE" ]; then
  linear issue update "$ISSUE_ID" --state "$CLAUDE_PLUGIN_OPTION_DONE_STATE" || {
    echo "close-issue: failed to transition $ISSUE_ID to $CLAUDE_PLUGIN_OPTION_DONE_STATE" >&2
    echo "  The feature branch has already been closed; retry the transition by hand:" >&2
    echo "    linear issue update $ISSUE_ID --state \"$CLAUDE_PLUGIN_OPTION_DONE_STATE\"" >&2
    exit 1
  }
fi
```

The `linear issue update` error block is the existing one from current
SKILL.md — preserve it verbatim. Prose around the section is retained.

### Test patterns

Two patterns reused from sr-start, no invention.

**Pattern 1: PATH-stub the `linear` binary** (used in the existing
`linear.bats`). Used when testing the real `lib/linear.sh` functions —
they're the ones that talk to the `linear` CLI.

**Pattern 2: STUB_DIR mirrored layout** (used in `orchestrator.bats`). The
test creates a tmp directory mirroring `scripts/lib/`, drops a fake
`linear.sh` defining the helpers as bash functions driven by env vars,
then sources the real script-under-test from that mirrored layout. Used
when testing logic that *consumes* `lib/linear.sh` helpers — we want to
control what those helpers return without going through the CLI.

#### `linear.bats` additions (Pattern 1)

Add three test cases for `linear_get_issue_state`:

1. **Returns state name from stubbed JSON.** `STUB_OUTPUT='{"state":{"name":"In Review"}}'`,
   call helper, assert output is `In Review`.
2. **Returns non-zero with diagnostic when stub exits non-zero.**
   `STUB_EXIT=1`, call helper, assert status non-zero and stderr contains
   `linear_get_issue_state: failed to view`.
3. **Calls `linear` with the right argv.** Assert the captured args file
   contains `issue view <id> --json --no-comments`.

These slot in alongside the existing `linear_get_issue_branch` tests —
follow that file's existing structure exactly.

#### `preflight.bats` (Pattern 2)

Header comment must explicitly cite the pattern source so future
contributors don't have to read `orchestrator.bats` to figure out the
shape:

```
# Tests for skills/close-issue/scripts/lib/preflight.sh
# Modeled after skills/sr-start/scripts/test/orchestrator.bats —
# function-level stubbing via STUB_DIR mirrored layout. See linear.bats
# in sr-start for the alternative PATH-stub pattern (used when testing
# helpers that wrap the linear CLI directly).
```

Setup:
- `STUB_DIR=$(mktemp -d)`; `mkdir -p "$STUB_DIR/lib"`.
- Copy real `preflight.sh` into `$STUB_DIR/lib/preflight.sh`.
- Write a fake `$STUB_DIR/lib/linear.sh` that defines
  `linear_get_issue_state` as a bash function reading
  `$STUB_LINEAR_STATE` (the state to return) and `$STUB_LINEAR_RC`
  (the exit code; default 0). On non-zero RC, the fake also writes to
  stderr so Test 5 can assert the diagnostic surfaces.
- Export `CLAUDE_PLUGIN_OPTION_REVIEW_STATE="In Review"`,
  `_IN_PROGRESS_STATE="In Progress"`, `_DONE_STATE="Done"`.
- `call_fn` helper: in a subshell, source `$STUB_DIR/lib/linear.sh`
  then `$STUB_DIR/lib/preflight.sh`, then invoke the function under
  test. (One file-per-helper kept the orchestrator.bats setup readable;
  one file with both helpers is fine for a one-helper-deep dependency.)

Test cases:

1. **state matches review state → returns 0, no stderr.**
   `STUB_LINEAR_STATE="In Review"`.
2. **state is in-progress → returns 1, stderr mentions `/prepare-for-review`.**
3. **state is done → returns 1, stderr mentions "leftover" or "Investigate".**
4. **state is unknown (e.g. `Backlog`) → returns 1, stderr mentions
   "dispatch lifecycle".**
5. **`linear_get_issue_state` returns non-zero (helper failure) → preflight
   returns 1.** `STUB_LINEAR_RC=1`. Asserts the helper's stderr surfaces
   (i.e., not swallowed).

Five tests is enough for proof of concept. The harness pattern is what's
being demonstrated, not exhaustive coverage of one function.

## Out of scope

Each of these is its own follow-up issue, not blocked by ENG-235 unless
explicitly noted:

- **Step 3.5 stale-parent test coverage** — the original ENG-235
  description called this out as the immediate downstream consumer, but
  ENG-208 is already Done. The work is real but file a separate issue when
  the time comes; not a strict prerequisite for ENG-235.
- **Line 79 (`.branchName // empty`) swap to `linear_get_issue_branch`.**
  The existing helper returns `null` (jq's literal output for missing
  fields) where SKILL.md's `// empty` returns nothing. Reconciling the two
  needs a behavior decision (modify the existing helper? coerce at the call
  site?); separate issue.
- **Other inline-bash extractions in close-issue** (Step 3 untracked-file
  preservation, Step 6's `linear issue update` transition wrapper, Step 7
  codex broker reap, the branch-resolver in the "Resolve `FEATURE_BRANCH`
  and `WORKTREE_PATH`" section). Incremental; each gets its own issue
  once this harness is proven.
- **Documenting the harness pattern in a separate playbook doc.** The
  pattern is documented near the code (header comments in the new bats
  file + the existing sr-start bats files). A standalone playbook for
  one pattern is heavier than warranted.
- **CI integration / running bats automatically.** No CI exists in the
  plugin yet (`.github/` is absent). Adding it is a separate concern and
  out of scope here.

## Acceptance criteria

1. `bats skills/close-issue/scripts/test/preflight.bats` runs green
   non-interactively (no Linear network calls).
2. `bats skills/sr-start/scripts/test/linear.bats` runs green — the
   ~30 existing tests still pass alongside the three new ones for
   `linear_get_issue_state`.
3. `skills/close-issue/SKILL.md` Pre-flight §1's inline bash block is
   replaced by a single `close_issue_check_review_state "$ISSUE_ID" || exit 1`
   call. Prose retained.
4. `skills/close-issue/SKILL.md` Step 6's `linear issue view ... | jq
   .state.name` is replaced by `linear_get_issue_state "$ISSUE_ID"` with
   a fail-loud rc check.
5. `linear_get_issue_state` is defined in
   `skills/sr-start/scripts/lib/linear.sh` with the same shape as
   `linear_get_issue_branch`, including `--no-comments`.
6. The new `preflight.bats` header comment names both reference patterns
   (`orchestrator.bats` for function-level stubbing,
   `linear.bats` for PATH-stub) so a contributor reading it understands
   why this file picked the shape it did.
7. `close-issue/scripts/lib/preflight.sh` does not call `exit` — it's a
   sourceable lib file.

## Prerequisites

None. No `blocked-by` relations to set.

## Notes for the autonomous implementer

- Run `bats skills/sr-start/scripts/test/linear.bats` once **before**
  any edits to confirm the baseline passes locally. If it doesn't, stop
  and surface — the failure isn't yours.
- The two patterns this spec invokes (PATH-stub and STUB_DIR mirrored
  layout) are demonstrated in `skills/sr-start/scripts/test/`. Read
  those files; do not invent new patterns.
- The `--no-comments` flag on `linear issue view` is real; the linear-cli
  supports it (existing `linear_get_issue_branch` uses it). Don't omit it
  to "match" the current SKILL.md inline call — the helper's whole job is
  to be the canonical fast-path for state reads.
- SKILL.md's "Source sr-start libs" section already loads `linear.sh`.
  Add the new `preflight.sh` source line after `branch_ancestry.sh` to
  keep the load order: defaults → linear → scope → branch_ancestry →
  preflight. (Section names are stable; line numbers shift as you edit.)
