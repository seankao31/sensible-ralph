# ralph-spec inlines issue creation instead of delegating to linear-workflow

## Context

ralph-spec's finalization Step 3 previously delegated issue creation to an external
`linear-workflow` skill: "Create via `linear-workflow`, honoring its duplicate-
prevention flow." This created an implicit dependency on a skill that ships as a
separate plugin (not bundled with sensible-ralph).

During ENG-243's interactive dogfooding (2026-04-24), the question arose: can
sensible-ralph be installed standalone without linear-workflow?

## Decision

Remove the delegation. Step 3 now directly performs the two operations it actually
needed: duplicate-prevention scan and issue creation, both via the `linear` CLI.

## Reasoning

**ralph-spec only used one of linear-workflow's three entry points.** linear-workflow
defines three flows: (1) starting work, (2) filing-no-implementation, (3) handoff/
completion. ralph-spec exclusively used Entry Point 2 (file without implementation).
The other two flows — starting work with In Progress transition, completion with Done
transition — are irrelevant to ralph-spec's contract.

**The specific behavior needed is ~30 lines of prose.** The duplicate-prevention
scan (four rules: exact duplicate, superseded, partial overlap, already done) and
the `linear issue create` call with ralph-spec's creation conventions (title, project,
state=Todo, no description, no assignee, no labels) fit directly in ralph-spec's
SKILL.md without a separate skill dispatch.

**linear-workflow has its own conventions that ralph-spec would fight.** linear-workflow
has opinions about priority (Bugs→Urgent, Features→Medium), project resolution from
workspace context, and autonomous-session behavior (file without confirmation, link
to originating issue). ralph-spec has its own conventions (project validated against
`.ralph.json` scope, state=Todo, no priority, no labels). Delegating and then
overriding produces confusion; inlining makes the contract explicit.

**Fewer external dependencies reduces release friction.** The sensible-ralph plugin
can be installed and used without also installing a separate linear plugin. The
duplicate-prevention logic doesn't evolve fast enough to justify a shared-library
dependency — it's been stable since ENG-219.

## Consequences

- ralph-spec and linear-workflow's duplicate-prevention rules can diverge. If
  linear-workflow's rules improve, ralph-spec won't pick them up automatically.
  This is acceptable: ralph-spec's needs are simpler (spec-producing sessions) than
  general issue-filing.
- Any ralph-spec bug in issue creation is now fixed in ralph-spec's SKILL.md rather
  than in linear-workflow. That's the right place — it's a ralph concern.
- Future maintainers: if the issue-creation logic grows substantially (more rules,
  more edge cases), revisit whether it warrants extraction into a shared helper.
  For now, 30 lines beats a plugin dependency.
