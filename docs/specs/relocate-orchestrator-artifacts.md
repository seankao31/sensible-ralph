# Relocate orchestrator artifacts under `.sensible-ralph/`

**Linear:** ENG-255
**Status:** Approved
**Project:** Sensible Ralph
**Date:** 2026-04-25

Move the two main-checkout orchestrator artifacts (`progress.json`,
`ordered_queue.txt`) into a subsystem-named hidden directory at the
consumer-repo root, tightening the consumer gitignore from two
filename entries to one directory entry.

## Motivation

The orchestrator currently writes `progress.json` and `ordered_queue.txt`
directly to the consumer repo's root. They're orchestrator subsystem
files but visually compete with first-class repo content (`README.md`,
`CLAUDE.md`, project source, etc.). The conventional place for subsystem
artifacts is a subsystem-named hidden directory.

Moving both into `.sensible-ralph/` tidies the repo root and lets the gitignore
collapse from a list of filenames to a single directory entry. The new
directory coexists with the existing `.sensible-ralph.json` consumer scope file
(different name, different purpose).

ENG-237 previously gitignored these as individual filenames; this ticket
consolidates to a directory entry. ENG-237 is `Done` and lives in the
`Agent Config` Linear project (out of scope for this repo's `.sensible-ralph.json`),
so it's referenced as historical context only — no Linear `blocked-by`
relation.

## In scope

One atomic commit. Nine file surfaces examined below: seven definite
edits, one conditional (only edit on grep hits), one examined and
needs no edit. Paths below are relative to the plugin repo root
(`sensible-ralph/`) unless noted.

### 1. `.gitignore` (plugin's own template)

Replace the two filename entries with one directory entry. `/.worktrees/`
and `ralph-output.log` lines are unchanged.

```gitignore
# Runtime artifacts the orchestrator writes to a consumer repo. Not usually
# relevant inside the plugin repo itself (sensible-ralph isn't typically a
# ralph consumer of its own skills), but shipped so the list is easy to
# copy-paste from here if the plugin's own development ever involves a
# dispatch.
/.sensible-ralph/
/.worktrees/
ralph-output.log
```

The `/.sensible-ralph/` entry covers both `.sensible-ralph/progress.json` and
`.sensible-ralph/ordered_queue.txt`. It does NOT match `.sensible-ralph.json` at the repo
root — different name, intentionally tracked.

### 2. `README.md`

(a) Lines 93-97 (the consumer-repo gitignore example block) get the same
swap as `.gitignore` above.

(b) Add one operator-migration note immediately under the example block,
before the parenthetical "(The paths match the plugin defaults...)" line:

> If you're upgrading from a version that wrote these artifacts at the
> repo root, run `mkdir -p .sensible-ralph && mv progress.json ordered_queue.txt
> .sensible-ralph/ 2>/dev/null` once at your consumer repo's root.

### 3. `skills/sr-start/scripts/orchestrator.sh`

(a) In `_progress_append` (around line 100):

```bash
# Before:
local progress_file="$repo_root/progress.json"
# After:
local progress_file="$repo_root/.sensible-ralph/progress.json"
```

(b) Add a startup `mkdir -p` near the orchestrator's main entry — after
`_resolve_repo_root` binds `repo_root`, before any dispatch (and
therefore before any `_progress_append` call):

```bash
mkdir -p "$repo_root/.sensible-ralph"
```

The implementer picks the natural placement from reading the file. The
constraint is sequencing only: `repo_root` must exist as a variable, and
the mkdir must complete before any `_progress_append` runs. The append
function's atomic `mktemp + mv` pattern requires the destination
directory to exist when `mktemp` runs — startup `mkdir` guarantees this
once for the run.

(c) Header comment line 13 is location-bearing and must be updated:

```text
# Before:
# pre-sorted by toposort.sh. progress.json is written to the repo root
# After:
# pre-sorted by toposort.sh. .sensible-ralph/progress.json is written under the repo root
```

Other narrative references to `progress.json` in this file (lines 10, 75,
91, 94, 131, 253) describe the record contents or atomicity properties,
not the filesystem location — leave them as the bare `progress.json`
identifier.

### 4. `skills/sr-start/SKILL.md`

(a) Step 2 snippet (line 67):

```bash
# Before:
"$SKILL_DIR/scripts/build_queue.sh" > ordered_queue.txt
# After:
mkdir -p .sensible-ralph
"$SKILL_DIR/scripts/build_queue.sh" > .sensible-ralph/ordered_queue.txt
```

(b) Step 4 snippet (line 91):

```bash
# Before:
"$SKILL_DIR/scripts/orchestrator.sh" ordered_queue.txt
# After:
"$SKILL_DIR/scripts/orchestrator.sh" .sensible-ralph/ordered_queue.txt
```

(c) Lines 94, 102, 105, 106 — narrative references to `progress.json`'s
location. Update to `.sensible-ralph/progress.json`. Field-name references
(`failed_step`, `residue_path`, etc.) are unchanged.

### 5. `skills/sr-start/scripts/build_queue.sh`

Line 9 — usage comment:

```bash
# Before:
#   scripts/build_queue.sh > ordered_queue.txt
# After:
#   mkdir -p .sensible-ralph && scripts/build_queue.sh > .sensible-ralph/ordered_queue.txt
```

### 6. `skills/sr-start/scripts/autonomous-preamble.md`

Examined; no edit needed. Line 15 ("The orchestrator records this as
`exit_clean_no_review` in `progress.json`") describes what gets written
to the record, not where the file lives — the bare `progress.json`
identifier reads naturally and the operator finds the file via
`docs/usage.md` anyway.

### 7. `docs/usage.md`

(a) Line 11 — the parenthetical `disjoint progress.json, worktree dirs,
and queue files`. Update `progress.json` → `.sensible-ralph/progress.json`. The
phrase "queue files" is generic and stays as-is.

(b) Line 15 — "Inspect `progress.json` at the repo root" →
"Inspect `.sensible-ralph/progress.json` at the repo root".

### 8. `skills/sr-start/scripts/test/orchestrator.bats`

`grep -n 'progress\.json' skills/sr-start/scripts/test/orchestrator.bats`
returns ~36 hits across the file. Rewrite every path expression
(`$REPO_DIR/progress.json` → `$REPO_DIR/.sensible-ralph/progress.json`) and
preserve path-independent narrative as-is. Tests MUST all pass
post-update with no other changes — that's the load-bearing acceptance
check for this section.

### 9. Stragglers in other bundled skills

Run:

```bash
grep -rn 'progress\.json\|ordered_queue\.txt' \
  skills/close-issue/SKILL.md \
  skills/prepare-for-review/SKILL.md \
  skills/sr-implement/SKILL.md
```

Update each location-bearing reference to the `.sensible-ralph/`-prefixed path.
This list may be empty; only edit on actual hits.

## Out of scope

- The `ralph` → `sensible-ralph` identity rename. Filed as a separate
  Linear stub issue with `blocked-by ENG-255` after this ticket
  approves; specced later in its own `/sr-spec` dialogue.
- Per-worktree artifacts (`.sensible-ralph-base-sha`, `ralph-output.log`).
  Different lifecycle, different filesystem location, well-tested where
  they are.
- `docs/archive/**` — historical snapshots, not touched.
- The three `docs/specs/*-design.md` files in `docs/specs/`
  (`ralph-loop-v2-design.md`, `sr-implement-skill-design.md`,
  `ralph-scope-model-design.md`) — point-in-time design records.
  Intentionally not updated.
- Filename schema or field structure of `progress.json` /
  `ordered_queue.txt`.
- Retention / pruning policy for `progress.json` (separate concern).
- The atomic-write pattern in `_progress_append` (`mktemp + mv`) —
  unchanged; the relocation just needs the destination directory to
  exist.

## Acceptance criteria

1. `.gitignore` lists `/.sensible-ralph/` and does NOT list `/progress.json` or
   `/ordered_queue.txt` as individual filename entries. `/.worktrees/`
   and `ralph-output.log` lines unchanged.

2. `README.md`'s consumer-repo gitignore example matches the plugin's
   own `.gitignore`. The migration one-liner is present and correct.

3. From the consumer repo root with `.sensible-ralph/` existing:
   ```bash
   git check-ignore -v .sensible-ralph/progress.json .sensible-ralph/ordered_queue.txt
   ```
   Both paths resolve against the new `/.sensible-ralph/` block (output
   references `.gitignore:N:/.sensible-ralph/`).

4. A fresh `/sr-start` invocation on a test fixture creates
   `.sensible-ralph/progress.json` (not `progress.json` at the repo root). Verify
   by running:
   ```bash
   bats skills/sr-start/scripts/test/orchestrator.bats
   ```
   All tests pass.

5. Repo-wide grep for stragglers returns only path-independent narrative:
   ```bash
   grep -rn 'progress\.json\|ordered_queue\.txt' \
     skills/ docs/usage.md README.md .gitignore 2>/dev/null \
     | grep -v 'docs/archive/' \
     | grep -v -E '\.sensible-ralph/(progress\.json|ordered_queue\.txt)'
   ```
   Any hit that IS location-bearing must be fixed before the commit
   lands. The grep deliberately excludes `docs/specs/` (this spec file
   itself contains many expected `progress.json` references; the three
   `*-design.md` files in that directory are also out of scope) and
   `docs/archive/**` (historical snapshots).

6. `.sensible-ralph.json` (the consumer scope file at the repo root) is NOT
   ignored — `git check-ignore .sensible-ralph.json` returns no match (or a
   different ignore source than the new `/.sensible-ralph/` block).

7. Per-worktree artifacts unchanged: `.sensible-ralph-base-sha` still written by
   the orchestrator at the worktree root; `ralph-output.log` still
   written there too; `/.worktrees/` and `ralph-output.log` gitignore
   entries intact.

## Verification (run in this order)

1. `bats skills/sr-start/scripts/test/orchestrator.bats` — load-bearing
   integration check.
2. The repo-wide grep from acceptance criterion 5 — must return only
   path-independent narrative.
3. `git check-ignore -v` against a freshly-created `.sensible-ralph/` in a
   scratch repo with the new `.gitignore` template — confirms the
   directory entry resolves both filenames.

If 1-3 all pass, the relocation is verified. No other behavior changes,
so no broader regression suite is needed.

## Operator migration (post-merge, one-shot)

The implementer's worktree cannot see the operator's main-checkout
root-level `progress.json` / `ordered_queue.txt` — they're at a
different filesystem path. After this ticket lands and the operator
merges, a one-time manual command at the consumer repo's root:

```bash
mkdir -p .sensible-ralph
mv progress.json .sensible-ralph/ 2>/dev/null || true
rm -f ordered_queue.txt
```

`progress.json` is preserved (cross-run audit log). `ordered_queue.txt`
is regenerated on every `/sr-start` invocation, so dropping it is
safe.

The README addition (section 2 above) documents this for any consumer
that upgrades.

## Commit shape

One atomic commit. Suggested message:

```
fix: relocate progress.json and ordered_queue.txt under .sensible-ralph/

Move the two main-checkout orchestrator artifacts into a subsystem-named
hidden directory at the consumer-repo root, tightening the gitignore
from two filenames to one directory entry and clearing the root
namespace.

Per-worktree artifacts (.sensible-ralph-base-sha, ralph-output.log) are
untouched — different lifecycle, different filesystem location.

Closes ENG-255.
```

Branch: `eng-255-relocate-progressjson-and-ordered_queuetxt-into-ralph`
(Linear default).
