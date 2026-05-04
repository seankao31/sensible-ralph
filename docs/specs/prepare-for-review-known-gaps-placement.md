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

The edit target is the bash heredoc inside `skills/prepare-for-review/SKILL.md`
that builds the static template body for the Linear handoff comment.
The heredoc is identifiable by its contents, not by its sentinel
name: it is the heredoc whose body contains the `**What shipped:**`,
`**Deviations from the PRD:**`, `**Surprises during implementation:**`,
`**Documentation changes:**` fields and the `## QA Test Plan` section
heading. At the time of writing, that heredoc opens with `<<'COMMENT'`
and closes with a `COMMENT` line, and is preceded by
`printf '## Review Summary\n\n' > "$COMMENT_FILE"` — but the action
described below is invariant to those particular tokens.

**Important framing:** the `## Review Summary` heading is not part of
the heredoc body. It is emitted by the separate `printf` call above
the heredoc and concatenated into the comment file first. The
heredoc body itself starts with the `**What shipped:**` line. Do
NOT add `## Review Summary` inside the heredoc — doing so would
emit the heading twice in the rendered comment.

### Action

Move the single `**Known gaps / deferred:** …` field line from its
current location (inside the QA Test Plan region of the heredoc) to
a new location (inside the Review Summary region of the heredoc),
between `**Surprises during implementation:** …` and
`**Documentation changes:** …`, with one blank line above and one
blank line below it.

This is naturally a remove-then-insert (or two `Edit` tool calls,
or one `Edit` whose `old_string` covers both regions). Use whichever
form is least likely to misfire on the actual file content at
implementation time.

**Anchors used to locate the regions:**

- *Insert site (Review Summary region):* the unique adjacency
  inside the heredoc where `**Surprises during implementation:** …`
  is followed by a blank line and then `**Documentation changes:** …`.
  Insert `**Known gaps / deferred:** <anything intentionally left
  unfinished; "None" if complete>` between them, surrounded by one
  blank line on each side, so the resulting sequence is field +
  blank + new field + blank + field.
- *Remove site (QA Test Plan region):* the unique location where
  `**Known gaps / deferred:** …` appears inside the QA Test Plan
  region of the heredoc. Remove that line and one of its adjacent
  blank lines (whichever is needed to keep the surrounding QA-section
  structure visually consistent — typically the blank line above
  the field).

