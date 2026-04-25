# Restructure plugin-wide shell helpers out of `ralph-start/scripts/`

**Linear:** ENG-274
**Date:** 2026-04-25

## Goal

Move the four plugin-wide shell helpers — `defaults.sh`, `linear.sh`,
`scope.sh`, `branch_ancestry.sh` — and their bats tests out of
`skills/ralph-start/scripts/lib/` and into a top-level `lib/` directory
at plugin root. Update every consumer to source from the new location.
Leave the two ralph-start-specific helpers (`worktree.sh`,
`preflight_labels.sh`) where they are.

## Motivation

The four shared helpers are currently sourced by `ralph-spec`,
`prepare-for-review`, and `close-issue` via paths like
`$CLAUDE_PLUGIN_ROOT/skills/ralph-start/scripts/lib/...`. That path
falsely implies ralph-start ownership. The helpers are plugin-wide
infrastructure: pure config exports (`defaults.sh`), Linear API
wrappers (`linear.sh`), `.ralph.json` parsing (`scope.sh`), and pure-git
ancestry helpers (`branch_ancestry.sh`).

The chezmoi → plugin extraction created the conditions to fix this.
`branch_ancestry.sh`'s own header already anticipated the move:

> When the ralph-workflow skills consolidate into a standalone plugin,
> these helpers relocate with the rest of the shared plumbing — the
> current location is pragmatic, not principled.

The plugin extraction is complete. The structural debt is cheap to pay
down now while the consumer surface is small (three skills) and the
test suite covers each moved lib in isolation.

## Scope

Move four `.sh` files and three `.bats` files; update three SKILL.md
files and four ralph-start internal scripts; update the stub layouts
in three or four bats test files. The change is path-only — no behavior
changes in any moved file.

## Target structure (post-move)

```
sensible-ralph/
├── .claude-plugin/
├── docs/
├── lib/                           ← NEW
│   ├── defaults.sh                ← moved from skills/ralph-start/scripts/lib/
│   ├── linear.sh                  ← moved
│   ├── scope.sh                   ← moved
│   ├── branch_ancestry.sh         ← moved
│   └── test/                      ← NEW
│       ├── linear.bats            ← moved
│       ├── scope.bats             ← moved
│       └── branch_ancestry.bats   ← moved
└── skills/
    └── ralph-start/scripts/
        ├── orchestrator.sh
        ├── build_queue.sh
        ├── preflight_scan.sh
        ├── dag_base.sh
        ├── toposort.sh
        ├── autonomous-preamble.md
        ├── lib/                   ← retained for ralph-start-only helpers
        │   ├── worktree.sh
        │   └── preflight_labels.sh
        └── test/                  ← retained for ralph-start-only tests
            ├── orchestrator.bats
            ├── build_queue.bats
            ├── preflight_scan.bats
            ├── dag_base.bats
            ├── toposort.bats
            └── worktree.bats
```

## Per-helper partition

| File | Move? | Reason |
|------|-------|--------|
| `defaults.sh` | → `lib/` | Sourced by ralph-spec, prepare-for-review, close-issue. Pure config exports — no skill-specific logic. |
| `linear.sh` | → `lib/` | Sourced by ralph-spec, close-issue. Linear CLI/GraphQL wrappers — domain layer, not skill-specific. |
| `scope.sh` | → `lib/` | Sourced by ralph-spec. Reads `.ralph.json`, which is a plugin-wide concept (every consumer repo declares it). |
| `branch_ancestry.sh` | → `lib/` | Sourced by close-issue. Pure git, no Linear or skill coupling. Header explicitly anticipates this move. |
| `worktree.sh` | stay | Sourced only by `orchestrator.sh`. Encodes ralph-start dispatch's worktree semantics. |
| `preflight_labels.sh` | stay | Sourced only by `preflight_scan.sh`. Tied to ralph-start's preflight ritual. |

