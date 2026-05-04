# Move "Known gaps / deferred" to Review Summary in prepare-for-review template

## Problem

`skills/prepare-for-review/SKILL.md` is internally inconsistent.

- **Step 5's prose (currently line 209)** instructs the agent that
  ambiguous codex findings should be captured in the handoff comment's
  `## Review Summary` section, "under 'Surprises during implementation'
  or 'Known gaps / deferred' as fits."
- **The Step 6 comment template (heredoc starting at line 247)** places
  the `**Known gaps / deferred:**` field under `## QA Test Plan`, not
  Review Summary.

A strict reader following Step 5 would file known-gap entries into a
field that doesn't exist where the step claims it does, then either
silently invent a heading or stuff the content somewhere else.

## Conceptual fix

"Known gaps / deferred" is a retrospective scope statement — it
answers "what didn't ship?" Its conceptual siblings are "Deviations
from the PRD" and "Surprises during implementation," all of which
belong in Review Summary.

QA Test Plan is purely forward-looking: instructions for the human
reviewer on what to exercise. Known gaps optionally constrain that
plan, but the primary audience for that information is someone asking
"is the scope right?" — a Review Summary question.

Step 5's existing prose already names the right section ("Review
Summary"), so the fix is template-side: align the template with what
Step 5 already says.

## Change

In `skills/prepare-for-review/SKILL.md`, edit the heredoc that begins
with `<<'COMMENT'` (currently at line 247).

**Remove** this line from the QA Test Plan section (currently the last
line before the closing `COMMENT` marker):

```
**Known gaps / deferred:** <anything intentionally left unfinished; "None" if complete>
```

**Insert** the same line into the Review Summary section, between the
"Surprises during implementation:" line and the "Documentation
changes:" line. The blank-line cadence between bold-field entries
must match the surrounding lines exactly (one blank line above and
below the inserted entry).

After the change, the heredoc body's section structure must read:

```
## Review Summary

**What shipped:** <1-3 sentence summary of the implementation>

**Deviations from the PRD:** <bulleted list of anything that differs from the issue description; "None" if identical>

**Surprises during implementation:** <bulleted list of things the PRD didn't anticipate; "None" if clean>

**Known gaps / deferred:** <anything intentionally left unfinished; "None" if complete>

**Documentation changes:** <bulleted list of decisions captured and docs pruned this session; "None" if nothing>
- Decision: <file:line or path> — <one-sentence summary>
- Pruned: <path> — <one-sentence reason>

## QA Test Plan

**Golden path:** <specific manual steps to verify the core behavior works>

**Edge cases worth checking:** <bulleted list of risky paths — what was tricky to get right, what boundary conditions exist>
```

Note that the **Documentation changes** field's bullet examples
(`- Decision: ...`, `- Pruned: ...`) stay attached directly under it
— do not separate them from their parent field by the inserted Known
gaps entry.

## What does NOT change

- **Step 5's prose (line 209)** stays as is. It already says "Review
  Summary." The point of this ticket is to make the template match.
- **No other sections** of `SKILL.md` are touched. No reordering of
  existing fields, no renaming, no new fields.
- **Frozen specs in `docs/specs/`** that reference "Known gaps /
  deferred" by name (e.g., `stale-parent-pre-merge-sha.md`) are
  point-in-time records. They reference the field by name, not by
  section placement, so they remain accurate after this change.
- **Stale copies of `SKILL.md` in `.worktrees/eng-*/`** are not
  edited. Each worktree's branch will receive the updated content
  through normal rebase/merge with main when next worked on.
- **Posted Linear comments** from prior `/prepare-for-review` runs
  are not migrated. The template is consumed at write-time; existing
  comments in Linear are immutable history and don't matter.

## Verification

The skill is markdown-only — no executable tests. Verification is:

1. **Diff inspection.** Confirm that exactly one line was removed
   from one location and inserted at another. No other characters
   should change.
2. **Heredoc integrity.** The closing `COMMENT` marker on its own
   line must be preserved exactly. Any change to its position or
   surrounding whitespace would break the bash heredoc syntax.
3. **No duplicate field.** Grep the file for the literal string
   `**Known gaps / deferred:**` — exactly one match must remain,
   inside the Review Summary section.

   ```bash
   grep -c '\*\*Known gaps / deferred:\*\*' skills/prepare-for-review/SKILL.md
   # Must print: 1
   ```

4. **No QA Test Plan residue.** Confirm `## QA Test Plan` no longer
   contains the Known gaps line by visually inspecting the section.
   It should now contain only `**Golden path:**` and `**Edge cases
   worth checking:**`.
5. **Step 5 prose unchanged.** Confirm line 209 (or the equivalent
   line referencing "Review Summary" and "Known gaps / deferred")
   reads identically before and after.

## Out of scope

- Any restructuring or reordering of other fields in either section.
- Adding inline reminder comments in the template explaining the
  placement rationale (the issue body and this spec record the
  rationale; adding it inline would clutter the template).
- Updating any other skill or doc that mentions "QA Test Plan" or
  "Review Summary" generically — those references still hold.
- Any backward-compatibility shim for already-posted comments —
  none exists or is needed.

## Implementation notes

- This is a single `Edit` tool call (one `old_string`, one
  `new_string`) on `skills/prepare-for-review/SKILL.md`.
- Estimated diff: ~5 lines net (one removed line + one inserted line
  + one removed blank line + one inserted blank line, plus context).
- No code changes, no test changes, no companion-skill changes.

## Acceptance

The change is accepted when:

1. `skills/prepare-for-review/SKILL.md` contains exactly one
   `**Known gaps / deferred:**` line, in the Review Summary section,
   between "Surprises during implementation" and "Documentation
   changes."
2. The QA Test Plan section contains only "Golden path" and "Edge
   cases worth checking" fields.
3. The bash heredoc syntax of the comment template still parses (the
   `COMMENT` close marker is intact and on its own line).
4. Step 5's prose at line 209 is byte-identical to its pre-change
   form.
