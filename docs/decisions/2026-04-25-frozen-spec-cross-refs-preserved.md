---
date: 2026-04-25
issue: ENG-278
---

# Frozen-spec cross-references to old scope-model path preserved deliberately

## Context

When `docs/specs/ralph-scope-model-design.md` was moved to
`docs/design/scope-model.md`, `git grep -l 'ralph-scope-model-design'`
returned matches in four frozen spec files beyond the migration spec
itself: `relocate-orchestrator-artifacts.md`,
`restructure-plugin-wide-shell-helpers.md`, `rename-to-sensible-ralph.md`,
and `ralph-loop-v2-design.md`. The ENG-278 PRD called for zero grep
results, but only counted on 0–1 substantive cross-refs.

## Decision

Only the live navigation pointer in `ralph-loop-v2-design.md:475` ("see
`ralph-scope-model-design.md`") was updated to the new path. The other
three references were left unchanged.

## Reasoning

Each of the three remaining files contains the old path as part of a
historical-narrative list, not as a clickable cross-ref:

- `relocate-orchestrator-artifacts.md` — in an "out-of-scope, intentionally
  not updated" list describing which files that ticket didn't touch.
- `restructure-plugin-wide-shell-helpers.md` — in a block explicitly stating
  "retroactive edits to prose records falsify the historical account and are
  left as-is."
- `rename-to-sensible-ralph.md` — in an "out-of-scope design records" list
  naming files by their path at the time of that ticket.

Updating these retroactively would make them claim things they didn't say —
e.g., the "we intentionally didn't update" list would name a file that now
lives somewhere else, confusing the historical meaning of the exception.

The migration spec itself (`persistent-design-doc-layer.md`) was also left
unchanged because it describes the migration and names the old path
intentionally.

## Consequences

A future `git grep -l 'ralph-scope-model-design'` will return these four
files. This is expected and does NOT indicate a stale cross-ref bug. Do not
"fix" these references — they are accurate historical records of the state
those documents described at the time they were written.
