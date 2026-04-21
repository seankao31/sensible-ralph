# Ralph Scope Model: Multi-Project Dispatch with Per-Repo Scope Config

**Linear issue:** ENG-205
**Date:** 2026-04-21
**Extends:** `2026-04-17-ralph-loop-v2-design.md` (ENG-176)
**Subsumes:** ENG-203 (cross-project blockers within an initiative)

## Problem

`agent-config/skills/ralph-start/config.json` hardcodes a single `project` field. This bakes in a single-scope assumption that doesn't match real workflows:

1. **One repo, multiple projects.** The chezmoi repo hosts two Linear projects — `Agent Config` (changes under `agent-config/`) and `Machine Config` (chezmoi plumbing and machine-level dotfiles). Today ralph can only drain one of them per run; operators must hand-edit `config.json` and re-run to cover the other.
2. **Concurrent sessions across repos.** Running `/ralph-start` in chezmoi while another session runs in a different repo should not produce collisions on `progress.json`, `ordered_queue.txt`, or worktree paths.
3. **Auto-detect scope from cwd.** Invoking `/ralph-start` from a repo should resolve its scope from the repo itself, not from a hand-maintained global setting that drifts with "which repo am I standing in."

The v2 spec (Contract Summary, Decision 7) already flagged single-project scope as a v2 constraint. ENG-203 attempted a narrower slice — cross-project blockers within one initiative — which this design subsumes.

## Non-goals (YAGNI)

Explicit exclusions, each with rationale so future-us doesn't re-open them without reason:

- **Out-of-repo invocation.** A "catch-all" session run from a neutral location not tied to any repo. Speculative (`"I might want…"` in the source ticket) with no concrete driver; designing for it now biases the first implementation toward abstractions that don't earn their complexity. `/ralph-start` is always invoked from inside a repo.
- **Initiative-level catch-all across all projects the operator owns.** Same reason.
- **Concurrent ralph runs in the same repo.** Not a workflow in current use; adding lockfiles or run-keyed state files is pure cost. The obvious extension (`<repo>/.ralph.lock` at dispatch start) is available if the need appears.
- **Union semantics for `projects` + `initiative` in the same config.** Creates a surprising interaction: if the initiative gains a project later, the effective scope changes silently. Explicit-either-or keeps scope diffable in the config file.
- **Cross-workspace (different Linear workspaces) scope.** No current driver; workspace identity is still assumed singular.

## Design Decisions

### 1. Scope is a project list; `initiative` is sugar that expands to one

A **scope** is the set of Linear projects that one `/ralph-start` invocation drains. The repo's `.ralph.json` expresses scope in one of two shapes, both of which resolve to a project list at load time:

```jsonc
// Explicit: project list
{
  "projects": ["Agent Config", "Machine Config"]
}

// Shorthand: initiative name, auto-expanded to its member projects
{
  "initiative": "AI Collaboration Toolkit"
}
```

**Rationale for projects-over-initiatives as the primary unit:**

Initiatives group by conceptual theme; repos contain projects. In the current Linear workspace, the `AI Collaboration Toolkit` initiative contains two projects (`I Said Yes` and `Agent Config`) that belong to two different repos — setting the chezmoi repo's scope to that initiative would pull `I Said Yes` issues into chezmoi's ralph queue, which the orchestrator would then try to dispatch as worktrees inside chezmoi. That is wrong. Initiatives trend toward becoming multi-repo as they grow; projects stay 1:1 with repos. The project list is the unit that aligns with "which issues should produce worktrees in *this* repo."

**Why keep `initiative` at all:**

For the case where an initiative's project membership genuinely matches a single repo's scope, the shorthand avoids the maintenance burden of hand-updating `projects` when the initiative gains a new project. It's a convenience layer on top of the same underlying project-list model — the orchestrator's downstream logic only sees the resolved list.

**Resolution rules:**

