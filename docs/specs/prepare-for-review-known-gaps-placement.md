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

### Idempotency check (run first)

Before any edit, check whether the acceptance criteria already
hold:

1. The file contains exactly one `**Known gaps / deferred:**` line.
2. That line is in the Review Summary region of the heredoc, after
   `**Surprises during implementation:**`.
3. No `**Known gaps / deferred:**` line is present in the QA Test
   Plan region of the heredoc.

If all three hold, the work is already done. Declare success and
make no edits — this is the intended end state, regardless of how
the file got there (rebase, cherry-pick, prior partial run, manual
edit). Do not stop or re-spec.

### Drift-handling rule

If the idempotency check did not short-circuit, attempt the change.
Stop and surface to the operator only when the change cannot be done
safely:

- **No matching file.** `skills/prepare-for-review/SKILL.md` is
  missing.
- **No identifiable heredoc.** No bash heredoc in the file carries
  the static template body (the one whose body contains the
  `**What shipped:**`, `**Surprises during implementation:**`,
  `**Documentation changes:**` fields and the `## QA Test Plan`
  heading). If the template has been refactored away from a
  heredoc, the mechanical instructions don't apply — re-spec.
- **Source field not findable.** No `**Known gaps / deferred:**`
  line exists in the QA Test Plan region of the heredoc, AND the
  idempotency check did not short-circuit. Either the field is
  somewhere unexpected (not covered by the spec) or the file has
  been hand-edited into a partial state — inspect.
- **Insert site ambiguous or missing.** `**Surprises during
  implementation:**` is not present in the heredoc, OR there is
  no clear position "after Surprises and before Documentation
  changes" (e.g., `**Documentation changes:**` is missing, or
  multiple instances of either anchor exist). If new fields have
  been added in Review Summary between Surprises and Docs, insert
  Known gaps immediately after Surprises (preserving the
  newly-added intervening fields after it) — that's still
  consistent with "after Surprises" placement; do not stop.

The Step 5 "**Ambiguous findings**" bullet is **not** a drift gate.
Read it as an alignment cross-reference: it should still point at
Review Summary as the home for ambiguous findings, but if it has
been edited in a way that contradicts that, file a follow-up issue
and proceed with this ticket. The Step 5 prose is conceptually
related to this change but operationally independent — fixing it is
out of scope here.

In any drift case above, do not guess. Surface the situation and
let a human re-evaluate.

## What this ticket does NOT touch

- **Step 5's "**Ambiguous findings**" bullet.** This ticket does not
  edit Step 5. (Step 5 should be re-read after the change for
  alignment — it should still direct ambiguous findings to Review
  Summary — but if it doesn't, file a follow-up issue rather than
  expanding scope here.)
- **The `printf '## Review Summary\n\n'` call** above the heredoc.
  The Review Summary heading is emitted there, not inside the
  heredoc; this ticket does not modify that line.
- **Other sections of `SKILL.md`** outside the heredoc body. No
  field renames, no reordering of unrelated fields, no new sections.
- **Frozen specs in `docs/specs/`** that reference "Known gaps /
  deferred" by name (e.g., `stale-parent-pre-merge-sha.md`). They
  reference the field by name, not by section placement, so they
  remain accurate after this change.
- **Stale copies of `SKILL.md` in `.worktrees/eng-*/`.** Each
  worktree's branch will receive the updated content through normal
  rebase/merge with main when next worked on.
- **Posted Linear comments** from prior `/prepare-for-review` runs.
  The template is consumed at write-time; existing comments in
  Linear are immutable history and don't matter.

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

5. **Field is in the Review Summary region.** Confirm the single
   match sits inside the heredoc body, in the Review Summary region
   (i.e., before the `## QA Test Plan` heading), and immediately
   after `**Surprises during implementation:** …` (one blank line
   between them). On the typical happy path it will also be
   immediately followed by `**Documentation changes:** …`; if
   independent template work has added new fields between Surprises
   and Documentation changes, the new Known gaps line should sit
   immediately after Surprises and before whatever those new fields
   are. Either layout is acceptable.
6. **No QA Test Plan residue.** Confirm `**Known gaps / deferred:**`
   no longer appears anywhere inside the QA Test Plan region of the
   heredoc.
7. **Step 5 alignment (informational).** Re-read Step 5's
   "**Ambiguous findings**" bullet. It should still direct ambiguous
   findings to Review Summary. If it does not, that is a separate
   follow-up issue, not a blocker for this ticket.

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
2. That single line sits inside the heredoc body, in the Review
   Summary region (before the `## QA Test Plan` heading),
   immediately after `**Surprises during implementation:**` (with
   one blank line between them).
3. `**Known gaps / deferred:**` is **not** present anywhere in the
   QA Test Plan region of the heredoc. (The QA Test Plan region
   may continue to evolve independently — this ticket does not
   constrain whether other QA fields exist or are added.)
4. The `printf '## Review Summary\n\n'` call above the heredoc is
   byte-identical before and after.
5. The heredoc that carries the static template body still parses
   as valid bash heredoc syntax: opener on its own line, terminator
   on its own line. Sentinel name is unconstrained.
6. Step 5's "**Ambiguous findings**" bullet is not edited by this
   ticket. (Verification step 7 checks for alignment with the new
   placement, but a misalignment does not fail acceptance — it
   becomes a follow-up issue.)
