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
that builds the handoff comment body. The heredoc begins with the
opener `<<'COMMENT'` and ends with a `COMMENT` marker on its own
line. Currently, the heredoc is wrapped by surrounding code that
looks like this (line numbers approximate):

```bash
# Heading
printf '## Review Summary\n\n' > "$COMMENT_FILE"

# Static body — quoted heredoc keeps backticks (and $) literal
cat >> "$COMMENT_FILE" <<'COMMENT'
**What shipped:** ...
...
COMMENT
```

**Important:** the literal heredoc body does NOT begin with
`## Review Summary`. That heading is emitted by the `printf` call
**above** the heredoc and is concatenated into the comment file before
the heredoc contents. The heredoc body itself starts with the
`**What shipped:**` line. Do NOT add `## Review Summary` inside the
heredoc; doing so would emit the heading twice in the rendered
comment.

### Edits to apply

Two changes inside the heredoc body. Apply them as either two
separate `Edit` tool calls or one `Edit` call whose `old_string`
spans both regions.

**Edit 1 — insert the field into Review Summary.** Find the unique
anchor where "Surprises during implementation:" is immediately
followed by a blank line and then "Documentation changes:". Insert
the `**Known gaps / deferred:**` field between them, with one blank
line above and one blank line below it. Concretely, the lines that
currently read:

```
**Surprises during implementation:** <bulleted list of things the PRD didn't anticipate; "None" if clean>

**Documentation changes:** <bulleted list of decisions captured and docs pruned this session; "None" if nothing>
```

become:

```
**Surprises during implementation:** <bulleted list of things the PRD didn't anticipate; "None" if clean>

**Known gaps / deferred:** <anything intentionally left unfinished; "None" if complete>

**Documentation changes:** <bulleted list of decisions captured and docs pruned this session; "None" if nothing>
```

**Edit 2 — remove the field (and its preceding blank line) from QA
Test Plan.** Find the unique anchor where "Edge cases worth
checking:" is followed by a blank line and then the
`**Known gaps / deferred:**` field, which is then followed by the
`COMMENT` heredoc terminator on its own line. The block that
currently reads:

```
**Edge cases worth checking:** <bulleted list of risky paths — what was tricky to get right, what boundary conditions exist>

**Known gaps / deferred:** <anything intentionally left unfinished; "None" if complete>
COMMENT
```

becomes:

```
**Edge cases worth checking:** <bulleted list of risky paths — what was tricky to get right, what boundary conditions exist>
COMMENT
```

(The blank line between "Edge cases worth checking" and the removed
field is also removed, so the `COMMENT` terminator now follows the
"Edge cases" line with exactly one newline. This matches the
heredoc's existing trailing-line pattern and keeps the bash heredoc
syntax intact.)

### After-state, exact heredoc body

After both edits, the literal contents *between* the `<<'COMMENT'`
opener and the `COMMENT` terminator must be exactly:

```
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

The `## QA Test Plan` heading stays inside the heredoc body (it was
already there). The `## Review Summary` heading remains in the
preceding `printf` call above the heredoc and is **not** part of the
heredoc body.

The `**Documentation changes**` field's bullet examples
(`- Decision: ...`, `- Pruned: ...`) stay attached directly under
that field — do not separate them from their parent field by the
inserted Known gaps entry.

### Drift-handling rule

This spec assumes the source layout described above. If, between
spec-time and implementation, `SKILL.md` has drifted in any of the
following ways, **stop and surface to the operator instead of
forcing a literal block replacement**:

- The heredoc opener (`<<'COMMENT'`) or its closing `COMMENT`
  marker is no longer present, has been renamed (e.g., to
  `<<'BODY'`), or the comment-template construction has been
  refactored away from a single heredoc.
- The string `**Known gaps / deferred:**` appears more than once
  in the file, or appears zero times (the field has already been
  moved or removed).
- The Edit-1 anchor — the contiguous "Surprises during
  implementation" → blank line → "Documentation changes" pattern
  — does not match exactly once inside the heredoc body.
- The Edit-2 anchor — the contiguous "Edge cases worth checking"
  → blank line → `**Known gaps / deferred:**` → `COMMENT`
  terminator pattern — does not match exactly once.
- Step 5's "**Ambiguous findings**" bullet no longer semantically
  designates Review Summary as the home for ambiguous findings /
  Known gaps. Harmless copy edits to that bullet (typos,
  punctuation, clarifications that still point at Review Summary)
  are fine and do not block. The drift case is specifically when
  Step 5 has been changed to redirect ambiguous findings to QA Test
  Plan or some other section — i.e., when the conceptual premise
  this spec rests on no longer holds. If you can read the current
  Step 5 and confirm "ambiguous findings still go in Review
  Summary," proceed; otherwise stop and re-spec.

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

1. **Diff inspection.** Confirm the only changes are: removing the
   `**Known gaps / deferred:**` line (and one preceding blank line)
   from the QA Test Plan region of the heredoc, and inserting the
   same line (with one blank line above and one below) into the
   Review Summary region of the heredoc. No other characters change.
2. **Heredoc integrity.** Bash heredoc syntax requires exactly:
   the opener (`<<'COMMENT'`) intact, the closing `COMMENT` token
   on a line by itself with nothing else on it, and a newline
   immediately before the terminator. Internal blank lines inside
   the heredoc body are payload, not syntax — this spec
   intentionally changes some of them. Verification: confirm the
   opener and the bare-`COMMENT` terminator line are both present
   and unchanged.
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
6. **No QA Test Plan residue.** Confirm `## QA Test Plan` no longer
   contains the Known gaps line by visually inspecting the section.
   After the change it should contain only `**Golden path:**` and
   `**Edge cases worth checking:**`.
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
- Net diff size: ~4 lines added, ~2 lines removed (one
  `**Known gaps / deferred:**` line + one blank line removed from
  QA Test Plan; one `**Known gaps / deferred:**` line + two blank
  lines added in Review Summary surrounding it). No other lines in
  the file change.
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
5. The heredoc opener (`<<'COMMENT'`) and its closing `COMMENT`
   marker are intact and on their own lines, satisfying bash
   heredoc syntax.
6. Step 5's "**Ambiguous findings**" bullet still semantically
   directs ambiguous findings to Review Summary (see verification
   step 7). It does not need to be byte-identical.
