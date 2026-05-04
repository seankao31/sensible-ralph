# Embed run_id header in ordered_queue.txt

**Linear:** ENG-287

## Problem

`/sr-start` rewrites `.sensible-ralph/ordered_queue.txt` for a new run in
step 2, then invokes the orchestrator in step 4. The orchestrator
generates `run_id` internally (`orchestrator.sh:150`,
`run_id="$(date -u +%Y-%m-%dT%H:%M:%SZ)"`) and writes it into every
`progress.json` record as it dispatches each issue.

Between the queue-file rewrite (step 2) and the orchestrator's first
`_progress_append` call (writes the first `start` record with the new
`run_id`), there is a window — typically seconds, but real — where:

- `ordered_queue.txt` reflects the new run (issue list).
- `progress.json` still only contains records from the previous run.

`render_status.sh:46–52` derives `latest_run_id` by chronological sort
over `progress.json`. During the window, that sort returns the
*previous* run's `run_id`. The renderer then partitions the new queue
file's issues against the previous run's records — operator sees a
status table that mixes the new queue with stale completion data, and
the footer reports `Run started: <previous-run-id>`.

The window self-corrects the moment the orchestrator writes its first
record, so the bug is invisible if the operator only inspects
`/sr-status` after the run is well underway. It surfaces when an
operator runs `/sr-status` immediately after `/sr-start` accepts
dispatch — a usage pattern that becomes routine if the autonomous
queue is part of the daily flow.

## Solution

Move `run_id` generation upstream from the orchestrator into
`build_queue.sh`, which writes a `# run_id: <iso8601>` header line at
the top of `ordered_queue.txt`. The orchestrator and `/sr-status` both
read `run_id` from that header rather than generating or deriving it
locally. The queue file becomes the single source of truth for "what
is the current run".

The race closes because `ordered_queue.txt` and the new `run_id`
become visible atomically — at the moment `build_queue.sh`'s output
finishes redirecting into the file. There is no longer a window where
the new queue is visible but the new `run_id` is not.

## Design

### Header format

First line of `.sensible-ralph/ordered_queue.txt`:

```
# run_id: 2026-05-04T12:34:56Z
ENG-287
ENG-288
```

- Literal prefix `# run_id: ` (hash, space, label, colon, space).
  Comment-style so the file remains greppable for issue IDs without a
  strip step (any line starting with `#` after whitespace-trim is
  metadata).
- Value is `date -u +%Y-%m-%dT%H:%M:%SZ` — matches the format the
  orchestrator currently generates. The string flows through to
  `progress.json` records untouched, preserving the existing
  `run_id` shape and the `fromdateiso8601`-sortability that
  `progress.json`-derived consumers may rely on.
- Exactly one header line, at line 1. No support for additional
  metadata lines in this spec — extensible later if needed.

### Writer

`skills/sr-start/scripts/build_queue.sh` generates `run_id` and emits
the header as the first line of stdout, before any issue IDs.

- The `/sr-start` step 2 invocation
  (`build_queue.sh > "$sr_root/ordered_queue.txt"`) is unchanged. The
  redirect captures both header and issue IDs in one atomic write.
- **Empty-queue case** (no pickup-ready Approved issues): unchanged
  from today — emit nothing, exit 0. Do **not** emit a header for an
  empty queue. A queue file with a header but no issues would falsely
  register as a new run in `/sr-status` even though the orchestrator
  was never invoked.
- The `run_id` generation line: `run_id="$(date -u +%Y-%m-%dT%H:%M:%SZ)"`,
  identical to the line currently in `orchestrator.sh:150`.
- Header is emitted only after `build_queue.sh` confirms a non-empty
  queue. The current control flow already exits 0 early when
  `approved_ids` or `toposort_input` is empty (`build_queue.sh:55–56`,
  `:117`); the header emission belongs at the point where issue IDs
  start being printed (i.e., immediately before the final
  `toposort.sh < "$toposort_input"` invocation on line 119).

### Readers

**`skills/sr-start/scripts/orchestrator.sh`:**

- Replace the unconditional generation at `orchestrator.sh:150` with a
  read of the queue file's first line:
  - If the first line matches `^# run_id: (.+)$`, set `run_id` to the
    captured value.
  - Otherwise, error to stderr and exit non-zero. No fallback.
- The error message should name the missing header explicitly:
  `orchestrator: ordered_queue.txt missing '# run_id: <id>' header line — was the queue file written by build_queue.sh?`
- The existing queue-loading loop (`orchestrator.sh:138–141`) reads
  every non-empty line into `queued_ids`. Add a `#`-comment skip:
  any line where the whitespace-trimmed value starts with `#` is
  dropped. This skips the header during issue-list construction.
  (Same pattern any other commented metadata would use; future-proofs
  the file format.)

**`skills/sr-status/scripts/render_status.sh`:**

