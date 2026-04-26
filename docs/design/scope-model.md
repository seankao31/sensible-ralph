# Scope model

Per-repo scope (`<repo-root>/.sensible-ralph.json`) declares which Linear
projects this repo's `/sr-start` sessions drain. The orchestrator
reads scope before every dispatch to bound queue construction,
blocker resolution, and out-of-scope preflight checks.

## Problem

A single hardcoded `project` field bakes in a single-scope assumption that doesn't match real workflows:

1. **One repo, multiple projects.** A consumer repo may host more than one Linear project — say `Project A` and `Project B`. Single-project scope can only drain one of them per run; operators would have to hand-edit config and re-run to cover the other.
2. **Concurrent sessions across repos.** Running `/sr-start` in one repo while another session runs in a different repo should not produce collisions on `progress.json`, `ordered_queue.txt`, or worktree paths.
3. **Auto-detect scope from cwd.** Invoking `/sr-start` from a repo should resolve its scope from the repo itself, not from a hand-maintained global setting that drifts with "which repo am I standing in."

## Non-goals (YAGNI)

Explicit exclusions, each with rationale so future-us doesn't re-open them without reason:

- **Out-of-repo invocation.** A "catch-all" session run from a neutral location not tied to any repo. Speculative (`"I might want…"` in the source ticket) with no concrete driver; designing for it now biases the first implementation toward abstractions that don't earn their complexity. `/sr-start` is always invoked from inside a repo.
- **Initiative-level catch-all across all projects the operator owns.** Same reason.
- **Concurrent ralph runs in the same repo.** Not a workflow in current use; adding lockfiles or run-keyed state files is pure cost. The obvious extension (`<repo>/.sensible-ralph.lock` at dispatch start) is available if the need appears.
- **Union semantics for `projects` + `initiative` in the same config.** Creates a surprising interaction: if the initiative gains a project later, the effective scope changes silently. Explicit-either-or keeps scope diffable in the config file.
- **Cross-workspace (different Linear workspaces) scope.** No current driver; workspace identity is still assumed singular.

## Design Decisions

### 1. Scope is a project list; `initiative` is sugar that expands to one

A **scope** is the set of Linear projects that one `/sr-start` invocation drains. The repo's `.sensible-ralph.json` expresses scope in one of two shapes, both of which resolve to a project list at load time:

```jsonc
// Explicit: project list
{
  "projects": ["Project A", "Project B"]
}

// Shorthand: initiative name, auto-expanded to its member projects
{
  "initiative": "AI Collaboration Toolkit"
}
```

**Rationale for projects-over-initiatives as the primary unit:**

Initiatives group by conceptual theme; repos contain projects. An initiative can contain projects belonging to different repos — setting one repo's scope to a cross-repo initiative would pull another repo's issues into this repo's ralph queue, which the orchestrator would then try to dispatch as worktrees inside the wrong repo. That is wrong. Initiatives trend toward becoming multi-repo as they grow; projects stay 1:1 with repos. The project list is the unit that aligns with "which issues should produce worktrees in *this* repo."

**Why keep `initiative` at all:**

For the case where an initiative's project membership genuinely matches a single repo's scope, the shorthand avoids the maintenance burden of hand-updating `projects` when the initiative gains a new project. It's a convenience layer on top of the same underlying project-list model — the orchestrator's downstream logic only sees the resolved list.

**Resolution rules:**

