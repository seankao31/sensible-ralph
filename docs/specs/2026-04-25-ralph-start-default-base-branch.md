# Make default base branch configurable via `.ralph.json`

**Status:** Approved (ENG-214)
**Project:** Sensible Ralph
**Date:** 2026-04-25

## Motivation

`scripts/dag_base.sh` hardcodes the literal string `"main"` as the base branch
when an Approved issue has no in-review parent in the queue:

```bash
if [[ $review_count -eq 0 ]]; then
  printf 'main\n'
```

This bakes a chezmoi-ism into ralph-v2. ENG-205 made the project scope
multi-project / per-repo via `.ralph.json`, so a project whose primary
trunk is `dev`, `master`, `release-YYYY`, or anything other than `main`
cannot use ralph as-is — `dag_base.sh` would tell `git worktree add` to
branch from a ref that doesn't exist locally, and the orchestrator's
`worktree_create_at_base` would fail with "base ref not found".

## Re-scoped from the original ticket

The original ENG-214 description proposed factoring branch and worktree
creation into a project-local `start-branch` skill, mirroring the
close-side split (ENG-213's `close-issue` + `close-branch`). The
brainstorming dialogue narrowed this:

- **Branch naming** is a plugin decision (always Linear's
  auto-generated `branchName`), not per-project.
- **Worktree path layout** is already configurable via the
  `$CLAUDE_PLUGIN_OPTION_WORKTREE_BASE` plugin option.
- **Worktree creation mechanics** (`git worktree add`, INTEGRATION
  merge sequence, single-parent-leaves-conflicts /
  multi-parent-fail-fast policy) are ralph-v2 invariants.
- **Linear interactions** (state transitions, blocker queries) belong
  in the orchestrator — start-branch should not touch Linear.
- **Initial post-create setup** (install deps, copy secrets, configure
  sparse checkout, etc.) is the only category with genuine project-local
  *logic*, but it is empty for sensible-ralph and chezmoi today, and
  Claude itself can do most of these inside the dispatched session.
  YAGNI: defer the skill until a real use case appears.

That leaves **default base branch resolution** as the single concern
that legitimately varies per-repo and cannot be plugin-decided. A single
string field in `.ralph.json` is sufficient — no skill, no new
composition mechanism.

## Design

### `.ralph.json` schema

Add an optional key `default_base_branch` (string). Example with the new
field set:

```jsonc
{
  "projects": ["My Project"],
  "default_base_branch": "dev"
}
```

When the key is absent, the default is `"main"` — preserving today's
behavior for every existing `.ralph.json`. The field is independent of
the existing `projects` / `initiative` shape: both shapes accept it.

### `scripts/lib/scope.sh` change

Inside `_scope_load_projects`, after the existing
`export RALPH_PROJECTS="$projects_newline"` line and before the
function's closing `}`, parse and export the new key:

```bash
local default_base dbb_type
dbb_type="$(jq -r 'if has("default_base_branch") then (.default_base_branch | type) else "absent" end' "$scope_file")"
if [[ "$dbb_type" == "absent" ]]; then
  default_base="main"
elif [[ "$dbb_type" == "string" ]]; then
  default_base="$(jq -r '.default_base_branch' "$scope_file")"
  if [[ -z "$default_base" ]]; then
    echo "scope: .ralph.json default_base_branch is empty — omit the key or set a non-empty string" >&2
    return 1
  fi
else
  echo "scope: .ralph.json default_base_branch must be a string, got $dbb_type" >&2
  return 1
fi
export RALPH_DEFAULT_BASE_BRANCH="$default_base"
```

Add `RALPH_DEFAULT_BASE_BRANCH` to the documented `Exports` list at
the top of the file.

The type-safe guard matches the fail-loud pattern everywhere in scope.sh:
absent key defaults to `"main"`, non-empty string is accepted, empty
string and all non-string JSON types (number, boolean, array, object)
are hard errors caught at load time — never at git-ref resolution time.

### `scripts/dag_base.sh` change

Replace the literal:

```bash
if [[ $review_count -eq 0 ]]; then
  printf 'main\n'
```

with:

```bash
if [[ $review_count -eq 0 ]]; then
  printf '%s\n' "$RALPH_DEFAULT_BASE_BRANCH"
```

`dag_base.sh` already sources `scope.sh` at the top of the file via
the conditional `RALPH_SCOPE_LOADED` marker block (the same gated
re-source pattern `orchestrator.sh` uses), so the env var is in scope
by the time the no-parent branch is reached.

Also update the file header comment:

```
# Output: "main" | "<branch>" | "INTEGRATION <branch1> <branch2> ..."
```

becomes:

```
# Output: "<RALPH_DEFAULT_BASE_BRANCH>" | "<branch>" | "INTEGRATION <branch1> <branch2> ..."
```

### `scripts/lib/worktree.sh` change

`worktree_create_with_integration` creates the integration worktree from
the literal ref `main`:

```bash
git worktree add "$path" -b "$branch" main
```

Replace with:

```bash
git worktree add "$path" -b "$branch" "${RALPH_DEFAULT_BASE_BRANCH}"
```

`RALPH_DEFAULT_BASE_BRANCH` is available because `scope.sh` is always
sourced before `worktree.sh` is used (both `orchestrator.sh` and
`dag_base.sh` source scope at the top via the conditional
`RALPH_SCOPE_LOADED` marker block). Also update the function's leading
comment to note this env-var dependency.

### `scripts/orchestrator.sh` change

In the INTEGRATION path of `_dispatch_issue`, the pre-merge `base_sha`
capture hardcodes the trunk ref:

```bash
# Capture main's SHA BEFORE any parent merges …
base_sha="$(git rev-parse main)"
```

Replace `main` with the configured trunk:

```bash
# Capture trunk SHA BEFORE any parent merges — that's the branch's true
# creation point for prepare-for-review diff scoping.
base_sha="$(git rev-parse "${RALPH_DEFAULT_BASE_BRANCH}")"
```

Update the surrounding comment to say "trunk" (or "default base branch")
instead of the literal word "main".

### `skills/ralph-start/SKILL.md` change

Update the "Scope resolution" section to document the new field. Add a
short subsection after the two-shape jsonc example:

```markdown
**Default base branch.** An optional `default_base_branch` field
(string) sets the branch ralph branches from when an Approved issue
has no in-review parent in the queue. Defaults to `"main"` if absent.
Example: `{ "projects": [...], "default_base_branch": "dev" }`.
```

### Tests

**`scripts/test/scope.bats`** — add five `@test` blocks following the
existing fake-repo-root pattern (`setup` / `teardown` / `source_scope`
helper in the file):

1. **`default_base_branch absent → RALPH_DEFAULT_BASE_BRANCH=main`** —
   write `.ralph.json` without the field, source scope, assert
   `RALPH_DEFAULT_BASE_BRANCH=main` in the captured exports.
2. **`default_base_branch set → exports the configured value`** — write
   `.ralph.json` with `"default_base_branch": "dev"`, assert
   `RALPH_DEFAULT_BASE_BRANCH=dev` in the captured exports.
3. **`default_base_branch empty string → hard error`** — write
   `.ralph.json` with `"default_base_branch": ""`, assert exit 1 and
   error message contains `default_base_branch`.
4. **`default_base_branch non-string number → hard error`** — write
   `.ralph.json` with `"default_base_branch": 123`, assert exit 1 and
   error message contains `default_base_branch`.
5. **`default_base_branch non-string boolean → hard error`** — write
   `.ralph.json` with `"default_base_branch": false`, assert exit 1 and
   error message contains `default_base_branch`.

**`scripts/test/worktree.bats`** — add one `@test` block:

6. **`worktree_create_with_integration uses RALPH_DEFAULT_BASE_BRANCH`**
   — set `RALPH_DEFAULT_BASE_BRANCH=dev`, stub or confirm `git worktree
   add` is called with `dev` as the base (not `main`). The existing
   worktree tests use a real temp git repo; add a `dev` branch in setup
   and pass it as `RALPH_DEFAULT_BASE_BRANCH` to confirm the ref
   resolves without error.

`dag_base.bats` does not need new cases — its existing no-parent test
will continue to pass (the default `main` matches the prior literal
when `RALPH_DEFAULT_BASE_BRANCH` is absent or `main`).

## Failure mode at the seam

If a future caller manages to invoke `dag_base.sh` or
`worktree_create_with_integration` without first sourcing `scope.sh`
(so `RALPH_DEFAULT_BASE_BRANCH` is unset):

- `dag_base.sh`: `printf '%s\n' "$RALPH_DEFAULT_BASE_BRANCH"` emits an
  empty line. The orchestrator's existing dag_base output validation
  (the `if [[ -z "${base_out//[[:space:]]/}" ]]` block in
  `_dispatch_issue` that emits `dag_base_empty` as the failed step)
  catches this and records `setup_failed`. No additional guard needed.
- `worktree_create_with_integration`: `git worktree add "$path" -b
  "$branch" ""` — git will reject the empty ref with a clear error,
  which propagates as a non-zero return from
  `worktree_create_with_integration`, triggering `_cleanup_worktree`
  and `setup_failed` in the orchestrator's error path. No additional
  guard needed.
- `git rev-parse ""` in the INTEGRATION `base_sha` block — also fails
  non-zero, hitting the same `setup_failed` path.

All three unset-env cases are caught before any Linear mutation.

## Documentation updates

- `skills/ralph-start/SKILL.md` — Scope resolution section (above).
- `scripts/dag_base.sh` — header comment (above).
- `scripts/lib/scope.sh` — Exports list at the top.
- `README.md` and `docs/usage.md` — check whether either references the
  hardcoded `main` and update if so. (Quick `grep -nE 'base.*main|main.*base'`
  during implementation will find any references.)

## Linear issue retitle

Retitle ENG-214 from `ralph-start: factor branch/worktree creation into
project-local start-branch` to `ralph-start: make default base branch
configurable via .ralph.json` so the issue title matches the re-scoped
work. The original framing (factor into start-branch) is preserved in
this spec's "Re-scoped from the original ticket" section above for
audit trail.

## Out of scope (explicit deferrals)

- **A `start-branch` skill of any shape.** Defer until a project has a
  real post-create requirement (sparse checkout config, secret copying,
  pre-warming caches that the dispatched Claude session shouldn't have
  to repeat). At that point a follow-up ticket can add the skill with
  a single justified responsibility — invocation point post-create,
  pre-Linear-state, exit non-zero triggers `setup_failed` cleanup.
- **Per-issue base override.** A label or comment on a Linear issue
  saying "branch from `release-2025` for this one" is conceivable but
  has no demand today. The DAG-driven base resolution
  (parent-branch / INTEGRATION) plus the per-repo
  `default_base_branch` covers every observed use case.
- **Auto-detect the repo's default branch from `git remote show origin`
  HEAD.** Explicit config is more predictable; auto-detection adds
  magic that the operator still has to override per-project, so it
  doesn't reduce config burden.
- **Per-project (within a multi-project repo) base overrides.** A
  `.ralph.json` with `"projects": ["A", "B"]` could in principle want
  different bases per project, but there is no observed need and
  per-repo is enough.

## Alternatives considered

**Plugin userConfig key (`$CLAUDE_PLUGIN_OPTION_DEFAULT_BASE_BRANCH`)
instead of `.ralph.json` field.** Rejected: userConfig is per-user,
shared across all repos the user works in. Default base is per-repo —
chezmoi could use `main` while another repo uses `dev` for the same
operator. The field belongs with the rest of the per-repo scope config.

**Symbolic placeholder (`dag_base.sh` keeps emitting literal `"main"`,
a translator step downstream substitutes).** Rejected: adds a moving
part with no benefit. The translator would just be a string lookup,
which `dag_base.sh` can do directly by reading the env var.

**Full project-local `start-branch` skill as the original ticket
proposed.** Rejected — see "Re-scoped from the original ticket" above.
The single per-project concern (default base) is config, not logic.
A skill with no logic is over-engineering. Ship the smaller change now;
add the skill if and when a project actually needs post-create logic.
