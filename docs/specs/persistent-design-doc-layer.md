# Persistent design-doc layer distinct from per-ticket specs

**Linear:** ENG-278

## Problem

The repo's documentation has two layers today, and they conflate two
different jobs.

- `docs/specs/` holds 12 active files. Roughly half are per-ticket
  implementation specs (`fix-sr-spec-echo-pipe-jq.md`,
  `2026-04-25-codex-review-gate-in-sr-spec.md`, etc.) — written by
  `/sr-spec`, scoped to one Linear issue, frozen on completion.
  Roughly half are subsystem design docs
  (`ralph-loop-v2-design.md`, `ralph-scope-model-design.md`,
  `sr-implement-skill-design.md`) — they describe how a subsystem is
  designed, but they were each born as a per-ticket spec and still
  carry that framing (Linear issue + date headers, "Supersedes ENG-X"
  pointers, "v2" in the filename).
- `docs/decisions/` holds atomic retrospective records of non-obvious
  choices. The folder is currently empty; all eight prior decisions
  have been moved to `docs/archive/decisions/`.

Neither layer fills the role of a **persistent, forward-looking
reference** that explains *how a subsystem works now*. A reader
looking to understand the orchestrator or the scope model has to
synthesize across point-in-time spec docs and current code.

`README.md` (lines 104–105) already says "Architectural designs live
in `docs/specs/`," documenting the conflation. The `-design` suffix on
the architectural files is a quiet convention that nobody has made
explicit.

## Goal

Establish `docs/design/` as a third, durable doc layer for living
subsystem references — separate from per-ticket specs and from
captured decisions — and seed it with one migrated example.

## Non-goals

Each of these is a deliberate exclusion. A future Linear issue can
take any of them on; none gates this issue.

- Migrating `docs/specs/ralph-loop-v2-design.md` (514 lines,
  point-in-time framing scattered through the body) to `docs/design/`.
- Migrating `docs/specs/sr-implement-skill-design.md` (written as a
  "Superseded by ENG-206" pointer; currency check is non-trivial) to
  `docs/design/`.
- Wiring `/prepare-for-review` or `update-stale-docs` to mechanically
  enforce the implementer-responsibility rule. The MVP relies on
  social enforcement via the CLAUDE.md rule.
- Adding `docs/design/` context-scanning to `/sr-spec` or
  `/sr-implement`. Skill discoverability comes via CLAUDE.md, which
  every session reads at start.
- Tooling to detect when a cluster of related decisions is ripe for
  synthesis into a design doc.

The autonomous implementer should not edit any skill file under
`skills/` as part of this issue. If a change seems to require it, that
indicates scope creep into one of the deferred follow-ups above.

## Design

### Folder structure & naming

- New folder `docs/design/` at the repo root.
- File naming: kebab-case, no date prefix, no Linear issue header, no
  "v2"-style version suffix in the filename. Topic name only. Example:
  `scope-model.md` — not `ralph-scope-model-design.md` and not
  `2026-04-25-scope-model.md`.
- The `-design` suffix used by existing files is dropped — when every
  file in `docs/design/` is a design doc, the suffix is redundant.
- One file per subsystem. No mega-files.
- Header is `# Subsystem name` followed by a one-line tagline. No
  bold-key metadata lines in the head — anything that reads as "what
  ticket / when / supersedes / extends / subsumes" belongs in commit
  history, not in a living doc.

### CLAUDE.md convention block

Append the following section to `CLAUDE.md` after the existing
`## Linear` block:

```markdown
## Documentation layers

Three places live docs go:

- **`docs/design/`** — living subsystem reference. Non-ticket-shaped,
  describes how a subsystem works *now*. Reread on landing to understand
  the system; updated whenever a change makes the doc stale. One file
  per subsystem, kebab-case topic name, no date or Linear issue header.
- **`docs/specs/`** — per-ticket implementation specs. Written by
  `/sr-spec`, scoped to a single Linear issue, frozen on completion.
  Mostly implementation context and detail; not a project-design
  reference.
- **`docs/decisions/`** — captured non-obvious choices, atomic and
  retrospective. Decisions accumulate here until enough related ones
  exist to synthesize into a design doc; once synthesized, the decision
  moves to `docs/archive/decisions/`. Decisions that don't relate to
  any subsystem (one-off tactical choices) just get archived directly
  on completion.

**Implementer responsibility:** when a change touches a subsystem with
a design doc, update the design doc in the same commit/PR. Same rule
as code + comments + READMEs (see `~/.claude/CLAUDE.md` "Unit of Work").
Skill-level enforcement of this rule is a deferred follow-up — for
now it's social.
```

This is the load-bearing artifact for AC-1 ("documented convention"
in the ENG-278 description). Place it after `## Linear`, before any
content the implementer might add later — it should be the second
top-level section of `CLAUDE.md`.

### Seed migration: `ralph-scope-model-design.md` → `scope-model.md`

The existing file (194 lines) is the smallest of the three
`*-design.md` files and the cleanest candidate. Steps:

