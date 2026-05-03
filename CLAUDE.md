# sensible-ralph

Claude Code plugin for autonomous overnight execution of Approved Linear
issues. See [`README.md`](README.md) for the five pillars and overall
design; [`docs/usage.md`](docs/usage.md) for the operator flow.

## Linear

**Initiative:** AI Collaboration Toolkit
**Team:** Engineering
**Project:** Sensible Ralph

Pre-extraction history lives under Agent Config — don't refile there.

**Cross-repo follow-ups:** Issues that touch chezmoi-managed agent config
(e.g. `~/.claude/skills/<name>` like `linear-workflow`, `using-superpowers`)
belong in the **Agent Config** project, not Sensible Ralph. Link them via
`related` from the originating issue.

**Estimates** use Fibonacci points (1, 2, 3, 5, 8, 13) — Engineering team
default. Every new issue must include an estimate.

## Documentation layers

Three places live docs go:

- **`docs/design/`** — living subsystem reference. Non-ticket-shaped,
  describes how a subsystem works *now*. Reread on landing to understand
  the system; updated whenever a change makes the doc stale. One file
  per subsystem, kebab-case topic name, no date or Linear issue header.
- **`docs/specs/`** — per-ticket implementation specs. Written by
  `/sr-spec`, scoped to a single Linear issue, frozen on completion.
  Mostly implementation context and detail; not a project-design
  reference. Filenames are kebab-case topic names, no date prefix.
- **`docs/decisions/`** — captured non-obvious choices, atomic and
  retrospective. Decisions accumulate here until enough related ones
  exist to synthesize into a design doc; once synthesized, the decision
  moves to `docs/archive/decisions/`. Decisions that don't relate to
  any subsystem (one-off tactical choices) just get archived directly
  on completion. Filenames are kebab-case topic names, no date prefix.

**Implementer responsibility:** when a change touches a subsystem with
a design doc, update the design doc in the same commit/PR. Same rule
as code + comments + READMEs (see `~/.claude/CLAUDE.md` "Unit of Work").
Skill-level enforcement of this rule is a deferred follow-up — for
now it's social. Frozen specs in `docs/specs/` may quote earlier
versions of these conventions or other rules; those quotes are
point-in-time records of what the ticket added at the time, not the
current convention. This file (project-root `CLAUDE.md`) is the live
source of truth.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/):
`<type>(<scope>): <subject>` — or `<type>: <subject>` for changes
that span multiple areas or don't fit a scope. Scopes are
architectural areas (`close-branch`, `prepare-for-review`,
`gitignore`), not tickets.

Linear ticket references go in a `Ref:` git trailer in the body,
not in the scope or subject:

```
fix(close-branch): gate remote delete on ls-remote

<body explaining the change>

Ref: ENG-238
```

Commits without a Linear ticket omit the `Ref:` trailer.