The partition criterion is "who sources this?" — single skill (stay)
vs multiple skills (move). It is not "what does it do?" The two
ralph-start-only helpers theoretically *could* be reused; lifting them
now would be speculative.

## File-by-file changes

The work splits into four classes of edit: move operations, consumer
SKILL.md updates, ralph-start internal script updates, and bats test
updates.

### (a) Move operations

```bash
mkdir -p lib/test

git mv skills/ralph-start/scripts/lib/defaults.sh        lib/defaults.sh
git mv skills/ralph-start/scripts/lib/linear.sh          lib/linear.sh
git mv skills/ralph-start/scripts/lib/scope.sh           lib/scope.sh
git mv skills/ralph-start/scripts/lib/branch_ancestry.sh lib/branch_ancestry.sh

git mv skills/ralph-start/scripts/test/linear.bats          lib/test/linear.bats
git mv skills/ralph-start/scripts/test/scope.bats           lib/test/scope.bats
git mv skills/ralph-start/scripts/test/branch_ancestry.bats lib/test/branch_ancestry.bats
```

Each `.bats` file uses
`SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"` to
reach its target lib at `$SCRIPT_DIR/<file>.sh`. Since the bats files
move *together with* their libs into `lib/test/`, that `$SCRIPT_DIR`
resolution still works — `lib/test/scope.bats`'s parent is `lib/`,
where `scope.sh` now lives. **No edits required inside the moved bats
files themselves.**

Update the now-stale comments inside `lib/branch_ancestry.sh` (formerly
`skills/ralph-start/scripts/lib/branch_ancestry.sh`):

- Remove the obsolete sentence in the header comment: *"When the
  ralph-workflow skills consolidate into a standalone plugin, these
  helpers relocate with the rest of the shared plumbing — the current
  location is pragmatic, not principled."* The relocation has happened.
- Update the line *"Co-located under scripts/lib/ with the Linear
  helpers because close-issue already sources from here."* to reflect
  the new location (`lib/` at plugin root, alongside `linear.sh`).

No other intra-file content changes are required — the libs themselves
are unchanged at the function level.

### (b) Consumer SKILL.md updates

Three SKILL.md files reference the old paths.

**`skills/ralph-spec/SKILL.md`** (currently lines 165, 166, 170 — line
numbers may shift; update by exact-string match):

```diff
-source "$CLAUDE_PLUGIN_ROOT/skills/ralph-start/scripts/lib/defaults.sh"
-source "$CLAUDE_PLUGIN_ROOT/skills/ralph-start/scripts/lib/linear.sh" || {
+source "$CLAUDE_PLUGIN_ROOT/lib/defaults.sh"
+source "$CLAUDE_PLUGIN_ROOT/lib/linear.sh" || {
   echo "ralph-spec: failed to source linear.sh — \$CLAUDE_PLUGIN_ROOT may be unset (sensible-ralph plugin not enabled?). Re-enable the plugin and re-run." >&2
   exit 1
 }
-source "$CLAUDE_PLUGIN_ROOT/skills/ralph-start/scripts/lib/scope.sh" || {
+source "$CLAUDE_PLUGIN_ROOT/lib/scope.sh" || {
```

**`skills/close-issue/SKILL.md`** (currently around line 55):

```diff
-RALPH_LIB="$CLAUDE_PLUGIN_ROOT/skills/ralph-start/scripts/lib"
-source "$RALPH_LIB/defaults.sh"
-source "$RALPH_LIB/linear.sh"
-source "$RALPH_LIB/scope.sh"
-source "$RALPH_LIB/branch_ancestry.sh"
+PLUGIN_LIB="$CLAUDE_PLUGIN_ROOT/lib"
+source "$PLUGIN_LIB/defaults.sh"
+source "$PLUGIN_LIB/linear.sh"
+source "$PLUGIN_LIB/scope.sh"
+source "$PLUGIN_LIB/branch_ancestry.sh"
```