1. **Move the file:**
   ```bash
   git mv docs/specs/ralph-scope-model-design.md docs/design/scope-model.md
   ```
2. **Rewrite the head.** Replace everything from the start of the
   file up to (but not including) the first `## ` heading with this
   block:

   ```markdown
   # Scope model

   Per-repo scope (`<repo-root>/.sensible-ralph.json`) declares which Linear
   projects this repo's `/sr-start` sessions drain. The orchestrator
   reads scope before every dispatch to bound queue construction,
   blocker resolution, and out-of-scope preflight checks.
   ```

   The existing file's first 7 lines are the title + metadata block —
   `# Ralph Scope Model: ...`, blank, `**Linear issue:**`, `**Date:**`,
   `**Extends:**`, `**Subsumes:**`, blank — all of which are removed
   in favor of the block above. Content from `## Problem` onward is
   not touched at this step.

   Also remove any "v2"/"v3" framing that survives in prose body
   paragraphs (the doc was originally written as a v2 design and
   carries some forward-looking-from-v1 phrasing).
3. **Currency check.** Read the file end-to-end against current
   `skills/sr-start/scripts/lib/scope.sh`. If any behavior
   described in the doc has drifted from the code (different env var
   name, different shape validation, different error message text),
   patch the doc inline. Do **not** modify `scope.sh`.
4. **Cross-references.** Run `git grep -l 'ralph-scope-model-design'`
   from the repo root. Update each match to point at
   `docs/design/scope-model.md`. Expected to be zero or one hit.
5. **No content reorganization** beyond head-stripping and currency
   patching. Sections, headings, examples stay where they are. This is
   migration, not rewrite — keeping it small means it's reviewable in
   one pass and reduces the risk of introducing fresh drift while
   migrating.

### README + usage.md updates

`README.md` lines 104–105 currently read:

```markdown
End-to-end operator flow is in [`docs/usage.md`](docs/usage.md).
Architectural designs live in [`docs/specs/`](docs/specs/); decisions
that outlived the designs live in [`docs/decisions/`](docs/decisions/).
```

Replace with:

```markdown
End-to-end operator flow is in [`docs/usage.md`](docs/usage.md).
Subsystem design docs live in [`docs/design/`](docs/design/); per-ticket
implementation specs in [`docs/specs/`](docs/specs/); captured decisions
in [`docs/decisions/`](docs/decisions/).
```

`docs/usage.md` line 3 currently reads:

```markdown
For design details see `docs/specs/ralph-loop-v2-design.md`; for the SKILL contract see `skills/sr-start/SKILL.md`.
```

**Leave unchanged.** `ralph-loop-v2-design.md` is a non-goal of this
issue, so the pointer still resolves. Updating it now would create a
dangling reference.

## Acceptance criteria

Mapped from the AC bullets in the ENG-278 issue description:

1. **Documented convention.** `CLAUDE.md` contains the new
   `## Documentation layers` section as specified above, immediately
   after `## Linear`.
2. **Seed design doc.** `docs/design/scope-model.md` exists, opens
   with `# Scope model`, contains no bold-key metadata lines in the
   head (`**Linear issue:**`, `**Date:**`, `**Supersedes:**`,
   `**Extends:**`, `**Subsumes:**`), and reflects current
   `lib/scope.sh` behavior.
3. **Skill discoverability.** No skill file changes. Discoverability
   is via the `CLAUDE.md` block, which every session reads at start.
   This is a deliberate interpretation of the original AC — explicit
   skill integration is a deferred follow-up.

## Verification

This is a docs change with no executable behavior. Verification is by
reading and grepping.

1. `git grep -l 'ralph-scope-model-design'` returns no results.
2. `docs/design/scope-model.md` exists; the file's head (everything
   before the first `## ` heading) contains no bold-key metadata
   lines — none of `**Linear issue:**`, `**Date:**`, `**Supersedes:**`,
   `**Extends:**`, or `**Subsumes:**` appear before the first section
   heading.
3. `docs/specs/ralph-scope-model-design.md` no longer exists.
4. `CLAUDE.md` contains a `## Documentation layers` section with all
   three folder bullets and the implementer-responsibility paragraph.
5. `README.md` references all three doc folders (`docs/design/`,
   `docs/specs/`, `docs/decisions/`).
6. Read the migrated `scope-model.md` end-to-end and confirm it
   describes current `lib/scope.sh` behavior. Any drift discovered is
   a docs bug to fix inline in the same change.

## Out-of-scope changes the autonomous session must NOT make

- No edits to any file under `skills/`.
- No edits to `docs/specs/ralph-loop-v2-design.md`.
- No edits to `docs/specs/sr-implement-skill-design.md`.
- No edits to `skills/sr-start/scripts/lib/scope.sh` (read-only
  reference for currency-checking the migrated doc).

## Single-PR scope

All changes are in `docs/design/` (new), `docs/specs/` (one file
removed, no others touched), `CLAUDE.md`, and `README.md`. The diff
should be reviewable as one PR.