**Field text to insert (verbatim, including the angle-bracket
placeholder text — this matches the surrounding fields' style):**

```
**Known gaps / deferred:** <anything intentionally left unfinished; "None" if complete>
```

**Do not touch unrelated content** in either region. If, at
implementation time, the QA Test Plan region or the Review Summary
region of the heredoc contains additional fields or template lines
not described here, preserve them exactly. This spec defines only
the placement of `**Known gaps / deferred:**`; everything else in
the heredoc is out of scope and must round-trip unchanged.

### Drift-handling rule

The spec rests on a few semantic invariants. If any of them no
longer holds at implementation time, stop and surface to the
operator instead of guessing:

- The file `skills/prepare-for-review/SKILL.md` exists and contains
  a heredoc identifiable by the field names listed above (the
  static template for the Linear handoff comment body). The
  heredoc's sentinel name is irrelevant — what matters is that the
  heredoc still exists and is the unique carrier of these fields.
  If the comment template has been refactored away from a heredoc
  entirely (e.g., into a separate template file or into a series
  of `printf` calls), stop — the conceptual change still applies
  but the mechanical instructions don't, so re-spec.
- A line matching `**Known gaps / deferred:**` is present at least
  once in the heredoc body, and its current location is inside the
  QA Test Plan region. If the field is absent (already moved or
  removed) or appears in some surprising location not covered by
  the anchors above, stop and inspect.
- The Review Summary region of the heredoc still contains both
  `**Surprises during implementation:**` and `**Documentation
  changes:**` as adjacent fields suitable for the insert. If
  Review Summary has been restructured such that this adjacency
  no longer exists, stop — the insert site is ambiguous.
- Step 5's "**Ambiguous findings**" bullet still semantically
  directs ambiguous findings to Review Summary (specifically to
  the Surprises or Known gaps field). Harmless copy edits to that
  bullet are fine. The drift case is when Step 5 has been changed
  to redirect ambiguous findings to QA Test Plan or some other
  section — i.e., the conceptual premise this spec rests on is
  gone. If you can read current Step 5 and confirm "ambiguous
  findings still go in Review Summary," proceed.

In any drift case, do not guess. Surface the situation and let a
human re-evaluate.

## What does NOT change

- **Step 5's "**Ambiguous findings**" bullet** keeps its semantic
  meaning — it must still direct ambiguous findings to Review
  Summary (where this ticket places the Known gaps field). Step 5's
  exact wording is not what this ticket changes; the template is.
  This spec does not require Step 5 to be byte-identical, only
  semantically intact.
- **The `printf '## Review Summary\n\n'` call** above the heredoc
  stays unchanged. The heading is emitted there, not inside the
  heredoc.
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

1. **Diff scope.** Confirm the diff is limited to the move of
   `**Known gaps / deferred:** …` from the QA Test Plan region to
   the Review Summary region, plus the surrounding blank-line
   adjustment needed to preserve the field-and-blank-line cadence
   at both sites. Any *other* lines in the heredoc — including any
   QA Test Plan content this ticket doesn't mention — must
   round-trip unchanged. Lines outside the heredoc (other skill
   sections, surrounding bash, etc.) must also be unchanged.
2. **Heredoc integrity.** Bash heredoc syntax requires three things
   only: the opener line intact (whatever sentinel name it uses),
   the closing terminator token on a line by itself with nothing
   else on it, and a newline immediately before the terminator.
   Internal blank lines inside the heredoc body are payload, not
   syntax — this spec intentionally rearranges some of them.
   Verification: confirm the heredoc's opener and terminator lines
   are both still present and structurally intact.
3. **`## Review Summary` heading source unchanged.** The heading is
   emitted by the `printf '## Review Summary\n\n'` line above the
   heredoc; that printf call must be byte-identical before and
   after.
4. **No duplicate field.** Grep the file for the literal string
   `**Known gaps / deferred:**` — exactly one match must remain.

   ```bash
   grep -c '\*\*Known gaps / deferred:\*\*' skills/prepare-for-review/SKILL.md
   # Must print: 1
   ```

5. **Field is in the Review Summary region.** Confirm the
   single match sits between `**Surprises during implementation:**`
   and `**Documentation changes:**` in the heredoc body.
6. **No QA Test Plan residue.** Confirm `**Known gaps / deferred:**`
   no longer appears anywhere inside the QA Test Plan region of the
   heredoc. Other QA fields that this ticket doesn't mention
   (whether they were already present or were added independently
   on another branch) should be left as-is.
7. **Step 5 semantic intent preserved.** The "**Ambiguous findings**"
   bullet must still direct ambiguous codex findings to Review
   Summary (specifically, into the Surprises during implementation
   or Known gaps / deferred field). Confirm by re-reading the bullet
   after the change. Byte-identical wording is not required —
   harmless copy edits are fine; what matters is that ambiguous
   findings are not redirected to QA Test Plan or anywhere else.

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

- The changes affect two non-contiguous regions inside the heredoc.
  Apply as either two separate `Edit` calls (one per region, using
  the multi-line anchors above) or one `Edit` whose `old_string`
  spans both regions including the intervening unchanged lines.
  Two smaller edits are more robust to minor surrounding-whitespace
  drift; one larger edit is simpler if the file matches the spec
  exactly.
- Expected diff size on the typical happy path is small (roughly
  one removed `**Known gaps / deferred:**` line + one removed blank
  line in QA Test Plan; one inserted `**Known gaps / deferred:**`
  line + the blank lines needed to surround it in Review Summary).
  Other lines in `SKILL.md` that this ticket does not address must
  round-trip unchanged.
- No code changes, no test changes, no companion-skill changes.

## Acceptance

The change is accepted when all of the following invariants hold;
nothing else about `SKILL.md` is constrained by this ticket:

1. `skills/prepare-for-review/SKILL.md` contains exactly one
   `**Known gaps / deferred:**` line.
2. That single line sits inside the heredoc body, between
   `**Surprises during implementation:**` and
   `**Documentation changes:**`, with one blank line above and one
   blank line below it.
3. `**Known gaps / deferred:**` is **not** present anywhere in the
   `## QA Test Plan` region of the heredoc. (The QA Test Plan
   region may continue to evolve independently — this ticket does
   not constrain whether other QA fields exist or are added.)
4. The `printf '## Review Summary\n\n'` call above the heredoc is
   byte-identical before and after — it remains the sole emitter
   of the `## Review Summary` heading.
5. The heredoc that carries the static template body still parses
   as valid bash heredoc syntax: opener on its own line, terminator
   on its own line. Sentinel name is unconstrained — whatever it
   was before the change, it remains the same after.
6. Step 5's "**Ambiguous findings**" bullet still semantically
   directs ambiguous findings to Review Summary (see verification
   step 7). It does not need to be byte-identical.
