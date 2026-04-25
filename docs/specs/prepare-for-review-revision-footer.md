# Replace `/prepare-for-review` dedup marker with a visible revision footer

## Problem

`/prepare-for-review` Step 6 currently embeds a dedup marker as the first line of the
`## Review Summary` section in the Linear handoff comment:

```
<!-- review-sha: $CURRENT_SHA -->
```

The assumption was that HTML comments render invisibly. Linear does not honour that
convention: `<!--` renders as literal text, and `-->` is auto-transformed by a
typographic input rule into `→`. Every handoff comment therefore opens with a visible
line of machine metadata sitting just below the `## Review Summary` header.

Functionally the dedup mechanism still works — Step 6's `body.contains` GraphQL filter
operates on the raw markdown body, not the rendered DOM, so SHA-based dedup remains
correct. The defect is cosmetic, but it appears on every handoff produced by the
sensible-ralph autonomous pipeline, so it warrants a clean fix.

## Goal

Replace the broken-invisibility marker with a visible, intentional revision footer
that:

1. Renders cleanly at the bottom of the handoff comment, visually separated from
   human-authored content.
2. Preserves the existing per-HEAD dedup invariant: re-running `/prepare-for-review`
   at the same `HEAD` is a no-op; re-running after new commits posts a fresh
   handoff.
3. Keeps the dedup query server-side via `body.contains`, since
   `linear issue comment list` cannot be relied on (returns only the first ~50
   comments with no exposed cursor).

## Non-goals

- **No retroactive fix to existing comments.** ENG-248 covers retrospective
  handoff-comment repair as a separate workstream and must not bleed into this
  change.
- **No change to the dedup query mechanism.** The GraphQL `body.contains` filter
  stays exactly as it is; only the marker string passed in changes.
- **No invisible-marker scheme.** Unicode zero-width characters and HTML-entity
  encodings were considered and rejected — the current bug is precisely an
  invisibility-by-convention assumption that broke; rolling new dice on the same
  class of trick is not worth the fragility.
- **No Linear-native metadata API research.** Linear comments do not expose
  user-defined metadata (only issues do, via custom fields); pursuing that path
  was rejected during design.

## Design

### Visible footer

Append a single-line footer at the **end** of the comment body, after the
`## Commits in this branch` block, separated by a horizontal rule:

```
---

_Posted by `/prepare-for-review` for revision `30ccec06a5f664daad895cb80fc8e6e5cdf4c9df`_
```

Italic text signals "machine-generated metadata"; the horizontal rule visually
separates it from human-authored review content; the full 40-char SHA in
backticks renders in monospace as developers expect.

### Dedup substring

The dedup query searches for the substring:

```
revision `<full-SHA>`
```

(literal `revision`, a single space, an opening backtick, the 40-char SHA, a
closing backtick). The phrase prefix plus backticks make accidental matches in
unrelated comment text astronomically unlikely; the full SHA preserves
per-HEAD uniqueness.

The marker is constructed via `printf` so backticks survive cleanly in bash
without command-substitution evaluation:

```bash
MARKER=$(printf 'revision `%s`' "$CURRENT_SHA")
```

The GraphQL query block downstream of `MARKER` (currently
`skills/prepare-for-review/SKILL.md` line 174) is **unchanged** — same
`body.contains` filter, same variable name, just a different marker string.

### File edits

All edits are confined to `skills/prepare-for-review/SKILL.md`. Line numbers
below reference the current file state and are descriptive — locate the actual
edit sites by surrounding context, not by line number, since the file may
shift before this issue is dispatched.

1. **Marker construction** (currently line ~173). Replace:
   ```bash
   MARKER="<!-- review-sha: $CURRENT_SHA -->"
   ```
   with:
   ```bash
   MARKER=$(printf 'revision `%s`' "$CURRENT_SHA")
   ```

2. **Explanatory paragraph** (currently line ~180). Rewrite the
   `<!-- review-sha: ... -->` reference to describe the new marker shape
   (`` revision `<SHA>` ``). The rationale about why server-side `body.contains`
   beats client-side `linear issue comment list` (~50-comment cap, no exposed
   cursor) stays intact — that argument is independent of marker shape.

3. **Placement instruction** (currently line ~186). Change:
   > Include `<!-- review-sha: $CURRENT_SHA -->` as the first line of the
   > `## Review Summary` section in the comment body so the SHA-based dedup
   > check can find it on retry.

   to refer to the new footer at the **end** of the comment body, e.g.:
   > Include the revision footer as the last line of the comment body so the
   > SHA-based dedup check can find it on retry.

4. **Heading printf** (currently line ~196). Replace:
   ```bash
   printf '## Review Summary\n<!-- review-sha: %s -->\n\n' "$CURRENT_SHA" > "$COMMENT_FILE"
   ```
   with:
   ```bash
   printf '## Review Summary\n\n' > "$COMMENT_FILE"
   ```

5. **Footer append** (after the existing commit-log append, currently after
   line ~221 `git log --oneline "$BASE_SHA"..HEAD >> "$COMMENT_FILE"`). Add:
   ```bash
   printf '\n---\n\n_Posted by `/prepare-for-review` for revision `%s`_\n' "$CURRENT_SHA" >> "$COMMENT_FILE"
   ```

### Verification

This is a skill markdown change with no automated test suite. The autonomous
implementer verifies in two layers:

**Static checks** (must all pass before considering the change complete):

- `grep -nE '<!--|review-sha' skills/prepare-for-review/SKILL.md` returns no
  matches. (The replacement marker uses the word `revision`, not `review-sha`,
  so this grep is a clean signal that the old marker is fully gone.)
- The `MARKER` variable assignment uses the `printf 'revision \`%s\`'` form
  shown above.
- The body assembly produces `## Review Summary\n\n` as its first content
  (no marker line above human content), and the final write before
  `linear issue comment add` ends with a horizontal-rule separator and the
  italic footer line containing the full `$CURRENT_SHA`.
- The GraphQL block at the original line ~174 is unchanged — same query,
  same variable plumbing.

**End-to-end verification** is deferred to the next real `/prepare-for-review`
invocation against a Linear issue. The codex-review-gate step that runs
*inside* `/prepare-for-review` itself (Step 5, on the implementing branch)
catches obvious bash/escape mistakes before any handoff comment is posted, so
incorrect quoting or expansion of the new printf marker fails fast rather
than producing a corrupt comment.

If a clean handoff comment is required for testing without producing a real
Linear side-effect, run the bash blocks for Step 6 manually with a fixture
`$CURRENT_SHA`, `$BASE_SHA`, and `$ISSUE_ID`, redirecting `linear issue
comment add` to `cat $COMMENT_FILE` to inspect the rendered body. This is
optional and at the implementer's discretion.

## Scope

- **Single file:** `skills/prepare-for-review/SKILL.md`.
- No other skills, no docs, no README, no plugin manifest changes.
- Confirmed by grep: no other `body.contains` dedup queries and no other
  `<!-- ... -->` HTML-comment markers exist in `skills/`. No
  `docs/`, `README.md`, or `CLAUDE.md` content references the current marker.

## Prerequisites

None. Self-contained.