The variable rename (`RALPH_LIB` → `PLUGIN_LIB`) reflects the new
ownership. Also update the surrounding prose paragraph that currently
says *"Source from the bundled ralph-start skill at
`$CLAUDE_PLUGIN_ROOT/skills/ralph-start/`"* — the libs no longer live
under ralph-start. The replacement prose should say the libs are
sourced from the plugin's top-level `lib/` directory.

**`skills/prepare-for-review/SKILL.md`** (currently around line 36):

```diff
-source "$CLAUDE_PLUGIN_ROOT/skills/ralph-start/scripts/lib/defaults.sh"
+source "$CLAUDE_PLUGIN_ROOT/lib/defaults.sh"
```

### (c) ralph-start internal script updates

Four scripts under `skills/ralph-start/scripts/` source the moved libs
via `$SCRIPT_DIR/lib/...`. After the move, that path resolves to
`skills/ralph-start/scripts/lib/`, which now contains only `worktree.sh`
and `preflight_labels.sh` — the moved files are no longer there.

The new pattern: introduce a `PLUGIN_ROOT` variable at the top of each
script that prefers `$CLAUDE_PLUGIN_ROOT` (set by the plugin harness in
production) and falls back to walking up from `$SCRIPT_DIR` (so bats
tests can run without setting the env var):

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
```

The `../../../` is three levels up: `scripts/` → `ralph-start/` →
`skills/` → plugin root.

Source-line changes per script:

| Script | Old | New |
|--------|-----|-----|
| `orchestrator.sh` | `$SCRIPT_DIR/lib/{defaults,linear,scope}.sh`; `$SCRIPT_DIR/lib/worktree.sh` | `$PLUGIN_ROOT/lib/{defaults,linear,scope}.sh` (moved); `$SCRIPT_DIR/lib/worktree.sh` (unchanged) |
| `build_queue.sh` | `$SCRIPT_DIR/lib/{defaults,linear,scope}.sh` | `$PLUGIN_ROOT/lib/{defaults,linear,scope}.sh` |
| `preflight_scan.sh` | `$SCRIPT_DIR/lib/{defaults,linear,scope,preflight_labels}.sh` | `$PLUGIN_ROOT/lib/{defaults,linear,scope}.sh` (moved); `$SCRIPT_DIR/lib/preflight_labels.sh` (unchanged) |
| `dag_base.sh` | `$SCRIPT_DIR/lib/{defaults,linear,scope}.sh` | `$PLUGIN_ROOT/lib/{defaults,linear,scope}.sh` |

The `# shellcheck source=lib/<file>.sh` directives above each `source`
line need their hint paths updated. For moved libs, hints become
`# shellcheck source=../../../lib/<file>.sh`. Hints for ralph-start-only
libs (`worktree.sh`, `preflight_labels.sh`) stay
`# shellcheck source=lib/<file>.sh`.

Header comments inside these scripts that mention `lib/<file>.sh`
sourcing paths should be skimmed and updated where the prose names a
specific path (e.g., `orchestrator.sh`'s top comment notes worktree.sh
resolution; that comment references a path that's still correct, so
no edit there). Where a header lists "sources from lib/..." for a now-
moved lib, qualify it as "sources from the plugin's top-level lib/".

### (d) Bats test updates

Two surfaces need attention.

**Tests that build stub directories.** `preflight_scan.bats` currently
builds a stub at `$STUB_DIR/lib/{defaults,linear,preflight_labels}.sh`
and copies `preflight_scan.sh` into `$STUB_DIR/`, so the script's
`$SCRIPT_DIR/lib/...` resolves to the stub libs. After the move, the
script reads `defaults.sh`, `linear.sh`, `scope.sh` from
`$PLUGIN_ROOT/lib/` and `preflight_labels.sh` from `$SCRIPT_DIR/lib/`.
The test must build a stub plugin root:

