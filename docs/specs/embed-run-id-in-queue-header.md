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
become visible atomically — at the moment `build_queue.sh`'s
tempfile + same-directory `mv` publishes the new file (POSIX
guarantees same-filesystem rename atomicity). There is no longer a
window where the new queue is visible but the new `run_id` is not,
nor a window where readers see a partial file.

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

`skills/sr-start/scripts/build_queue.sh` generates `run_id`, builds the
full queue contents (header + issue IDs), and atomically publishes the
result to a destination path passed as `$1`. **Interface change:** the
script no longer streams to stdout; it takes an output path argument.

- New invocation, replacing the redirect-based form in
  `skills/sr-start/SKILL.md` step 2:
  ```bash
  "$SKILL_DIR/scripts/build_queue.sh" "$sr_root/ordered_queue.txt"
  ```
- **Atomic publish.** `build_queue.sh` writes its output to a tempfile
  in the same directory as the destination path
  (`mktemp "${dest}.XXXXXX"`), then `mv`s the tempfile to the
  destination on success. Same-filesystem rename is atomic on POSIX —
  readers of `ordered_queue.txt` either see the prior published file
  (fully formed) or the new one (fully formed), never a partial mix.
  This pattern matches `_progress_append`'s tempfile + `mv` approach
  in `orchestrator.sh:117–123`.
- **Failure handling.** If any step in queue construction fails
  (`linear_list_approved_issues`, `toposort.sh`, blocker fetches),
  `build_queue.sh` removes the tempfile and exits non-zero. The
  destination file is left untouched. This means a failed `/sr-start`
  cannot publish a bogus "current run" — the prior queue file (if
  any) remains the authoritative current state. Closes finding 2
  from the codex adversarial review.
- **Empty-queue case** (no pickup-ready Approved issues): the script
  removes its tempfile, exits 0, and **does not touch the
  destination file**. Existing `ordered_queue.txt` from a prior
  /sr-start (if any) remains in place. `/sr-status` continues to show
  the most recent ACTUAL run. Rationale: an empty queue means "no
  new dispatch happened"; preserving the prior file means /sr-status
  doesn't lose visibility into the last completed run.
- The `run_id` generation line: `run_id="$(date -u +%Y-%m-%dT%H:%M:%SZ)"`,
  identical to the line currently in `orchestrator.sh:150`. Format
  flows through to `progress.json` records untouched. Second-
  resolution collision behavior is documented under Failure modes
  below — inherits from today's orchestrator.
- The header is the first line of the tempfile; issue IDs follow.
  Order: header → toposort.sh output. The script exits non-zero before
  the `mv` if `toposort.sh` fails, so a partial issue list is never
  published.

### Caller (`/sr-start` SKILL.md step 2)

The full step 2 snippet under the new design:

```bash
sr_root="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.sensible-ralph"
mkdir -p "$sr_root"
"$SKILL_DIR/scripts/build_queue.sh" "$sr_root/ordered_queue.txt"
```

If `build_queue.sh` exits non-zero, `set -e` (or a manual exit-status
check, depending on the surrounding skill harness) halts dispatch.
The destination file's prior state is preserved.

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

**Operator-facing upgrade behavior.** A repo that has a header-less
`.sensible-ralph/ordered_queue.txt` left over from a prior plugin
version will have `/sr-status` exit non-zero with the missing-header
error message until the next `/sr-start` runs. The next `/sr-start`'s
atomic publish writes a header-bearing file, restoring `/sr-status`.
Operators who want immediate restoration without dispatching can
either (a) `rm .sensible-ralph/ordered_queue.txt` to fall into the
"no current run" path, or (b) re-run `/sr-start` to regenerate. Both
are one-step recoveries. This trade-off is explicitly accepted —
weighing one-time post-upgrade friction against indefinite
dead-code maintenance of a fallback path. Documented per codex
finding 4.

## File-by-file changes

1. **`skills/sr-start/scripts/build_queue.sh`** — interface change:
   take output path as `$1`. Generate `run_id`. Build full queue
   contents (header + issue IDs from `toposort.sh`) into a tempfile in
   the destination's directory. On success, `mv` the tempfile to the
   destination. On `toposort.sh` failure or any other error, remove
   the tempfile and exit non-zero (destination unchanged). On empty
   queue, remove the tempfile, exit 0, and leave the destination
   untouched. The current control-flow early-exits at
   `build_queue.sh:55–56` and `:117` already handle the empty case;
   they need adjustment to clean up the tempfile (instead of just
   exiting). ~25 lines net.

2. **`skills/sr-start/scripts/orchestrator.sh`** — replace the
   generation line (currently line 150) with a header read + non-zero
   exit on missing header. Add a `#`-comment skip in the queue-load
   loop (currently lines 138–141). ~10 lines net.

3. **`skills/sr-status/scripts/render_status.sh`** — restructure
   the early-exit logic at lines 38–52 to read the queue header,
   delete the `progress.json` derivation block, exit non-zero on
   missing header. Add `#`-comment skip in the `queued_issues` loop
   (lines 104–110). ~15 lines net.

4. **`skills/sr-start/SKILL.md`** — step 2 invocation changes from
   `build_queue.sh > "$sr_root/ordered_queue.txt"` to
   `build_queue.sh "$sr_root/ordered_queue.txt"` (positional arg, no
   redirect). One sentence noting the queue file's first line is the
   `# run_id:` header. One sentence noting that the script publishes
   atomically and leaves the destination intact on failure or empty
   queue.

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

