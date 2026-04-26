# Fix `sr-spec` echo-pipe-jq to use `printf` (zsh-safe)

**Linear:** ENG-269
**Date:** 2026-04-25

## Goal

Replace `echo "$VIEW" | jq` with `printf '%s' "$VIEW" | jq` on three
lines of `skills/sr-spec/SKILL.md`, so the preflight block survives
zsh's backslash-expanding `echo` builtin when the Claude Code Bash tool
dispatches commands through `/bin/zsh -c`.

This restores consistency with the rest of the codebase — `printf '%s'
| jq` is already the dominant pattern across `skills/sr-start/`,
`skills/close-issue/SKILL.md`, and even line 320 of this same file
(`BLOCKERS_JSON`). The three offending lines are the outlier.

## Background

Linear issue descriptions can contain newlines, which serialize as `\n`
escape sequences inside JSON string values. zsh's builtin `echo`
interprets backslash escapes by default and converts those `\n` into
literal newlines mid-stream. JSON forbids unescaped control characters
U+0000–U+001F inside string values, so `jq` rejects the result with:

```
jq: parse error: Invalid string: control characters from U+0000 through
U+001F must be escaped
```

`printf '%s'` is POSIX-strict and never interprets backslashes in its
argument — only in the format string — so the JSON round-trips intact
regardless of which shell is interpreting the command.

This was first observed during a `/sr-spec ENG-234` run on
2026-04-24, where the preflight block crashed on a description
containing a multi-line code fence. The fix was applied inline at the
time; this issue codifies it in the SKILL.

## Scope

Edit exactly one file: `skills/sr-spec/SKILL.md`.

Note: ENG-269's description references `agent-config/skills/sr-spec/
SKILL.md`, which is the pre-extraction location. The live file in this
repository lives under `skills/`. Edit the live path, not the historical
one.

### Edit — replace `echo` with `printf '%s'` at lines 185–187

The three lines inside the `if [ -n "${ISSUE_ID:-}" ]; then` block:

```bash
# before
STATE=$(echo "$VIEW" | jq -r '.state.name')
PRIOR=$(echo "$VIEW" | jq -r '.description // empty')
ISSUE_PROJECT=$(echo "$VIEW" | jq -r '.project.name // empty')

# after
STATE=$(printf '%s' "$VIEW" | jq -r '.state.name')
PRIOR=$(printf '%s' "$VIEW" | jq -r '.description // empty')
ISSUE_PROJECT=$(printf '%s' "$VIEW" | jq -r '.project.name // empty')
```

No surrounding prose changes. No new comment explaining the choice —
the rest of the codebase doesn't comment its `printf '%s' | jq`
usages (e.g. `BLOCKERS_JSON` at line 320, all of `linear.sh`,
`build_queue.sh`, `preflight_scan.sh`, `orchestrator.sh`,
`dag_base.sh`, `close-issue/SKILL.md`), and adding one only on these
three lines would be inconsistent.

## Verification

After the edit, all of the following must pass:

1. `grep -nE 'echo .*\| *jq' skills/sr-spec/SKILL.md`
   → zero matches.

2. `grep -cF 'printf '\''%s'\'' "$VIEW" | jq' skills/sr-spec/SKILL.md`
   → exactly `3` (fixed-string count; no regex escaping pitfalls).

3. Repo-wide audit stays clean:
   `grep -rnE 'echo .*\| *jq' --include='*.md' --include='*.sh' .`
   → zero matches anywhere outside `.git/`.

No automated test suite covers this file; verification is the three
greps above. The fix can additionally be exercised end-to-end by
running `/sr-spec` against any Linear issue with a multi-line
description and confirming the preflight block does not error — but
this is optional, not gating.

## Testing expectations

This is a documentation-only edit to a skill file. No code changes, no
tests to add or update. TDD doesn't apply.

## Out of scope

- **Other `echo "$VAR" | jq` instances.** Repo-wide audit at spec time
  found zero. If the verification grep in step 3 returns matches, those
  are new since this spec was written and need separate evaluation —
  do NOT silently widen this fix to cover them.
- **Defensive shell options** (e.g. `emulate sh`, `setopt NO_BSD_ECHO`).
  These would mask the bug but not fix the SKILL.md text as documented,
  and would add shell-mode coupling that the rest of the codebase
  doesn't have.
- **Contributor guidance** (CLAUDE.md note, CONTRIBUTING.md, lint
  rule). A repo-wide convention is broader than this fix and out of
  scope. The other 30+ `printf '%s' | jq` call sites already establish
  the pattern by example.
- **Comment near the edited lines** explaining "why printf and not
  echo." Inconsistent with how the rest of the codebase treats the
  same idiom.

## Prerequisites

None. No `blocked-by` relations to set.

## Alternatives considered

1. **`printf '%s' "$VAR" | jq`** (chosen). POSIX-strict, matches
   dominant repo style, smallest possible diff, restores consistency
   the file already has at line 320.

2. **Here-string: `jq -r '.state.name' <<<"$VIEW"`.** Avoids the pipe
   entirely. Functionally correct in bash and zsh, but `<<<` is not
   POSIX, no other site in the repo uses it for `jq`, and it would
   introduce a new idiom for no benefit.

3. **`jq --argjson view "$VIEW" '$view.state.name'`.** Bypass the
   shell stream by passing JSON as a CLI argument. Brittle for
   arbitrarily-shaped descriptions (quoting, length limits), and
   massively inconsistent with surrounding code.

4. **Switch the Bash tool's invocation shell.** Out of scope for this
   plugin; would also leave the SKILL.md vulnerable to anyone running
   it under a non-Claude-Code zsh.