- `projects` present → used directly.
- `initiative` present → expanded via `linear api` GraphQL (the CLI's `linear issue query` has no `--initiative` filter) to the list of member projects. Expansion runs each time `scope.sh` is sourced — see Decision 3 for the caching semantics, and Open Questions for the known staleness window.
- Both fields present → hard error. The author must pick one expression.
- Neither field present, or resolution yields an empty project list → hard error.

### 2. Config splits into per-repo scope and global workflow

Two files:

- **Per-repo: `<repo-root>/.sensible-ralph.json`** (committed to each target repo). Contains *only* scope — a `projects` list or an `initiative` name.
- **Global: plugin `userConfig`** (declared in `.claude-plugin/plugin.json`, exported by the Claude Code harness as `CLAUDE_PLUGIN_OPTION_*` env vars; shell-side defaults in `lib/defaults.sh`). Keeps all workspace-wide workflow fields: state names, labels, `worktree_base`, `model`, `stdout_log_filename`. There is no `SENSIBLE_RALPH_PROJECT` env var; project scope is the per-repo concern.

**Rationale:**

- Scope is a repo fact; workflow is a workspace fact. Splitting matches reality — "which issues should ralph drain here?" is local to the repo; "what does *Approved* mean in Linear?" is global to the ENG team.
- `.sensible-ralph.json` committed at the repo root means the scope travels with the repo. Cloning any repo that adopts ralph on a new machine works with no central-registry setup.
- Auto-detection is trivial: `git rev-parse --show-toplevel` + read `<root>/.sensible-ralph.json`. No path-keyed central file. (Using `--show-toplevel` instead of `--git-common-dir` so each worktree reads its own committed `.sensible-ralph.json` — a branch that edits scope must see its own change, not the main checkout's stale copy. This differs from `progress.json`, which intentionally uses `--git-common-dir` for cross-worktree sharing.)
- Duplicating workflow fields across every repo (the alternative of a per-repo file that holds both scope and workflow) would create drift surface every time a convention changes — e.g. renaming the `ralph-failed` label would touch every repo's config.

**File-name rationale:** `.sensible-ralph.json` matches the `.eslintrc.json` / `.prettierrc.json` dotfile-config convention; the file is set-once-per-repo so discoverability matters less than unobtrusiveness. Namespace collision with other `ralph`-named tools (Geoffrey Huntley's loop pattern has the same name but no on-disk artifacts) is a known minor risk; renaming can happen later if it bites.

### 3. Scope loading exports a content-hashed bleed-through guard

`lib/scope.sh` parses `<repo>/.sensible-ralph.json`, validates it, and exports two
things:

```
SENSIBLE_RALPH_PROJECTS      = newline-joined list of in-scope project names
SENSIBLE_RALPH_SCOPE_LOADED  = "<repo-root-abs-path>|<sha1-of-sensible-ralph.json>"
```

Entry-point scripts compute their own expected `SENSIBLE_RALPH_SCOPE_LOADED` and
re-source `scope.sh` when the marker differs. The content hash catches
in-place edits (and branch switches in the same worktree that change
scope) — without it, the gate would match path-wise and skip re-loading
across a scope change, leaving stale `SENSIBLE_RALPH_PROJECTS` in the shell.

Workflow config (state names, labels, `worktree_base`, etc.) is exported
separately by the plugin harness as `CLAUDE_PLUGIN_OPTION_*` env vars
and is unaffected by scope reloading.

Loading order:

1. Resolve working-tree root via `git rev-parse --show-toplevel` (see Decision 2 rationale for the `--show-toplevel` vs `--git-common-dir` distinction).
2. Source `lib/linear.sh` first (it defines `linear_list_initiative_projects`, which the `.sensible-ralph.json` `initiative` shape calls). `lib/scope.sh` asserts that function is defined at load time and fails loudly otherwise — without the guard, the initiative path would emit a late "command not found" that's harder to trace.
3. Source `lib/scope.sh` → resolves scope (expanding `initiative` via Linear if present) → exports `SENSIBLE_RALPH_PROJECTS` as a newline-joined string. The newline-joined pattern matches existing bash 3.2 conventions in the scripts; a real array isn't portable across `source` boundaries on macOS's default bash.
4. Set `SENSIBLE_RALPH_SCOPE_LOADED` to the tuple `"<repo-root>|<sha1-of-sensible-ralph.json>"`.

The sha1 component catches in-place scope edits (e.g., branch switches in the same worktree).

**Caching profile for initiative scope:** each entry-point subprocess started from the user's shell sources `scope.sh` fresh (the user's shell does not propagate `SENSIBLE_RALPH_SCOPE_LOADED` back from children), so `preflight_scan.sh`, `build_queue.sh`, every preview-phase `dag_base.sh`, and `orchestrator.sh` each trigger one `linear_list_initiative_projects` call. Within a single subprocess chain — `orchestrator.sh` and the `dag_base.sh` subprocesses it spawns per issue — `SENSIBLE_RALPH_SCOPE_LOADED` is inherited and the gate skips re-source, so the orchestrator's in-flight run uses the project list captured at its startup. The staleness implication: if Linear initiative membership changes mid-orchestration, the running orchestrator does not pick it up until the next `/sr-start`. Accepted as a known limitation — see Open Questions.

**Validation at load (all hard errors — no silent fallbacks):**

- `.sensible-ralph.json` missing → fail with a message pointing at the expected file and example contents. Silent defaults would reintroduce the "I didn't notice I was in the wrong repo" bug that auto-detection exists to prevent.
- Both `projects` and `initiative` set → fail.
- `projects` empty, or `initiative` resolves to zero projects → fail.
- Project names that don't exist in Linear → deferred to query time. The CLI emits a clear error on unknown projects; adding a pre-validation round-trip doesn't earn its latency.

### 4. Query and preflight layer absorb the project-list dimension; downstream is untouched

The project/scope dimension is localized to two places: config loading (Decision 3) and the Linear query + chain-runnability layer (this decision). Everything further downstream — toposort, DAG base selection, worktree creation, dispatch, outcome classification, progress tracking — operates on branch names and DAG edges and is unaffected.

**Approved-issue listing (`linear_list_approved_issues` in `lib/linear.sh`):**

Today one `linear issue query --project "$SENSIBLE_RALPH_PROJECT"` call. New: one call per project in `SENSIBLE_RALPH_PROJECTS`; results concatenated, then the existing state-name + no-failed-label filters apply to the union. Preserved over a raw-GraphQL one-shot query (which would require hand-rolled filters matching the CLI's output shape) for consistency with the existing layer.

**Blocker resolution (`linear_get_issue_blockers`):**

Already returns all blockers regardless of project membership (via GraphQL `inverseRelations`). No change to routing logic; the implementation must extend the `inverseRelations` fields to include `project { id name }` per blocker so the out-of-scope-blocker anomaly path can name the project in its error message.

**Chain runnability (`preflight_scan.sh::_chain_runnable`, `build_queue.sh`):**

Today: an `Approved` blocker is runnable only if its ID is in this run's approved set. Cross-project Approved blockers fail this check and the issue is reported stuck.

New: the membership check widens. An `Approved` blocker is runnable if it is in the approved set (which now spans `SENSIBLE_RALPH_PROJECTS`). A blocker whose project is *outside* the scope remains stuck; the error message changes from "blocker not in this project" to "blocker in project `<name>`, outside this run's scope — add to `.sensible-ralph.json` or resolve the relationship."

**Preflight anomaly set — one new entry:**

- Canceled / Duplicate blocker — unchanged.
- Deep-stuck dependency chain — unchanged.
- Missing PRD on an Approved issue — unchanged (applies to every issue in the union).
- **Out-of-scope blocker (new).** Distinguished from canceled/duplicate because the fix is different — operator adds the blocker's project to `.sensible-ralph.json`, or explicitly cancels / rescopes the relationship.

**Toposort:** unchanged. Operates on issue IDs and `blocked-by` edges only.

**DAG base selection:** unchanged. Works on branch names and blocker states. A Machine Config parent in `In Review` supplies its branch as the base for an Agent Config child, the same as within-project today.

### 5. Concurrent cross-repo sessions are safe by construction

A natural question: should `progress.json` become `progress-<run_id>.json` or move to a scope-keyed state directory to avoid cross-repo collisions? Neither is necessary:

| Resource | Location | Why two-repo concurrency is safe |
|---|---|---|
| `progress.json` | Orchestrator cwd, anchored to repo root by `_resolve_repo_root` | Two repos → two different parents → disjoint files |
| `ordered_queue.txt` | Caller's cwd (currently not anchored via `_resolve_repo_root`; the implementation should anchor it to the repo root for consistency with `progress.json`) | Two repos → disjoint files when each session is invoked from its repo root |
| `.worktrees/<branch>` | `<repo>/.worktrees/<branch>` via `worktree_path_for_issue` | Two repos → disjoint trees |
| Linear state writes | Keyed by issue ID (unique workspace-wide) | No collision by construction |
| Branch names | Linear's `<team>-<id>-<slug>` — globally unique | No collision |

The design's concurrency guarantee stops at the cross-repo boundary. Same-repo concurrency (two `/sr-start` sessions in the same working tree) is an explicit non-goal.

## Contract summary

What changes for callers and operators:

- **Workflow config** comes from the plugin's `userConfig` exported as `CLAUDE_PLUGIN_OPTION_*` env vars. There is no global `config.json` and no `SENSIBLE_RALPH_PROJECT` env var. The required-keys list in SKILL.md's Prerequisites section follows that shape.
- **Each ralph-hosting repo** has a committed `<repo-root>/.sensible-ralph.json` with either `projects: [...]` or `initiative: "..."`.
- **`linear_list_approved_issues`, `preflight_scan.sh`, `build_queue.sh`** exported surface is unchanged — callers still consume an issue-ID list. Internal query shape changes.
- **`SENSIBLE_RALPH_PROJECTS`** is the exported scope env var (newline-joined project names). There is no `SENSIBLE_RALPH_PROJECT`.
- **`SENSIBLE_RALPH_SCOPE_LOADED`** is the tuple `"<repo-root>|<sha1-of-sensible-ralph.json>"` — the per-repo bleed-through guard. (No `SENSIBLE_RALPH_CONFIG_LOADED`; workflow config comes from the plugin harness, not a sourced shell file.)

Nothing else changes. The state machine, the pickup rule, the pre-flight anomaly policy, the outcome model, the orchestrator's DAG handling, `/prepare-for-review`, and `/close-feature-branch` are all untouched.

## Code-change surface

| File | What changed |
|---|---|
| `lib/scope.sh` (new) | Scope loader: parses `.sensible-ralph.json`, exports `SENSIBLE_RALPH_PROJECTS` + `SENSIBLE_RALPH_SCOPE_LOADED` |
| `lib/defaults.sh` (new) | Workflow defaults for `CLAUDE_PLUGIN_OPTION_*` env vars (replaces old `config.sh`/`config.json`) |
| `lib/linear.sh` | `linear_list_approved_issues` unions over `SENSIBLE_RALPH_PROJECTS`; `linear_list_initiative_projects` expands initiative shorthand |
| `skills/sr-start/scripts/preflight_scan.sh` | Updated `_chain_runnable`; out-of-scope-blocker anomaly added |
| `skills/sr-start/scripts/build_queue.sh` | Matches updated `_chain_runnable` semantics |
| `skills/sr-start/SKILL.md` | Prerequisites: `.sensible-ralph.json` replaces `project`; scope-resolution section added |
| `docs/usage.md` | Operator flow updated for scope model |
| `docs/design/scope-model.md` (this file, moved from `docs/specs/`) | Migrated from frozen spec to living design doc |
| `<consumer-repo>/.sensible-ralph.json` (new per repo) | `{ "projects": [...] }` or `{ "initiative": "..." }` |
| `skills/sr-start/test/…` | Tests for scope resolution and multi-project queue building |

## Open questions

1. **Pre-validation of `projects` against Linear at load time.** Would catch unknown project names earlier but adds a round-trip to every invocation. Current plan: skip; the existing "query fails cleanly on unknown project" path is sufficient. Revisit if the early failure proves too cryptic in practice.

2. **Initiative expansion freshness inside an orchestrator run.** As described in Decision 3, the reload gate lets `orchestrator.sh` and its per-issue `dag_base.sh` subprocesses share the initiative expansion captured at orchestrator startup — a Linear membership change during the run is invisible until the next `/sr-start`. Accepted for now: mid-orchestration membership changes are rare; forcing re-expansion on every inherited subprocess would roughly double the initiative API traffic (from `N+3` calls per session to `2N+3`) for a scenario nobody has observed. If this staleness ever bites, the cheap fix is to unset `SENSIBLE_RALPH_SCOPE_LOADED` in `scope.sh` on the initiative path so every subprocess re-expands.

3. **Alternate file format (TOML / YAML) for `.sensible-ralph.json`.** JSON matches the existing `config.json` and `jq` tooling, and scope is a tiny data shape. If the file grows hard-to-edit fields later, reconsider.
