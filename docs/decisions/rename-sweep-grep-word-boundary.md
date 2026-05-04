# Rename-sweep acceptance grep needs `\b` before `RALPH_[A-Z_]+`

## Context

The ENG-276 spec (`docs/specs/rename-to-sensible-ralph.md`) defined an
acceptance grep in criterion 1 to verify that no plugin-identity
`ralph` tokens remained outside heritage carve-outs. One alternation was
`RALPH_[A-Z_]+` — meant to catch env vars that hadn't been renamed to
`SENSIBLE_RALPH_*`. After completing the rename sweep, that alternation
returned hundreds of hits. None of the hits were unrenamed vars; they
were all the *renamed* `SENSIBLE_RALPH_*` vars matching as substrings.

## Decision

The pattern must be `\bRALPH_[A-Z_]+`, not `RALPH_[A-Z_]+`.

## Reasoning

`_` is a word character in regex (`\w` = `[A-Za-z0-9_]`). The token
`SENSIBLE_RALPH_PROJECTS` therefore has *no* word boundary between
`E` (end of `SENSIBLE`) and the `_`, nor between the `_` and `R` (start
of `RALPH`). Without an explicit `\b` anchor before `RALPH_`, the
substring `RALPH_PROJECTS` matches inside `SENSIBLE_RALPH_PROJECTS`.

Adding `\b` forces the engine to require a word/non-word transition
immediately before `R`. Inside `SENSIBLE_RALPH_*` the character before
`R` is `_` (a word char), so the boundary doesn't fire and the pattern
correctly skips the renamed token. Standalone `RALPH_PROJECTS` (e.g.
in heritage docs that the grep should still flag) starts at a position
where the prior char is a non-word char (start of line, space, `$`,
quote, etc.), so `\b` does fire and the match succeeds.

The other alternations in the same grep (`\.ralph\b`, `skills/ralph-`,
`\bralph-(start|spec|implement|status)\b`, `\bralph_[a-z]`) were already
correctly anchored; only `RALPH_[A-Z_]+` was missing its boundary.

## Consequences

- **Future rename tickets** that need to verify completeness via grep
  must remember to anchor with `\b` whenever the new name *contains*
  the old name as a substring delimited only by word characters
  (`SENSIBLE_RALPH_FOO` contains `RALPH_FOO`; `XSensibleRalphX` would
  contain `SensibleRalph`; etc.).
- **A correctly-anchored grep is a behavioral verification** — a
  green grep should mean "no unrenamed tokens remain," not "the grep
  was tautologically passing." Spot-checking the grep against a
  deliberately-stale fixture before relying on it is cheap insurance.
- The fix landed in the same commit as the rename
  (`75acac8`), and the spec at
  `docs/specs/rename-to-sensible-ralph.md` was updated to document the
  reasoning inline ("Pattern notes" paragraph).
