# Session diagnostics composition: A + C + E (defer B and D)

## Context

ENG-308 set out to make autonomous-session failures diagnosable from
the operator's existing ritual (`/sr-status`, `progress.json`, the
worktree) without operators needing insider knowledge of where
Claude Code stores session transcripts. ENG-294 was the manifestation:
a session ended `exit_clean_no_review` after a nested-skill bug
([anthropics/claude-code#17351](https://github.com/anthropics/claude-code/issues/17351))
with `ralph-output.log` containing a single sentence. Diagnosing
required recognizing Claude Code's project-slug naming convention
(`/Users/me/repo` → `-Users-me-repo`), hand-finding the JSONL under
`~/.claude/projects/`, and grep'ing 600 KB of transcript.

The brainstorm enumerated five candidate approaches:

- **A — orchestrator capture:** pre-generate a UUID per dispatch, pass
  it to claude as `--session-id`, write `session_id` and
  `transcript_path` into `progress.json`.
- **B — auto-summarize via fast-claude:** run a separate fast model
  invocation per failed issue to summarize the JSONL into a one-line
  diagnostic.
- **C — inline diagnose pass:** a small bash helper that runs git/JSONL
  heuristics and emits a one-line `hint` field on the end record.
- **D — `/sr-diagnose <issue-id>` operator command:** a self-paced
  command for deeper inspection, pairs naturally with A.
- **E — status surface:** render the new fields under each non-success
  Done row in `/sr-status`.

For C, the four candidate heuristics:

- **H1 — no implementation commits** past `.sensible-ralph-base-sha`.
- **H2 — uncommitted edits left** in the worktree (excluding
  orchestrator-owned files).
- **H3 — context-loss after Skill** (the claude-code#17351 shape:
  `Skill` tool_use followed by a text-only assistant turn).
- **H4 — auto-mode refusal pattern.**

## Decision

Compose **A + C + E** and ship together. Defer B and D.

For C's heuristic catalog: **H1 + H2 + H3 in v1**, defer H4.

## Rationale

### Why A + C + E together

A alone gives operators a transcript pointer but no synthesis — they
still hand-grep 600 KB of JSONL, just from a path that's now printed
instead of inferred. E alone (without A) has nothing to render. C
alone (without A) can compute hints but the operator still can't reach
the rich session log.

The three are interlocking by design: A captures the path, C
synthesizes a one-line hint by reading both git state and the JSONL,
and E renders both as a sub-block under the failing row. Each piece
adds proportional value; shipping any subset leaves diagnosability
incomplete.

The A+C+E surface also degrades gracefully under field-presence gating
in E: a record without the new fields renders one-line (legacy
behavior), a record with `hint` only renders the arrow line and skips
the path lines, etc. Old `progress.json` consumers continue working;
no migration is needed.

### Why defer B (auto-summarize via fast-claude)

B is the most ambitious option — it would invoke a separate fast-model
claude per failed dispatch to read the JSONL and produce a natural-
language summary. Worth defering until A+C+E is observed in
operation: if the inline hint + transcript pointer prove sufficient
for the failure modes operators actually encounter, B's per-failure
fast-claude invocation is cost without payoff. If the rule-based
hints turn out to under-report or miss novel failure shapes, B
becomes a high-value follow-up. The decision to skip B is not "B is
bad" but "let's see if we need it."

### Why defer D (`/sr-diagnose <issue-id>`)

D pairs naturally with A — once `transcript_path` is in
`progress.json`, an operator command that reads it and runs deeper
analysis (e.g., full-transcript diff vs. successful runs, annotated
tool-use timeline) is a logical next step. Deferred because A+C+E's
inline hint is the **passive** surface (always visible during the
operator's existing `/sr-status` glance), while D would be an
**active** escape hatch (operator decides to dig deeper). The passive
surface is a strict prerequisite; active becomes valuable once the
passive one's gaps are observed.

### Why H1 + H2 + H3, defer H4

H1 (no commits past base) catches the most common pathology: the
session reached `/prepare-for-review` invocation but never produced
any implementation work. Cheap to compute (one `git rev-list --count`).

H2 (dirty tree) catches the inverse: the session did work but exited
without committing, so the work is recoverable but not yet captured.
Also cheap (one `git status --porcelain`).

H3 (post-Skill context loss) catches the specific manifestation that
motivated the entire issue: ENG-294's claude-code#17351 nested-skill
bug. Reading the JSONL is more expensive than git but still bounded
(2 s self-cap, 5 s outer timeout); the heuristic looks at the last 5
assistant events and applies a defensive-parsing posture that
silently suppresses on missing/malformed/schema-changed input rather
than emitting wrong hints.

H4 (auto-mode refusal pattern) was deferred because parsing the
auto-mode permission-denial JSONL shape requires deeper coupling to
claude-code's undocumented internal format than H1–H3. H1 reads
public git plumbing; H2 reads public git plumbing; H3 reads the JSONL
schema only enough to extract assistant-turn tool_use names. H4 would
need to recognize the specific structure of permission-denial
tool_results, which is more fragile. Becomes a candidate follow-up
issue if operators routinely encounter auto-mode refusals that
H1–H3's hints don't characterize.

## JSONL defensive-parsing posture

The JSONL schema is undocumented internal format. Future Claude Code
releases may change it without notice. The design choice for
JSONL-dependent heuristics (only H3 today) is **under-report rather
than mis-report:**

- Missing JSONL after the bounded poll → silent suppression.
- Unreadable file → silent suppression.
- Any `jq` access error → silent suppression.

H3 stops firing if the schema changes; it never emits a hint that's
wrong because the parsing landed on a shifted field. The trade-off is
explicit: operators see "no hint" rather than "wrong hint." The
worktree-log path and the H1/H2 git heuristics are independent of
JSONL schema, so the diagnostic surface degrades gracefully — the
sub-block stays useful even if the JSONL becomes unparseable.

The same posture applies to the slug rule: the
`<config_dir>/projects/<slug>/<session_id>.jsonl` path is empirically
observed for Claude Code 2.x and not a documented public contract. A
future change to the slug-encoding rule would silently break the
printed `session:` line and H3 (which reads the same computed path).
Both fail safe — H3 suppresses without emitting wrong hints, the
printed path simply points at a missing file (operator-actionable
information) rather than the wrong file. The orchestrator does not
validate the JSONL exists at write time; the renderer does not
validate at render time.

A future ENG-N follow-up could harden either surface by reading the
actual session path via `--output-format stream-json` (one extra
parse step per dispatch); deferred pending observed need.

## Out of scope

- **B (auto-summarize via fast-claude).** Becomes a follow-up issue if
  A+C+E is observed insufficient.
- **D (`/sr-diagnose` operator command).** Pairs with A; becomes a
  follow-up if the passive inline surface proves insufficient.
- **H4 (auto-mode refusal heuristic).** Higher coupling to claude-code
  internals than H1–H3; deferred pending observed need.
- **Backfilling diagnostic fields into legacy records.** Old records
  lack the fields; the renderer omits the missing pieces and the row
  degrades to today's behavior.

## See also

- `docs/specs/surface-session-diagnostics.md` — the implementation
  spec.
- `docs/design/orchestrator.md` — `--session-id`, the diagnose-call
  invocation, and the `progress.json` schema additions.
- `docs/design/outcome-model.md` — operator-triage column references
  the inline hint and transcript path.
- ENG-294 — the manifestation that motivated this work.
- ENG-307 — mitigates the most common cause of the cryptic-exit
  shape; complementary, not blocking.
