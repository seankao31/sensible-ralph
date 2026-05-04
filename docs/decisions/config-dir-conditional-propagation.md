# CLAUDE_CONFIG_DIR forwarded conditionally, not unconditionally

## Context

ENG-308 added `CLAUDE_CONFIG_DIR="$config_dir" claude -p ...` at the dispatch
site so the child would land its JSONL exactly where the orchestrator recorded
`transcript_path`. This was defensive: when the parent had `CLAUDE_CONFIG_DIR`
set to an empty or relative value, the orchestrator normalized it to
`$HOME/.claude`, and the explicit export forced the child to use the same path.

ENG-337 revealed that this export broke authentication on macOS when the parent
had `CLAUDE_CONFIG_DIR` **unset** (the documented default). claude 2.x branches
its auth-resolution path on the *set-ness* of the variable, not its value:
explicitly setting it to `$HOME/.claude` disables the macOS keychain fallback
and reads only `~/.claude/.claude.json`, which on macOS lacks auth fields. Every
dispatched child exited with `Not logged in · Please run /login`.

Two fix options were on the table:

- **Option 1 — drop the export entirely.** Children inherit `CLAUDE_CONFIG_DIR`
  naturally when the parent has it set; when the parent has it unset, the child
  defaults to `$HOME/.claude` anyway. Simplest, but silently discards ENG-308's
  defense against empty/relative parent values.

- **Option 2 — export only when normalization did real work.** Track a
  `_propagate_config_dir` flag: set to 1 iff the parent had `CLAUDE_CONFIG_DIR`
  set to *any* value (empty, relative, or absolute); 0 when unset. Export at the
  dispatch site iff the flag is 1.

## Decision

Option 2. Propagate `CLAUDE_CONFIG_DIR` to the child only when the parent had it
set (regardless of value quality), leave the child's env alone when the parent
had it unset.

## Reasoning

Option 1 discards the ENG-308 defense for a case that, while rare, is real: an
operator whose shell has `CLAUDE_CONFIG_DIR=""` or `CLAUDE_CONFIG_DIR=relative`
would silently produce a divergent JSONL location — the orchestrator records one
path in `transcript_path` but claude writes elsewhere. The operator can't
trivially find the session transcript from `/sr-status`. The warnings the
orchestrator already emits (for empty/relative values) alert the operator to the
misconfiguration, but the forwarded normalized value keeps the transcript pointer
accurate in the meantime.

Option 2 keeps the defense (export normalized value for empty/relative parent)
while fixing the auth regression (no export when parent was unset).

## Consequences

Future changes to env threading in `_dispatch_issue` must preserve the set-ness
distinction: "parent had it set" and "parent had it unset" are semantically
distinct. Only the *unset* case should leave the child's env variable absent.
The `_propagate_config_dir` flag makes this distinction explicit at the
normalization site; the dispatch site reads the flag, not `CLAUDE_CONFIG_DIR`
directly.