```
$STUB_PLUGIN_ROOT/
├── lib/
│   ├── defaults.sh         (copied from real lib/defaults.sh)
│   ├── linear.sh           (synthesized stub — same approach as today)
│   └── scope.sh            (real or stubbed — match current behavior)
└── skills/ralph-start/scripts/
    ├── preflight_scan.sh   (copied)
    └── lib/
        └── preflight_labels.sh (copied)
```

Then `export CLAUDE_PLUGIN_ROOT="$STUB_PLUGIN_ROOT"` before invoking
`preflight_scan.sh`. The script's `PLUGIN_ROOT` resolution picks up
the env var and reads from the stub.

**Other entry-point bats files (`orchestrator.bats`, `build_queue.bats`,
`dag_base.bats`).** Apply the equivalent fix where they construct stub
layouts that encode the old `$SCRIPT_DIR/lib/` structure. Tests that
don't construct stubs and just source the real scripts work without
changes — the fallback walk-up from `$SCRIPT_DIR` resolves correctly
when the test invokes the real script in its real location.

The implementer should grep these bats files for `lib/` references
during the migration and apply the stub-layout update consistently.

### What does NOT change

- `skills/ralph-start/scripts/lib/{worktree,preflight_labels}.sh` — stay
  put.
- `skills/ralph-start/scripts/test/{worktree,preflight_scan,build_queue,dag_base,orchestrator,toposort}.bats`
  — stay put (their bats files test scripts that remain in
  `skills/ralph-start/scripts/`).
- `skills/ralph-start/scripts/{toposort.sh,autonomous-preamble.md}` —
  toposort doesn't source any libs; the preamble is markdown.
- `README.md` — its only `skills/ralph-start/scripts/...` reference is
  `autonomous-preamble.md`, which doesn't move.
- Historical specs in `docs/specs/` and `docs/archive/` — these document
  past work at the paths that existed when written. Retroactive
  path-edits would falsify the historical record.
- `.gitignore` — runtime-artifact patterns are unaffected.
- `.claude-plugin/plugin.json` — no userConfig or surface-area changes.
- `.ralph.json` — no schema changes.

## Verification

After the implementation lands, all of the following must hold.

1. **Files at new locations:**
   ```bash
   test -f lib/defaults.sh && \
   test -f lib/linear.sh && \
   test -f lib/scope.sh && \
   test -f lib/branch_ancestry.sh && \
   test -f lib/test/linear.bats && \
   test -f lib/test/scope.bats && \
   test -f lib/test/branch_ancestry.bats
   ```

2. **Files removed from old locations:**
   ```bash
   test ! -e skills/ralph-start/scripts/lib/defaults.sh && \
   test ! -e skills/ralph-start/scripts/lib/linear.sh && \
   test ! -e skills/ralph-start/scripts/lib/scope.sh && \
   test ! -e skills/ralph-start/scripts/lib/branch_ancestry.sh && \
   test ! -e skills/ralph-start/scripts/test/linear.bats && \
   test ! -e skills/ralph-start/scripts/test/scope.bats && \
   test ! -e skills/ralph-start/scripts/test/branch_ancestry.bats
   ```

3. **ralph-start-only helpers retained:**
   ```bash
   test -f skills/ralph-start/scripts/lib/worktree.sh && \
   test -f skills/ralph-start/scripts/lib/preflight_labels.sh
   ```

4. **No stale source paths in any active consumer:**
   ```bash
   ! grep -rn "skills/ralph-start/scripts/lib/\(defaults\|linear\|scope\|branch_ancestry\)" \
     skills/ docs/specs/ 2>/dev/null
   ```
   The grep excludes `docs/archive/` (historical records keep their
   original paths). `docs/specs/` is included because it contains both
   completed and active specs; once ENG-273 has landed, its spec file
   becomes a historical record but stays in `docs/specs/` rather than
   being moved to `docs/archive/`. The verification asserts that no
   active-spec content still references the moved paths after this
   issue completes.

