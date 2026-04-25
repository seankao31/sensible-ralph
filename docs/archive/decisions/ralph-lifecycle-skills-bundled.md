# Ralph lifecycle skills bundled into the plugin (close-issue, prepare-for-review)

**Date:** 2026-04-24

## Context

ENG-243 specified moving ralph-start, ralph-spec, and ralph-implement into the
sensible-ralph plugin. During interactive implementation (2026-04-24), we noticed
that `close-issue` and `prepare-for-review` — both living in chezmoi's
`agent-config/skills/` as "global" skills — have deep ralph-lifecycle coupling
and shouldn't be left behind.

The original spec scoped them out because they were classified as "general-purpose"
and lived in the chezmoi global layer rather than the ralph-specific layer. That
classification turned out to be wrong.

## Decision

Bundle `close-issue` and `prepare-for-review` into the sensible-ralph plugin
alongside the three already-specified skills.

## Reasoning

**close-issue:** The whole skill is ralph-lifecycle invariants — state-machine gate
(issue must be In Review), blocker ordering gate (all parents Done), stale-parent
labeling (detects DAG children built on pre-amendment base), worktree cleanup,
codex broker reap. The only project-specific part — VCS integration — is already
delegated to a project-local `close-branch` skill. Leaving close-issue in chezmoi
while ralph-start lives in the plugin would mean the loop's terminal step (merge)
sources its config from a different installation than everything else.

**prepare-for-review:** It's the exit gate of every dispatched `ralph-implement`
session — the skill that transitions `In Progress → In Review`. It is invoked BY
the plugin's ralph-implement skill. A plugin user who can't reach prepare-for-review
has a broken runtime. Leaving it in chezmoi ties the plugin's terminal state to
an external dependency that isn't versioned with the plugin.

**Naming conflict resolution:** Keeping both chezmoi copies and plugin copies of
the same skill name (`close-issue`, `prepare-for-review`) produces a dual-install
conflict when the plugin is enabled. Chezmoi's copies are deleted in the ENG-243
cutover commit; the plugin copies are authoritative post-extraction.

## Consequences

Consumers of `sensible-ralph` get close-issue and prepare-for-review automatically
when they install the plugin — no separate installation step. The project-local
`close-branch` skill (VCS integration) remains outside the plugin and is the only
thing a consumer repo must provide.

Future maintainers: if you're tempted to extract close-issue or prepare-for-review
back out, verify you have a plan for the "plugin's own lifecycle skills depend on an
external skill" problem first.
