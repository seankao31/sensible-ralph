# Ralph-spec sources ralph-start's config and linear libs

## Context

`ralph-spec`'s finalization step needs three pieces of configuration that
`/ralph-start` also needs:

1. The `approved_state` value (workflow state name to transition to).
2. `$RALPH_PROJECTS` — the newline-joined list of in-scope projects from
   the repo's `.ralph.json`, expanded from the `initiative` shape if
   applicable via a Linear GraphQL query.
3. A helper for reading an issue's `blocked-by` relations in the same JSON
   shape the orchestrator reasons about (`linear_get_issue_blockers`).

Two realistic ways to get them:

1. **Reimplement** — parse `config.json` with `jq`, parse `.ralph.json`
   with `jq`, write a bespoke GraphQL query for initiative expansion,
   write another for blocker lookup.
2. **Source the same libs** `ralph-start`'s scripts source:
   `$HOME/.claude/skills/ralph-start/scripts/lib/{linear,config}.sh`.
   These export `$RALPH_APPROVED_STATE`, `$RALPH_PROJECTS`, and define
   `linear_get_issue_blockers` and `linear_list_initiative_projects`.

## Decision

`ralph-spec`'s finalization step sources `ralph-start`'s libs from the
installed skill directory:

```bash
CONFIG="${RALPH_CONFIG:-$HOME/.claude/skills/ralph-start/config.json}"
source "$HOME/.claude/skills/ralph-start/scripts/lib/linear.sh"
source "$HOME/.claude/skills/ralph-start/scripts/lib/config.sh" "$CONFIG"
```

All downstream logic uses `$RALPH_APPROVED_STATE`, `$RALPH_PROJECTS`, and
`linear_get_issue_blockers` — no reimplementation of the parsing or query
logic those libs already do.

## Reasoning

**Drift risk of reimplementation.** `.ralph.json` has two shapes (`projects`
list vs `initiative` name); `config.sh` validates both-set / neither-set,
handles zero-expansion of initiatives, and refuses silent truncation at
250 projects. A hand-rolled `jq` pipeline in ralph-spec would miss one of
these, silently, until the edge case hits in production. Reusing the lib
means ralph-spec and ralph-start cannot disagree on scope semantics by
construction.

**Same-helper guarantee for blocker verification.** The post-mutation
blocker verification in ralph-spec step 5 compares what we asked for
against what ralph-start's orchestrator will see at dispatch time. Using
`linear_get_issue_blockers` — the exact function `dag_base.sh` and
`build_queue.sh` call — means the verification and the dispatch read
the same bytes. Rolling our own query would open a semantic gap.

**Bash requirement.** `config.sh` uses bash 3.2+ features (array
indirection via `${!arr[@]}`) and fails in zsh with `bad substitution`.
`ralph-spec`'s SKILL.md notes this explicitly: if the login shell is
zsh or fish, wrap the sourcing in `bash -c` or a temp bash script.
This is the price of lib reuse; the alternative (writing POSIX-sh-safe
code in ralph-spec) is worse.

## Consequences

**Do not extract the libs into a new shared location** (e.g.
`agent-config/lib/`) to "clean up" the cross-skill coupling. The libs'
consumers are `ralph-start` scripts (path: `$SCRIPT_DIR/../lib/...`),
`ralph-spec` (path: `$HOME/.claude/skills/ralph-start/scripts/lib/...`),
and nothing else. A third location would double the import surface
without a third consumer.

**If `ralph-start` ever relocates its libs**, `ralph-spec`'s source paths
break. Mitigation: the sourcing is wrapped in a fail-loud `|| exit 1`
block with a message pointing at `$RALPH_CONFIG` and the repo's
`.ralph.json`. A missed path would stop before any mutation.

**Do not version-pin the ralph-start lib path.** `$HOME/.claude/skills/`
is where chezmoi materializes skills; if that convention ever changes,
both skills move together. The coupling is intentional — ralph-spec
depends on ralph-start being installed.
