# Shell helpers

Module map and loading conventions for the bash libraries that
underpin the orchestrator, preflight, queue builder, `sr-spec`,
`prepare-for-review`, and `close-issue`.

## Where the helpers live

After ENG-274 (and ENG-279, which lifted `worktree.sh`) the helpers
split across two directories. The partition criterion is **who sources
this?** — single skill stays local; multiple skills lift to plugin-wide
`lib/`. It is *not* "what does it do?": purpose-based grouping
(`config/`, `linear/`, `scope/`, `git/`) was rejected as over-engineered
for a small file count, and function-style proximity ("close-issue
specific") was rejected as a structural lie when nothing prevents a
second consumer from appearing.

```
sensible-ralph/
├── lib/                                ← plugin-wide (multi-skill)
│   ├── defaults.sh
│   ├── linear.sh
│   ├── scope.sh
│   ├── branch_ancestry.sh
│   └── worktree.sh
└── skills/
    └── sr-start/scripts/lib/           ← sr-start-only
        └── preflight_labels.sh
```

`close-issue` keeps its own `scripts/lib/preflight.sh` and
`scripts/lib/stale_parent.sh` for the same reason sr-start keeps
`preflight_labels.sh`: single-skill consumers, single-skill location.
Pre-ENG-274, `close-issue` reached into `skills/sr-start/scripts/lib/`
for shared helpers; that path was a transitional ownership leak the
restructure resolved. `close-issue` no longer sources from
`skills/sr-start/scripts/lib/` at all.

## Module map

### Plugin-wide (`lib/`)

Sourced by orchestrator, preflight_scan, build_queue, dag_base,
sr-spec, sr-status, prepare-for-review, and close-issue.

| File | Purpose | Public surface |
|---|---|---|
| `defaults.sh` | Shell-side fallback values for `CLAUDE_PLUGIN_OPTION_*` env vars when the plugin harness hasn't populated them (e.g. operator skipped the enable-time config dialog). Mirrors the `userConfig` defaults in `.claude-plugin/plugin.json`. | Exports `CLAUDE_PLUGIN_OPTION_DESIGN_STATE`, `_APPROVED_STATE`, `_IN_PROGRESS_STATE`, `_REVIEW_STATE`, `_DONE_STATE`, `_FAILED_LABEL`, `_STALE_PARENT_LABEL`, `_COORD_DEP_LABEL`, `_WORKTREE_BASE`, `_MODEL`, `_STDOUT_LOG_FILENAME`. Idempotent; preserves explicitly-empty caller values so preflight catches misconfiguration rather than silently papering over it. |
| `linear.sh` | Linear CLI / GraphQL wrappers. Domain layer above `linear` and `linear api`. | `linear_list_approved_issues`, `linear_list_initiative_projects`, `linear_get_issue_blockers`, `linear_get_issue_blocks`, `linear_get_issue_branch`, `linear_get_issue_state`, `linear_set_state`, `linear_add_label`, `linear_remove_label`, `linear_label_exists`, `linear_comment`. |
| `scope.sh` | Reads `<repo-root>/.sensible-ralph.json`, resolves `projects` directly or expands `initiative` via Linear. Auto-runs `_scope_load` on source. | Exports `SENSIBLE_RALPH_PROJECTS` (newline-joined project names), `SENSIBLE_RALPH_DEFAULT_BASE_BRANCH`, and the bleed-through guard `SENSIBLE_RALPH_SCOPE_LOADED`. |
| `branch_ancestry.sh` | Pure-git helpers — no Linear dependency. Currently consumed by `close-issue` only; lives in plugin-wide `lib/` because the helpers are framework-shaped (anything else needing ancestry checks should reuse them) and the file's own header anticipates this. | `is_branch_fresh_vs_sha` (0/1/2 outcome triple), `list_commits_ahead`, `resolve_branch_for_issue`. |
| `worktree.sh` | Worktree creation, state classification, and path-resolution helpers. Encodes sr-start dispatch's worktree semantics: on any conflict (single or multi parent) both merge helpers leave conflicts in place and write a SHA-pinned `.sensible-ralph-pending-merges` marker for the dispatched session to drain. Marker writes are atomic (mktemp + same-FS rename) and fail closed — any I/O failure or hostile preexisting non-file at the marker path propagates as the helper's non-zero exit, so the orchestrator never dispatches a session over a worktree in MERGING state without a valid marker. Lifted from sr-start scripts/lib in ENG-279 — `/sr-spec` step 7 became the second consumer. | `worktree_create_at_base`, `worktree_create_with_integration`, `worktree_merge_parents`, `worktree_path_for_issue`, `worktree_branch_state_for_issue`, `_resolve_repo_root`, `_worktree_write_pending_marker`. |

### sr-start-only (`skills/sr-start/scripts/lib/`)

Sourced only by orchestrator and preflight_scan.

| File | Purpose | Public surface |
|---|---|---|
| `preflight_labels.sh` | Workspace-label existence preflight. Hardcoded list of required `CLAUDE_PLUGIN_OPTION_*_LABEL` env vars; rejects misconfiguration where the env var is empty as well as the case where Linear lacks the label. | `preflight_labels_check`. |

`preflight_labels.sh` could theoretically move to plugin-wide `lib/`,
but it has exactly one consumer today; lifting it now would be
speculative. The criterion is *move when sharing exists, not when
sharing might hypothetically exist* — exactly why ENG-279 lifted
`worktree.sh` once `/sr-spec` became its second consumer.

## Load order

Two rules govern source order:

1. **`defaults.sh` first.** The fallback values it exports are read
   by other modules at call time (e.g. `linear.sh` references
   `CLAUDE_PLUGIN_OPTION_APPROVED_STATE` and `_FAILED_LABEL` inside
   `linear_list_approved_issues`). Sourcing `defaults.sh` first
   guarantees those names are bound — even when the plugin harness
   skipped the enable-time dialog and never exported them.
2. **`linear.sh` before `scope.sh`.** `scope.sh`'s `_scope_load`
   guard checks `declare -f linear_list_initiative_projects` and
   fails loudly if the function isn't defined. Without the guard the
   `initiative` expansion path would emit a late "command not found"
   that's harder to trace than a load-time error.

`branch_ancestry.sh` has no inter-module dependencies — pure git, no
Linear, no `CLAUDE_PLUGIN_OPTION_*` reads — so it can be sourced at
any point in the sequence.

### Canonical sequence (orchestrator)

`skills/sr-start/scripts/orchestrator.sh` sources via
`$PLUGIN_ROOT/lib/...` for plugin-wide helpers, in this order:

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

source "$PLUGIN_ROOT/lib/defaults.sh"
source "$PLUGIN_ROOT/lib/linear.sh"
# scope.sh re-source is gated by SENSIBLE_RALPH_SCOPE_LOADED — see below.
source "$PLUGIN_ROOT/lib/scope.sh"
source "$PLUGIN_ROOT/lib/worktree.sh"
```

`PLUGIN_ROOT` prefers the harness-exported `$CLAUDE_PLUGIN_ROOT` and
falls back to walking three levels up from `$SCRIPT_DIR` — used by
the bats harnesses, which run scripts outside the harness context.
The same fallback applies in `preflight_scan.sh`, `build_queue.sh`,
`dag_base.sh`, and `coord_dep_backstop_scan.sh`.

### Canonical sequence (close-issue)

`skills/close-issue/SKILL.md` sources from the plugin's top-level
`lib/` (aliased as `$PLUGIN_LIB`) and from its own `scripts/lib/` for
close-issue-specific helpers:

```bash
PLUGIN_LIB="$CLAUDE_PLUGIN_ROOT/lib"
source "$PLUGIN_LIB/defaults.sh"
source "$PLUGIN_LIB/linear.sh"
source "$PLUGIN_LIB/scope.sh"
source "$PLUGIN_LIB/branch_ancestry.sh"
source "$CLAUDE_PLUGIN_ROOT/skills/close-issue/scripts/lib/preflight.sh"
source "$CLAUDE_PLUGIN_ROOT/skills/close-issue/scripts/lib/stale_parent.sh"
```

`preflight.sh` and `stale_parent.sh` go last because both have
load-time dependencies on functions defined in `linear.sh` (and
`stale_parent.sh` additionally on `branch_ancestry.sh`).

## Bleed-through guard

`scope.sh` exports `SENSIBLE_RALPH_SCOPE_LOADED` as the tuple
`"<repo-root-abs-path>|<sha1-of-.sensible-ralph.json>"`. Entry-point
scripts compute their own expected tuple and re-source `scope.sh`
only when the marker differs:

```bash
RESOLVED_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || RESOLVED_REPO_ROOT=""
RESOLVED_SCOPE_HASH=""
if [[ -n "$RESOLVED_REPO_ROOT" && -f "$RESOLVED_REPO_ROOT/.sensible-ralph.json" ]]; then
  RESOLVED_SCOPE_HASH="$(shasum -a 1 < "$RESOLVED_REPO_ROOT/.sensible-ralph.json" | awk '{print $1}')"
fi
EXPECTED_SCOPE_LOADED="${RESOLVED_REPO_ROOT}|${RESOLVED_SCOPE_HASH}"
if [[ "${SENSIBLE_RALPH_SCOPE_LOADED:-}" != "$EXPECTED_SCOPE_LOADED" ]]; then
  source "$PLUGIN_ROOT/lib/scope.sh"
fi
```

Why both components matter:

- **Repo-root path** catches cross-repo bleed-through — running
  `/sr-start` in repo A and then in repo B from the same shell would
  otherwise inherit A's `SENSIBLE_RALPH_PROJECTS`.
- **Content hash of `.sensible-ralph.json`** catches in-place edits and
  branch switches in the same worktree that change scope. Without it,
  the gate would match path-wise and silently keep stale projects.

The guard is shell-environment, not file-system: subprocesses inherit
the env var and skip the re-source, but a fresh shell starts with
the var unset and always re-sources. See
[`scope-model.md`](scope-model.md) Decision 3 for deeper rationale,
including the initiative-expansion caching profile and why mid-run
membership changes are accepted as a known limitation.

## Bash 3.2 portability

macOS ships `/bin/bash` 3.2 and the plugin runs there. Concrete
implications for these helpers:

- **No `declare -A` associative arrays.** Where keyed lookup is
  needed, use a parallel-arrays-by-index pattern or jq.
- **No `mapfile` / `readarray`.** Use `while IFS= read -r line; do
  ...; done <<< "$input"` instead — `lib/linear.sh::linear_add_label`
  and `lib/scope.sh::_scope_load_projects` both use this shape.
- **Newline-joined strings substitute for arrays across `source`
  boundaries.** A real bash array doesn't cross a `source` cleanly on
  3.2 — that's why `SENSIBLE_RALPH_PROJECTS` is exported as a
  newline-joined string and consumers iterate with `while IFS= read -r
  project; do ...; done <<< "$SENSIBLE_RALPH_PROJECTS"`.
- **Empty-array expansion needs the `${arr[@]+"${arr[@]}"}` guard
  under `set -u`.** Bash 3.2 treats expanding an unset array reference
  as an unbound-variable fault even when the array was declared but
  never appended to. See `lib/linear.sh::linear_add_label` and
  `skills/sr-start/scripts/lib/preflight_labels.sh::preflight_labels_check`
  for the working pattern.

Future contributors: don't reach for bash 4+ features. `bash --version`
on the dev machine is misleading because Homebrew installs a newer
bash at `/opt/homebrew/bin/bash`; the harness invokes `/bin/bash`.

## Sourcing-from rules of thumb

- **From a SKILL.md:** use `$CLAUDE_PLUGIN_ROOT/lib/...` directly. The
  harness exports it whenever the plugin is enabled.
- **From an entry-point script under `skills/sr-start/scripts/`:** use
  `$PLUGIN_ROOT/lib/...` with the `${CLAUDE_PLUGIN_ROOT:-$(cd
  "$SCRIPT_DIR/../../.." && pwd)}` fallback shape, so the script
  works both in production (harness present) and from a bats harness
  (harness absent, working from the real repo path).
- **`# shellcheck source=` hints:** for plugin-wide libs, point them
  at the relocated path (`# shellcheck source=../../../lib/<file>.sh`
  from `skills/<skill>/scripts/`); for sr-start-only libs, the
  intra-skill path (`# shellcheck source=lib/<file>.sh`).
- **Don't add `set` calls or `exit` at the top level of a sourced
  file** — sourcing mutates the caller's shell options and aborts the
  caller's process. Use `return` for errors. All callers in this
  codebase run with `set -euo pipefail` already active.