5. **Each consumer skill markdown sources from the new location:**
   ```bash
   grep -q 'CLAUDE_PLUGIN_ROOT/lib/defaults.sh' skills/ralph-spec/SKILL.md && \
   grep -q 'CLAUDE_PLUGIN_ROOT/lib/defaults.sh' skills/prepare-for-review/SKILL.md && \
   grep -q 'CLAUDE_PLUGIN_ROOT/lib/defaults.sh' skills/close-issue/SKILL.md
   ```

6. **All bats suites pass.** Run from repo root:
   ```bash
   bats lib/test/*.bats
   bats skills/ralph-start/scripts/test/*.bats
   ```
   Both invocations exit 0. The first covers the moved libs; the
   second covers the entry-point scripts and the still-resident
   `worktree.sh`, validating that `PLUGIN_ROOT` resolution and updated
   stub-fixture layouts work.

7. **Smoke source from the harness path.** Confirms the new source
   pattern works as a consumer skill would invoke it:
   ```bash
   bash -c 'set -eu
            export CLAUDE_PLUGIN_ROOT="'"$(pwd)"'"
            source "$CLAUDE_PLUGIN_ROOT/lib/defaults.sh"
            source "$CLAUDE_PLUGIN_ROOT/lib/linear.sh"
            source "$CLAUDE_PLUGIN_ROOT/lib/scope.sh"
            source "$CLAUDE_PLUGIN_ROOT/lib/branch_ancestry.sh"
            printf "%s\n" "$CLAUDE_PLUGIN_OPTION_APPROVED_STATE"' \
     | grep -qx 'Approved'
   ```

The autonomous session should run all seven verifications inline and
abort before handoff if any fail.

## Prerequisites

- **`blocked-by ENG-273`** — ENG-273 (currently `Todo`, in scope
  `Sensible Ralph`) adds `CLAUDE_PLUGIN_OPTION_DESIGN_STATE` to
  `defaults.sh` at its current path. ENG-273 must land first so its
  targeted edit applies cleanly to the file in its original location.
  ENG-274 then sweeps the post-edit `defaults.sh` (with the new state
  already inside it) into `lib/`. Both issues are in the same scope,
  so the dispatcher's blocker chain handles ordering automatically.

No other prerequisites. The plugin's existing infrastructure
(`$CLAUDE_PLUGIN_ROOT` env var, bats test runner, source-pattern
conventions in skill markdown) is all in place.

## Out of scope

Explicitly excluded from this issue:

- **`worktree.sh` and `preflight_labels.sh`.** Each has a single
  in-plugin consumer. Lifting them would be speculative; the partition
  criterion is "move when sharing exists, not when sharing might
  hypothetically exist."
- **Renaming or refactoring any moved file's contents.** This issue
  moves files and updates source paths. It does not split functions
  across files, change function signatures, or rewrite implementations.
  Cleanup is filed separately if needed.
- **Historical specs** in `docs/specs/` and `docs/archive/decisions/`
  that mention the old paths (e.g., `ralph-scope-model-design.md`,
  `ralph-implement-skill-design.md`,
  `ralph-spec-sources-ralph-start-libs.md`). These are records of
  work-as-done at the time. Retroactive path-edits would falsify the
  record.
- **README.md and `docs/usage.md` narrative.** Neither references the
  moved paths in a way that needs updating.
- **`docs/specs/in-design-workflow-state.md`** (ENG-273 spec). Stays
  as-written. By the time ENG-274 dispatches, ENG-273 has landed and
  that spec is a historical record.
- **Adding new shared helpers, or extracting duplication between
  existing libs.** Out of scope; file separately if the implementer
  notices a candidate.
- **Changes to `userConfig`, `.ralph.json` schema, or any externally-
  visible contract.** This is a pure internal restructure.

## Alternatives considered