- `projects` present → used directly.
- `initiative` present → expanded via `linear api` GraphQL (the CLI's `linear issue query` has no `--initiative` filter) to the list of member projects. Fresh lookup each invocation; no caching (see Open Questions).
- Both fields present → hard error. The author must pick one expression.
- Neither field present, or resolution yields an empty project list → hard error.

### 2. Config splits into per-repo scope and global workflow

Two files:

- **Per-repo: `<repo-root>/.ralph.json`** (committed to each target repo). Contains *only* scope — a `projects` list or an `initiative` name.
- **Global: `agent-config/skills/ralph-start/config.json`** (current location, unchanged). Keeps all workspace-wide workflow fields: state names, labels, `worktree_base`, `model`, `stdout_log_filename`, `prompt_template`. The `project` key is removed.

**Rationale:**

- Scope is a repo fact; workflow is a workspace fact. Splitting matches reality — "which issues should ralph drain here?" is local to the repo; "what does *Approved* mean in Linear?" is global to the ENG team.
- `.ralph.json` committed at the repo root means the scope travels with the repo. Cloning chezmoi on a new machine — or cloning any repo that adopts ralph — works with no central-registry setup.
- Auto-detection is trivial: `_resolve_repo_root` (existing, worktree-safe via `--git-common-dir`, per ENG-202) + read `<root>/.ralph.json`. No path-keyed central file.
- Duplicating workflow fields across every repo (the alternative of a per-repo file that holds both scope and workflow) would create drift surface every time a convention changes — e.g. renaming the `ralph-failed` label would touch every repo's config.

**File-name rationale:** `.ralph.json` matches the `.eslintrc.json` / `.prettierrc.json` dotfile-config convention; the file is set-once-per-repo so discoverability matters less than unobtrusiveness. Namespace collision with other `ralph`-named tools (Geoffrey Huntley's loop pattern has the same name but no on-disk artifacts) is a known minor risk; renaming can happen later if it bites.

### 3. Config loading extends the existing anti-bleed-through guard

Today, `lib/config.sh` exports `RALPH_CONFIG_LOADED=<global-config-path>` to let entry-point scripts detect a stale prior-shell invocation and re-source. With scope now living in the repo, the guard extends to a tuple:

```
RALPH_CONFIG_LOADED = "<global-config-abs-path>|<repo-root-abs-path>"
```

Loading order:

1. Resolve repo root via `_resolve_repo_root`.
2. Load global `config.json` → exports workflow-level `RALPH_*` minus `RALPH_PROJECT`.
3. Load `<repo>/.ralph.json` → resolves scope (expanding `initiative` via Linear if present) → exports `RALPH_PROJECTS` as a newline-joined string. The newline-joined pattern matches existing bash 3.2 conventions in the scripts; a real array isn't portable across `source` boundaries on macOS's default bash.
4. Update `RALPH_CONFIG_LOADED` with the tuple.

Entry-point scripts (`ralph-start/SKILL.md` step invocations) re-source when either component of the tuple differs from their target. This is the only mechanical change to the existing anti-bleed-through logic.

**Validation at load (all hard errors — no silent fallbacks):**

- `.ralph.json` missing → fail with a message pointing at the expected file and example contents. Silent defaults would reintroduce the "I didn't notice I was in the wrong repo" bug that auto-detection exists to prevent.
- Both `projects` and `initiative` set → fail.
- `projects` empty, or `initiative` resolves to zero projects → fail.
- Project names that don't exist in Linear → deferred to query time. The CLI emits a clear error on unknown projects; adding a pre-validation round-trip doesn't earn its latency.

### 4. Query and preflight layer absorb the project-list dimension; downstream is untouched

The project/scope dimension is localized to two places: config loading (Decision 3) and the Linear query + chain-runnability layer (this decision). Everything further downstream — toposort, DAG base selection, worktree creation, dispatch, outcome classification, progress tracking — operates on branch names and DAG edges and is unaffected.

**Approved-issue listing (`linear_list_approved_issues` in `lib/linear.sh`):**

Today one `linear issue query --project "$RALPH_PROJECT"` call. New: one call per project in `RALPH_PROJECTS`; results concatenated, then the existing state-name + no-failed-label filters apply to the union. Preserved over a raw-GraphQL one-shot query (which would require hand-rolled filters matching the CLI's output shape) for consistency with the existing layer.

**Blocker resolution (`linear_get_issue_blockers`):**

Already returns all blockers regardless of project membership (via GraphQL `inverseRelations`). No change to routing logic; ENG-215 must extend the `inverseRelations` fields to include `project { id name }` per blocker so the out-of-scope-blocker anomaly path can name the project in its error message.

**Chain runnability (`preflight_scan.sh::_chain_runnable`, `build_queue.sh`):**

Today: an `Approved` blocker is runnable only if its ID is in this run's approved set. Cross-project Approved blockers fail this check and the issue is reported stuck — the ENG-203 pain point.

New: the membership check widens. An `Approved` blocker is runnable if it is in the approved set (which now spans `RALPH_PROJECTS`). A blocker whose project is *outside* the scope remains stuck; the error message changes from "blocker not in this project" to "blocker in project `<name>`, outside this run's scope — add to `.ralph.json` or resolve the relationship."

**Preflight anomaly set — one new entry:**

- Canceled / Duplicate blocker — unchanged.
- Deep-stuck dependency chain — unchanged.
- Missing PRD on an Approved issue — unchanged (applies to every issue in the union).
- **Out-of-scope blocker (new).** Distinguished from canceled/duplicate because the fix is different — operator adds the blocker's project to `.ralph.json`, or explicitly cancels / rescopes the relationship.

**Toposort:** unchanged. Operates on issue IDs and `blocked-by` edges only.

**DAG base selection:** unchanged. Works on branch names and blocker states. A Machine Config parent in `In Review` supplies its branch as the base for an Agent Config child, the same as within-project today.

### 5. Concurrent cross-repo sessions are safe by construction

ENG-205 asks whether `progress.json` should become `progress-<run_id>.json` or move to a scope-keyed state directory. Neither is necessary:

| Resource | Location | Why two-repo concurrency is safe |
|---|---|---|
| `progress.json` | Orchestrator cwd, anchored to repo root by `_resolve_repo_root` (ENG-202) | Two repos → two different parents → disjoint files |
| `ordered_queue.txt` | Caller's cwd (currently not anchored via `_resolve_repo_root`; ENG-215 should anchor it to the repo root for consistency with `progress.json`) | Two repos → disjoint files when each session is invoked from its repo root |
| `.worktrees/<branch>` | `<repo>/.worktrees/<branch>` via `worktree_path_for_issue` | Two repos → disjoint trees |
| Linear state writes | Keyed by issue ID (unique workspace-wide) | No collision by construction |
| Branch names | Linear's `<team>-<id>-<slug>` — globally unique | No collision |

The design's concurrency guarantee stops at the cross-repo boundary. Same-repo concurrency (two `/ralph-start` sessions in the same working tree) is an explicit non-goal.

## Contract summary

What changes for callers and operators:

- **Global `config.json`** no longer contains a `project` key. The required-keys list in SKILL.md's Prerequisites section updates accordingly.
- **Each ralph-hosting repo** has a committed `<repo-root>/.ralph.json` with either `projects: [...]` or `initiative: "..."`.
- **`linear_list_approved_issues`, `preflight_scan.sh`, `build_queue.sh`** exported surface is unchanged — callers still consume an issue-ID list. Internal query shape changes.
- **`RALPH_PROJECTS`** replaces `RALPH_PROJECT` in the exported env-var set.
- **`RALPH_CONFIG_LOADED`** becomes a tuple `"<global>|<repo-root>"`.

Nothing else in the v2 contract changes. The state machine, the pickup rule, the pre-flight anomaly policy, the outcome model, the orchestrator's DAG handling, `/prepare-for-review`, and `/close-feature-branch` are all untouched.

## Code-change surface (roadmap, not implementation plan)

| File | Change |
|---|---|
| `agent-config/skills/ralph-start/config.json` | Remove `project` field |
| `agent-config/skills/ralph-start/config.example.json` | Same |
| `agent-config/skills/ralph-start/scripts/lib/config.sh` | Drop `RALPH_PROJECT`; add `.ralph.json` loader with scope resolution; export `RALPH_PROJECTS`; extend `RALPH_CONFIG_LOADED` tuple |
| `agent-config/skills/ralph-start/scripts/lib/linear.sh` | `linear_list_approved_issues` unions over `RALPH_PROJECTS`; new helper `linear_list_initiative_projects` (GraphQL via `linear api`) for `initiative` expansion |
| `agent-config/skills/ralph-start/scripts/preflight_scan.sh` | Update `_chain_runnable`; add out-of-scope-blocker anomaly |
| `agent-config/skills/ralph-start/scripts/build_queue.sh` | Match new `_chain_runnable` semantics |
| `agent-config/skills/ralph-start/SKILL.md` | Prerequisites: drop `project`, add `.ralph.json`; new section on scope resolution |
| `agent-config/docs/playbooks/ralph-v2-usage.md` | Revise "When to run" and the single-project scope language |
| `agent-config/docs/specs/2026-04-17-ralph-loop-v2-design.md` | Contract-summary note about v2 single-project limit updated to reference this design |
| `.ralph.json` at chezmoi repo root (new) | `{ "projects": ["Agent Config", "Machine Config"] }` |
| `agent-config/skills/ralph-start/test/…` | Existing tests updated; new tests for scope resolution and multi-project queue building |

## Coexistence with in-flight work

**ENG-206 (In Progress)** — replaces `prompt_template` in `config.json` with a dedicated prompt file or dispatched skill. Orthogonal to this design (does not touch `project`), but both rewrite `config.json` / `lib/config.sh`. Sequence via explicit `blocked-by: ENG-206` on this design's implementation ticket so the DAG order is visible to ralph itself.

**ENG-203 (Triage)** — cross-project blockers within one initiative. Fully subsumed by Decision 4 under the project-list scope. Cancel with a comment pointing at this design + the implementation ticket.

## Follow-up tickets to file after approval

1. **Implement ralph scope model** — one implementation ticket covering all changes above (subsumes ENG-203). `blocked-by: ENG-206`.
2. **Close ENG-203 as subsumed** — comment linking to this design and the implementation ticket.

## Open questions (deferred to implementation)

1. **Pre-validation of `projects` against Linear at load time.** Would catch unknown project names earlier but adds a round-trip to every invocation. Current plan: skip; the existing "query fails cleanly on unknown project" path is sufficient. Revisit if the early failure proves too cryptic in practice.

2. **Initiative expansion caching.** Fresh lookup each invocation keeps semantics simple and avoids staleness. If latency becomes a real concern at scale (≥5 projects, slow Linear API windows), add an opt-in cache with a short TTL — not before.

3. **Alternate file format (TOML / YAML) for `.ralph.json`.** JSON matches the existing `config.json` and `jq` tooling, and scope is a tiny data shape. If the file grows hard-to-edit fields later, reconsider.