- **Helper sweep (interface change):** every existing test that
  invokes `bash "$STUB_PLUGIN_ROOT/skills/sr-start/scripts/build_queue.sh"`
  and asserts on `$output` (stdout) becomes a test that passes a
  destination path and asserts on file contents. ~10 tests touched,
  mechanical conversion. Add a per-test `local out_path; out_path="$(mktemp)"`
  setup line and replace `[ "$output" = "..." ]` assertions with
  `[ "$(cat "$out_path")" = "..." ]` (or substring/regex matches as
  appropriate).
- **New:** "queue with approved issues writes `# run_id: <iso8601>`
  as first line" — set up a single approved issue with no blockers,
  invoke with a destination path, assert first line of output file
  matches `^# run_id: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$`,
  remaining lines are issue IDs.
- **New (atomicity guarantee):** "build_queue.sh with failing
  toposort.sh leaves the destination file unchanged" — pre-populate
  the destination with a known sentinel content (e.g.,
  `# run_id: SENTINEL\nENG-OLD\n`), set up an issue graph that
  triggers a toposort cycle (or stub `toposort.sh` to exit non-zero),
  invoke `build_queue.sh`, assert non-zero exit, assert destination
  contents are byte-identical to the sentinel. Closes finding 2 from
  the codex adversarial review.
- **New (empty-queue preservation):** "build_queue.sh with empty
  approved set leaves the destination file unchanged" — pre-populate
  the destination with sentinel content, set
  `STUB_APPROVED_IDS=""`, invoke `build_queue.sh`, assert exit 0,
  assert destination contents byte-identical to the sentinel. Also
  assert no tempfile lingers in the destination directory after the
  run (mirrors `orchestrator.bats` test 23 atomicity check).
- **New (empty-queue, no prior file):** "build_queue.sh with empty
  approved set and no destination file does not create one" — invoke
  with a destination path that does not exist, assert exit 0, assert
  destination still does not exist. Same atomicity hygiene.
- **Delete:** "no approved issues outputs nothing and exits 0"
  (line 77) — superseded by the two new empty-queue tests above,
  which cover both the "preserve prior" and "no-create" cases more
  directly than the original output-emptiness assertion.

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
  obsolete. The renderer now selects records by header `run_id`
  rather than by chronologically-latest derivation. The structural
  protection (`select(.run_id == $run)` at `render_status.sh:63`)
  silently drops any record whose `run_id` doesn't match the header,
  including legacy records from older runs. The new precedence test
  (records under `OLD` don't appear when header selects `NEW`)
  exercises the same protection on the same code path.

### Acceptance-criteria mapping

The original Linear description listed four acceptance criteria. Three
map directly; the fourth is superseded by this spec. Two acceptance
criteria are added during the codex round (atomic publish + run_id
inheritance documented).

| Criterion | Status | Covered by |
| --- | --- | --- |
| `/sr-start` writes `# run_id: <id>` as first line of `ordered_queue.txt` | Met | `build_queue.bats` new "header first line" test |
| `/sr-status` reads `run_id` from header instead of deriving from `progress.json` | Met | `render_status.bats` precedence test |
| Fall back to current derivation if header absent | **Superseded** | This spec drops the fallback; `/sr-status` errors loud on missing header. See "Backwards-compat" above for rationale (no existing users to compat for). |
| Tests cover both paths | Met (revised) | New tests above cover header-present and header-missing-error in both the orchestrator and renderer |
| **Added:** queue-file publish is atomic (race "closed" claim must hold) | Met | `build_queue.bats` new "atomicity guarantee" test (failing toposort leaves destination intact) + new "empty-queue preservation" test |
| **Added:** `run_id` second-resolution constraint inheritance is documented | Met | "Failure modes" section, `run_id` second-resolution collision entry |

## Failure modes

- **`run_id` second-resolution collision** (codex finding 3). Header
  values come from `date -u +%Y-%m-%dT%H:%M:%SZ` — second-precision.
  Two `/sr-start` invocations completed within the same UTC second
  produce queue files with the same `run_id`. `/sr-status` would
  group records from both invocations as one logical run. **This
  inherits today's behavior:** the orchestrator currently has the
  same collision (`orchestrator.bats:1447` notes "run_id is
  second-resolution by design; back-to-back runs within the same
  second would share an id"). Today the consequence is benign because
  /sr-status's chronological-sort derivation also can't distinguish
  same-second runs. Under this design, the consequence is the same:
  ambiguous grouping. The risk is bounded by the operator pattern
  (intentional rapid-fire `/sr-start`) and the constraint that
  `/sr-start` is single-invocation by design. **Mitigation:** none in
  this spec — widening the identifier (nanoseconds, PID-suffixed,
  random) is out of scope; see Out of scope below. If real-world
  collisions are ever observed, follow up with a separate issue.

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
  runs would race the queue file's atomic publish (last-rename-wins).
  Not a new failure mode. The atomic publish guarantees readers see
  one or the other in full, but the loser's `run_id` simply
  vanishes — no half-formed file is exposed.

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
- **Widening `run_id` resolution** beyond second-precision UTC
  (codex finding 3 recommendation). Inherits today's orchestrator
  identifier format; any change to the format would propagate
  through `progress.json` records, the orchestrator's existing
  `run_id` handling, the chronological-sort logic in any consumer
  that touches `progress.json` directly, and the existing
  orchestrator.bats coverage. Worth a separate issue if real
  collisions are observed.
- Concurrent `/sr-start` support. Inherited limitation, not addressed.

## Prerequisites

None. ENG-241 (added `/sr-status` and the `progress.json` event
discriminator) is already shipped and provides the surface this change
modifies. No `blocked-by` relations to set on this issue.