1. **Plugin-root `lib/` — chosen.** Top-level `lib/` is the conventional
   shell-project layout. Shortest source path
   (`$CLAUDE_PLUGIN_ROOT/lib/<file>.sh` — three components). Matches the
   intra-skill `scripts/lib/` pattern lifted to plugin scope. Tests
   co-located in `lib/test/` so `$SCRIPT_DIR` resolution in moved bats
   files keeps working with no edits inside the bats themselves.

2. **Plugin-root `scripts/lib/`.** Strict mirror of the intra-skill
   structure (`scripts/lib/` + `scripts/test/`). Rejected: the
   `scripts/` wrapper carries no content beyond `lib/` and `test/` —
   it doubles the noun ("scripts/library/") and adds two path
   components to every source line for no offsetting benefit. The
   intra-skill `scripts/` exists because ralph-start has entry-point
   scripts (`orchestrator.sh` etc.) to host alongside its libs; the
   plugin-root migration has only libs.

3. **`shared/` directory.** Names the cross-skill relationship
   explicitly. Rejected: `lib/` says both "category: shell library" and
   (via root position) "scope: plugin-wide", whereas `shared/` says
   only the relationship and is less conventional in shell ecosystems.
   Keeping the noun (`lib/`) consistent across plugin-wide and
   intra-skill scopes lets context do the disambiguation work.

4. **Split per concern (`config/`, `linear/`, `scope/`, `git/`).**
   Strongest semantic separation. Rejected: heavily over-engineered
   for four files. Four directories each holding one shell file plus
   one test carry no information that filenames don't already carry.
   Reconsider only if the lib count grows past 10–15 helpers.

5. **Leave the libs in place; document them as plugin-wide via header
   comments.** No file moves, just clarifying prose. Rejected: the
   issue body and `branch_ancestry.sh`'s own header already document
   the intent. The structural lie ("ralph-start owns these") is in the
   path itself; comments cannot override it. Documentation is not a
   substitute for accurate layout.

## Testing expectations

- **No new automated tests.** The move is a structural refactor with
  no behavior change. Each moved lib already has a `.bats` file; the
  existing tests validate the same code at the new location.
- **Tests that build stub directories must update their stub layouts**
  to mirror the new plugin root (per File-by-file changes section (d)).
  The bats suite passing in the new layout is itself the integration
  test.
- **TDD does not apply.** There is no production-code branch in the
  orchestrator scripts that changes here; the change is path-only.
- **Codex review at `/prepare-for-review`** catches drift on the
  markdown source-pattern updates (three SKILL.md files, multiple
  lines each) and on the four ralph-start internal scripts.

## Notes

- The libs declare their dependencies via runtime guards
  (`scope.sh`'s `_scope_load` checks for `linear_list_initiative_projects`
  being defined; `linear.sh` references `RALPH_PROJECTS` and
  `CLAUDE_PLUGIN_OPTION_*` at call time). These guards work the same
  regardless of file location — the move shouldn't affect source-order
  semantics. If the implementer notices a regression here, that's a
  signal to investigate, not paper over.
- `$CLAUDE_PLUGIN_ROOT` is exported by the Claude Code plugin harness
  whenever the plugin is enabled. The fallback walk-up from
  `$SCRIPT_DIR` exists for the bats-test invocation context, where
  the harness is not running.
- The autonomous implementer should run `bats` from repo root (not
  from `skills/ralph-start/scripts/`) so both test directories are
  discoverable. Verification step 6 explicitly invokes both.
- All consumer files reference the libs via `$CLAUDE_PLUGIN_ROOT/lib/...`
  or `$PLUGIN_ROOT/lib/...`. There are no relative-path references
  encoding the structural assumption "the libs live at this depth";
  every consumer either uses the harness env var or computes plugin
  root via `cd $SCRIPT_DIR/../../..`. That keeps the structure shallow
  to refactor again later if the plugin layout ever changes.