- Restructure the early-exit logic at `render_status.sh:38–52`:
  1. If `$queue_file` does not exist, print the existing
     `_no_runs_message` and exit 0. (The legitimate fresh-repo path —
     no `/sr-start` has ever been invoked.)
  2. Otherwise, read the queue file's first line. If it matches
     `^# run_id: (.+)$`, set `latest_run_id` to the captured value.
  3. If the queue file exists but has no valid header line, error to
     stderr and exit non-zero. Mirror the orchestrator's error
     message: `sr-status: ordered_queue.txt missing '# run_id: <id>' header line — re-run /sr-start to regenerate.`
- **Delete** the chronological-sort derivation block currently at
  `render_status.sh:46–52` (the
  `[.[].run_id] | unique | map(select(. != null)) | sort_by(fromdateiso8601) | last`
  jq pipeline). Without a fallback path, that block is unreachable.
- The downstream queue-file read at `render_status.sh:104–110` (the
  while-loop building `queued_issues`) needs the same `#`-comment
  skip so the header line doesn't show up as a queued issue ID.
- The existing "no progress.json" early-exit (`render_status.sh:38–41`)
  is folded into the restructured logic above. If the queue header
  yields a `run_id` but `progress.json` is missing or has no records
  for that `run_id`, the renderer naturally produces empty Done /
  empty Running / full Queued — which is the exact race-fix
  rendering. (Today, the early-exit short-circuits this case to "no
  runs recorded" because the derivation has nothing to find.)

### Backwards-compat

None. The header is required. There is no production use of an older
plugin version that would have written a header-less queue file. The
fail-loud branches above (orchestrator and renderer) are correct
strict-contract enforcement, not deprecation paths.

## File-by-file changes

1. **`skills/sr-start/scripts/build_queue.sh`** — generate `run_id` and
   emit the header line immediately before the `toposort.sh` invocation
   on line 119. ~3 lines added.

2. **`skills/sr-start/scripts/orchestrator.sh`** — replace the
   generation line (currently line 150) with a header read + non-zero
   exit on missing header. Add a `#`-comment skip in the queue-load
   loop (currently lines 138–141). ~10 lines net.

3. **`skills/sr-status/scripts/render_status.sh`** — restructure
   the early-exit logic at lines 38–52 to read the queue header,
   delete the `progress.json` derivation block, exit non-zero on
   missing header. Add `#`-comment skip in the `queued_issues` loop
   (lines 104–110). ~15 lines net.

4. **`skills/sr-start/SKILL.md`** — step 2 description grows one
   sentence noting the queue file's first line is the `# run_id:`
   header.

5. **`docs/design/orchestrator.md`** — the `progress.json` schema
   section currently states `run_id` is generated by the
   orchestrator. Update to note `run_id` originates from the queue
   header.

6. **`docs/decisions/run-id-from-queue-header.md`** — new file
   capturing this decision and the race it closes. (Per the
   `docs/decisions/` convention in `CLAUDE.md`: kebab-case topic, no
   date prefix, atomic single-decision file.)

7. **`docs/specs/embed-run-id-in-queue-header.md`** — this spec
   itself, frozen on completion.

## Test plan

### `skills/sr-start/scripts/test/build_queue.bats`

- **New:** "queue with approved issues emits `# run_id: <iso8601>` as
  first line" — set up a single approved issue with no blockers, run
  `build_queue.sh`, assert first output line matches
  `^# run_id: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$`,
  assert remaining lines are issue IDs.
- **Existing:** "no approved issues outputs nothing and exits 0"
  (line 77) stays as-is — empty queue still emits nothing, no header.

### `skills/sr-start/scripts/test/orchestrator.bats`

- **Helper sweep:** the `write_queue` helper (used throughout) prepends
  `# run_id: <fixture-id>` to the file. Fixture id is a known fixed
  value (e.g., `2026-01-01T00:00:00Z`) so tests can assert specific
  values flow through. One-line change to the helper.
- **New:** "orchestrator uses queue header `run_id` for all
  `progress.json` records" — write a queue with header
  `2026-01-01T00:00:00Z`, dispatch one issue, assert every record in
  `progress.json` has `run_id == "2026-01-01T00:00:00Z"`.
- **New:** "orchestrator with header-less queue file: errors and
  exits non-zero" — write a queue file with no header, run
  orchestrator, assert non-zero status, assert stderr contains
  `missing '# run_id: <id>' header line`.
- **Update:** "two consecutive runs produce distinct run_ids" (line
  1417) — each run's `write_queue` invocation gets a different
  fixture id (e.g., the existing `sleep 1` between runs is replaced
  by passing two distinct ids). Assert both ids appear, distinct.

### `skills/sr-status/scripts/test/render_status.bats`

- **Helper sweep:** the `write_queue` helper (line 44) takes an
  optional `run_id` argument and prepends `# run_id: <run_id>` to
  the file. Existing call sites pass an explicit id.
- **New (the regression test for ENG-287):** "queue header `run_id`
  takes precedence; new run with no progress.json records yet
  renders empty Done/Running and full Queued" — write
  `progress.json` with records under `run_id` `OLD`, write queue
  with header `NEW` and three issue IDs, run renderer, assert:
  `Run started: NEW`, `=== Done (0) ===`, `=== Running (0) ===`,
  `=== Queued (3) ===` listing the issues from the queue. (No
  records from `OLD` should appear anywhere.)
- **New:** "queue file exists but no header: error and exit non-zero"
  — write queue file with no header, assert non-zero status, assert
  stderr contains `missing '# run_id: <id>' header line`.
- **Existing:** "no progress.json: friendly hint" (line 54) — keep,
  but verify it still passes given the restructured early-exit
  logic. The fixture has no queue file either, so the new
  "queue-file-missing → no runs message" path applies.
- **Delete:** "two run_ids in progress.json: chronologically-latest
  selected via fromdateiso8601" (line 169) — obsolete. Without the
  derivation path, that selection logic doesn't exist.
- **Delete:** "run_ids out of insertion order: chronologically-latest
  selected via fromdateiso8601" (line 240) — same reason.
- **Delete:** "legacy records (no event field) coexist with new
  records: legacy filtered out by run_id selection" (line 190) —
  partially obsolete. The renderer now selects records by header
  `run_id` rather than by chronologically-latest derivation. If the
  intent of the legacy-filtering coverage is preserved by the new
  precedence test (records under `OLD` don't appear when header
  selects `NEW`), this test can be deleted. If the operator wants
  the legacy coverage retained, restate it as: "records from older
  `run_id`s in `progress.json` are not rendered when the queue
  header selects a different `run_id`."

### Acceptance-criteria mapping

The original Linear description listed four acceptance criteria. Three
map directly; the fourth is superseded by this spec.

| Original criterion | Status | Covered by |
| --- | --- | --- |
| `/sr-start` writes `# run_id: <id>` as first line of `ordered_queue.txt` | Met | `build_queue.bats` new "header first line" test |
| `/sr-status` reads `run_id` from header instead of deriving from `progress.json` | Met | `render_status.bats` precedence test |
| Fall back to current derivation if header absent | **Superseded** | This spec drops the fallback; `/sr-status` errors loud on missing header. See "Backwards-compat" above for rationale (no existing users to compat for). |
| Tests cover both paths | Met (revised) | New tests above cover header-present and header-missing-error in both the orchestrator and renderer |

## Failure modes

- **Race during the queue-file write.** The redirect
  `build_queue.sh > "$sr_root/ordered_queue.txt"` is not atomic on
  POSIX — the file is opened/truncated on `>` and written
  incrementally. A `/sr-status` invocation that reads the file
  mid-write could see a partial header, no header, or a partial issue
  list. Today's race window is closed; this micro-window opens. In
  practice the file is small (~tens of lines) and writes complete in
  microseconds, but the race is technically present. **Mitigation:**
  none in this spec — declared out of scope as immeasurably narrow.
  If observed, follow-up by writing to a tempfile + `mv` (the same
  pattern `_progress_append` uses).

- **Operator hand-edits `ordered_queue.txt`.** If an operator opens
  the queue file and edits issue IDs without preserving the header,
  the orchestrator and renderer both error loud on the next
  invocation. The error message points at re-running `/sr-start` to
  regenerate. Acceptable failure mode — operator gets clear guidance.

- **Direct `orchestrator.sh` invocation outside `/sr-start`** (e.g.,
  ad-hoc debugging with a hand-written queue file). The strict
  contract requires the operator to write a header line. Trivial in
  practice (one `printf` before the issue IDs); error message is
  explicit.

- **Concurrent `/sr-start` invocations.** Already documented as
  unsupported (`orchestrator.sh:109–111`). The single-source-of-truth
  design here inherits the same limitation: two parallel `/sr-start`
  runs would race the queue file write. Not a new failure mode.

## Out of scope

- Changes to the `progress.json` record schema. The `run_id` field on
  records remains exactly as-is.
- Tooling for cross-run analytics derived from `run_id`. Records can
  still be grouped by `run_id` from `progress.json` if such tooling
  is built later.
- Any operator-facing "force regenerate `run_id`" flag. Rerunning
  `/sr-start` rewrites the queue file with a fresh `run_id`.
- Pruning or rotating `ordered_queue.txt` history. The file is
  overwritten on each `/sr-start`, no retention concept.
- Atomic queue-file writes via tempfile + rename. Documented as a
  follow-up under Failure modes.
- Concurrent `/sr-start` support. Inherited limitation, not addressed.

## Prerequisites

None. ENG-241 (added `/sr-status` and the `progress.json` event
discriminator) is already shipped and provides the surface this change
modifies. No `blocked-by` relations to set on this issue.
