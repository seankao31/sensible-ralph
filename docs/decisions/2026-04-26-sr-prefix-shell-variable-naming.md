# `sr_` prefix for local shell variables, `SENSIBLE_RALPH_` for env vars

## Context

The ENG-276 rename sweep enumerated five identifier-bearing surfaces
in its surface map (consumer scope file, runtime dir, base-SHA marker,
internal env vars, slash commands and skill dirs). It did *not*
enumerate every snake-case `ralph_*` identifier the inventory grep
would surface. The implementer found two:

- `ralph_root` — a local shell variable in `skills/sr-start/SKILL.md`
  step examples and `skills/sr-start/scripts/build_queue.sh` comments,
  pointing at the runtime artifact dir.
- `digraph ralph_spec { ... }` — a graphviz diagram label in
  `skills/sr-spec/SKILL.md` showing the `/ralph-spec` (now `/sr-spec`)
  flow.

Both fall under the spec's renaming principle (plugin-identity → rename),
but the spec didn't pre-decide the new names.

## Decision

Local shell variables get the short `sr_` prefix; env vars keep the
full `SENSIBLE_RALPH_` prefix. So:

- `ralph_root` → `sr_root`
- `digraph ralph_spec` → `digraph sr_spec`
- `RALPH_PROJECTS` → `SENSIBLE_RALPH_PROJECTS` (already in the spec)

## Reasoning

The spec's surface-map rationale already justified asymmetric prefixes
between slash commands (`/sr-X`, short) and env vars
(`SENSIBLE_RALPH_X`, full). The argument: env vars conventionally
favor descriptive names because nobody types them at a prompt
(`LD_LIBRARY_PATH`, `KUBECONFIG`), while slash-command prefixes get
typed every invocation and benefit from compactness.

Local shell variables and graphviz node labels share the slash-command
side of that tradeoff:

- `sr_root` appears in user-visible SKILL.md `bash` snippets that
  operators copy-paste. Brevity matters for readability.
- `sr_spec` is a graphviz node identifier; visually compact labels
  read better in rendered diagrams, and the label directly mirrors
  the slash command name (`/sr-spec` → `digraph sr_spec`).

Env vars in contrast are referenced via `$SENSIBLE_RALPH_PROJECTS`
inside scripts — the user doesn't type them, and the descriptive
prefix prevents collisions with any future plugin that also exports a
generic `PROJECTS` var.

## Consequences

- **New shell variables** added inside this plugin's skills should
  follow the `sr_*` convention (e.g. `sr_log_dir`, `sr_queue_file`)
  unless they're being exported as env vars across a `source` boundary
  or a subprocess fork — exported names follow `SENSIBLE_RALPH_*`.
- **Graphviz diagram identifiers** that name slash commands or skill
  flows follow the `sr_*` form (mirrors `/sr-X`).
- The acceptance grep's `\bralph_[a-z]` alternation continues to
  catch any future identifier that drifts back to the heritage form;
  no new alternation needed.
