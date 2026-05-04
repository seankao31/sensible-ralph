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

Separate "queue under construction" from "queue committed for
dispatch" using two files in `.sensible-ralph/`:

- **`queue_pending.txt`** (new) — written by `build_queue.sh` in
  step 2, contains issue IDs only (no header). Internal to
  `/sr-start`'s build/preview phase. Never read by `/sr-status`.
- **`ordered_queue.txt`** (existing path, new contract) — written
  *only* by the orchestrator at startup, after the operator confirms
  dispatch. First line is `# run_id: <iso8601>`; subsequent lines
  are issue IDs. Read by `/sr-status` as the authoritative current
  run.

The orchestrator generates `run_id` at startup, atomically publishes
header + issues to `ordered_queue.txt` (tempfile + same-directory
`mv`), then writes the first `progress.json` record. `/sr-status`
reads `run_id` directly from the header.

The original ENG-287 bug — `/sr-status` rendering the new queue
against the *previous* run's `run_id` — closes by construction:
`ordered_queue.txt` is only written when a run is committed for
dispatch, and the header it carries is the same `run_id` that flows
into every `progress.json` record. Mixed-state rendering becomes
structurally impossible. Aborted previews and failed builds leave
`ordered_queue.txt` intact (showing the last actual run), so they
cannot create phantom runs.

A *different* transient remains and is documented honestly under
Failure modes: between the orchestrator publishing the header and
writing the first `start` record for issue 1, `/sr-status` renders
`Done (0) / Running (0) / Queued (N)` with the new `run_id`. This
window equals the orchestrator's per-issue setup time for the first
issue (branch lookup, worktree create/merge, base-SHA write, Linear
`In Progress` transition, Claude session setup — `orchestrator.sh:599`
context). It is bounded by today's per-issue setup duration (seconds
to minutes for the first issue) and inherits from today's
orchestrator: today's operator sees the same setup-time gap, just
with the *additional* mixed-state confusion that this spec resolves.
Under Option β the operator sees an honest "new run committed, no
issues running yet" rendering instead of the misleading mixed state.
Codex round-3 finding 1 surfaces this; the recommendation to publish
the header after the first `start` record is rejected because it
inverts the UX (operator who just `/sr-start`ed sees no visible
change until the first issue actually transitions, which feels
broken). See Failure modes below.

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

### Build phase: `build_queue.sh`

Builds the dispatch list and atomically publishes it to a destination
path. **Interface change:** the script takes an output path argument
(`$1`) instead of streaming to stdout. Output contains issue IDs
only — no header.

- New invocation, replacing the redirect-based form in
  `skills/sr-start/SKILL.md` step 2:
  ```bash
  "$SKILL_DIR/scripts/build_queue.sh" "$sr_root/queue_pending.txt"
  ```
- **Atomic publish.** `build_queue.sh` writes its output to a tempfile
  in the same directory as the destination path
  (`mktemp "${dest}.XXXXXX"`), then `mv`s the tempfile to the
  destination on success. Same-filesystem rename is atomic on POSIX —
  readers of `queue_pending.txt` either see the prior published file
  (fully formed) or the new one (fully formed), never a partial mix.
  This pattern matches `_progress_append`'s tempfile + `mv` approach
  in `orchestrator.sh:117–123`.
- **Failure handling.** If any step in queue construction fails
  (`linear_list_approved_issues`, `toposort.sh`, blocker fetches),
  `build_queue.sh` removes the tempfile and exits non-zero. The
  destination file is left untouched.
- **Empty-queue case** (no pickup-ready Approved issues): the script
  removes its tempfile and exits with **distinct exit code `2`**
  (success-with-no-work). The destination file is left untouched.
  This signals to the caller that there is nothing to dispatch
  *without* leaving a stale file behind that could be mistaken for a
  fresh queue. Closes codex finding 1.
- Exit code summary: `0` = published a non-empty queue;
  `1` = construction failed (toposort cycle, linear error, etc.);
  `2` = empty queue, nothing to publish.

### Commitment phase: orchestrator startup

The orchestrator becomes the publisher of `ordered_queue.txt`. Before
dispatching the first issue and before writing the first progress
record, the orchestrator:

1. Reads `queue_pending.txt` (issue IDs).
2. Errors out with non-zero exit if `queue_pending.txt` is missing or
   empty (this is a contract violation — `/sr-start` step 2 should
   have populated it before invoking the orchestrator).
3. Generates `run_id` (same `date -u +%Y-%m-%dT%H:%M:%SZ` line that
   currently lives at `orchestrator.sh:150`).
4. Atomically publishes header + issue IDs to `ordered_queue.txt` via
   tempfile + same-directory `mv`. The tempfile is named
   `mktemp "${ordered_queue}.XXXXXX"` to keep the rename on the
   same filesystem.
5. Continues with the existing dispatch loop, using the in-memory
   issue ID list (no need to re-read `ordered_queue.txt`).

This is the *only* path that writes `ordered_queue.txt`. The file
is by construction either non-existent (no dispatch ever ran in this
repo) or fully formed with a valid header.

### Caller: `/sr-start` SKILL.md flow

Step 2 invokes `build_queue.sh` with the pending path and branches
on exit code:

```bash
sr_root="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.sensible-ralph"
mkdir -p "$sr_root"
queue_pending="$sr_root/queue_pending.txt"
if "$SKILL_DIR/scripts/build_queue.sh" "$queue_pending"; then
  : # exit 0: non-empty queue published, continue to step 3
else
  rc=$?
  case "$rc" in
    2) echo "/sr-start: no pickup-ready Approved issues. Nothing to dispatch." >&2 ; exit 0 ;;
    *) echo "/sr-start: build_queue.sh failed with exit $rc" >&2 ; exit "$rc" ;;
  esac
fi
```

Step 3 (preview) reads `queue_pending.txt`. Step 4 invokes
`orchestrator.sh "$queue_pending"`. The orchestrator does the
commitment publish to `ordered_queue.txt` internally before
dispatch.

`ordered_queue.txt` is *not* touched by `/sr-start` directly. Aborts
at step 3 leave `ordered_queue.txt` unchanged (still showing the last
committed run, if any) — closes codex finding 2.

### Readers

**`skills/sr-start/scripts/orchestrator.sh`:**

The orchestrator is now both a reader and writer of `ordered_queue.txt`
— see "Commitment phase" above for the publish step.

- The `$1` argument is now `queue_pending.txt`, not `ordered_queue.txt`.
  The orchestrator reads `queue_pending.txt` for issue IDs only.
- Generate `run_id` (replaces the line currently at `orchestrator.sh:150`,
  which is preserved structurally — same `date -u +...` invocation,
  same point in the script flow, just upstream of the publish).
- Atomically publish header + issue IDs to `ordered_queue.txt` (path
  resolved as `$repo_root/.sensible-ralph/ordered_queue.txt` via
  the existing `_resolve_repo_root` helper used elsewhere in
  `orchestrator.sh`).
- Continue dispatch with the in-memory `queued_ids` list. No
  `#`-comment skip needed in the queue-loading loop because
  `queue_pending.txt` is header-less by construction.

**`skills/sr-status/scripts/render_status.sh`:**

The renderer reads `ordered_queue.txt` only. It does *not* read
`queue_pending.txt`.

- Restructure the early-exit logic at `render_status.sh:38–52`:
  1. If `$queue_file` (i.e., `ordered_queue.txt`) does not exist,
     print the existing `_no_runs_message` and exit 0. Legitimate
     fresh-repo path — no `/sr-start` has ever committed a run.
  2. Otherwise, read the queue file's first line. If it matches
     `^# run_id: (.+)$`, set `latest_run_id` to the captured value.
  3. If the queue file exists but has no valid header line, error to
     stderr and exit non-zero:
     `sr-status: ordered_queue.txt missing '# run_id: <id>' header line — re-run /sr-start to regenerate.`
     This case should not occur under the new design (orchestrator
     always writes a header), but the explicit error guards against
     legacy header-less files left over from prior plugin versions.
- **Delete** the chronological-sort derivation block currently at
  `render_status.sh:46–52` (the
  `[.[].run_id] | unique | map(select(. != null)) | sort_by(fromdateiso8601) | last`
  jq pipeline). Without a fallback path, that block is unreachable.
- The downstream queue-file read at `render_status.sh:104–110` (the
  while-loop building `queued_issues`) needs a `#`-comment skip so
  the header line doesn't show up as a queued issue ID.
- **No-progress.json contract** (codex round-4 finding 1).
  `render_status.sh` runs under `set -euo pipefail`. The existing
  early-exit at `render_status.sh:38–41` (which short-circuits to
  `_no_runs_message` when `progress.json` is missing) **moves but
  does not disappear**: under the new design, when the queue header
  is present but `progress.json` is missing or unreadable, the
  renderer must initialize `run_records='[]'` and continue with the
  partitioning logic on that empty array. This produces empty Done,
  empty Running, and full Queued — the correct rendering for the
  setup-time gap before the first `start` record lands. Specifically:
  ```bash
  if [[ -f "$progress_file" ]]; then
    run_records="$(jq --arg run "$latest_run_id" '[.[] | select(.run_id == $run)]' < "$progress_file")"
  else
    run_records='[]'
  fi
  ```
  All downstream jq reads partition `$run_records`, not `$progress_file`,
  so they are safe under `[]`. Without this explicit handling, `set -e`
  would crash the renderer on the first jq read of a missing
  `$progress_file`.

### Backwards-compat

None. The header is required. The fail-loud branches above
(orchestrator and renderer) are correct strict-contract enforcement,
not deprecation paths.

**The plugin's existing user (this repo plus the operator's other
sensible-ralph repos) has header-less `ordered_queue.txt` files on
disk from prior plugin versions.** Codex round-3 finding 2 correctly
calls out that this is "production use" in the literal sense —
earlier wording in this spec that called the older format "no
production use" was inaccurate. The operator-facing upgrade
behavior is unchanged from the prior section, just honestly
labeled:

A repo with a header-less `.sensible-ralph/ordered_queue.txt` left
over from a prior plugin version will have `/sr-status` exit
non-zero with the missing-header error message until the next
`/sr-start` runs. The next `/sr-start`'s commitment publish writes
a header-bearing file, restoring `/sr-status`. **Recovery:** re-run
`/sr-start`. (Codex round-4 finding 3 correctly noted that
`rm ordered_queue.txt` was a misleading recovery suggestion: while
it does silence the missing-header error, it makes `/sr-status`
report `No ralph runs recorded` even when `progress.json` has run
history — suppressing real visibility. Recovery is a single
`/sr-start` invocation.)

This trade-off is explicitly accepted — weighing one-time
post-upgrade friction (one operator, one-step recovery, no
dispatch needed) against indefinite dead-code maintenance of a
fallback path. The contract simplification (`ordered_queue.txt`
*always* has a header by construction once the upgrade is past)
is worth the single recovery step. If at some future point the
operator population expands beyond Sean's repos, revisit.

## File-by-file changes

1. **`skills/sr-start/scripts/build_queue.sh`** — interface change:
   take output path as `$1`. Build issue IDs from `toposort.sh` into
   a tempfile in the destination's directory. On success (non-empty),
   `mv` the tempfile to the destination, exit 0. On `toposort.sh`
   failure or any other error, remove the tempfile and exit 1. On
   empty queue (no pickup-ready Approved issues), remove the
   tempfile and exit 2. Header is *not* written here. The current
   control-flow early-exits at `build_queue.sh:55–56` and `:117`
   are repurposed for the empty-queue (exit 2) path. ~25 lines net.

2. **`skills/sr-start/scripts/orchestrator.sh`** — `$1` is now
   `queue_pending.txt`. Generate `run_id` (preserve the existing
   `date -u +...` line, just before its current position). Read
   `queue_pending.txt` into `queued_ids` (existing loop at
   `orchestrator.sh:138–141`, unchanged). Insert a new step
   immediately after `queued_ids` is populated: atomically publish
   header + `queued_ids` to `ordered_queue.txt` (`$repo_root/.sensible-ralph/ordered_queue.txt`)
   via tempfile + `mv`. Continue with the existing dispatch loop.
   ~25 lines net.

3. **`skills/sr-status/scripts/render_status.sh`** — restructure
   the early-exit logic at lines 38–52 to read the queue header,
   delete the `progress.json` derivation block, exit non-zero on
   missing header. Add `#`-comment skip in the `queued_issues` loop
   (lines 104–110). ~15 lines net.

4. **`skills/sr-start/SKILL.md`** — step 2 invocation changes from
   `build_queue.sh > "$sr_root/ordered_queue.txt"` to the
   exit-code-aware snippet shown in the "Caller" section above
   (writes to `queue_pending.txt`). Step 3 (preview) reads
   `queue_pending.txt` instead of `ordered_queue.txt`. Step 4
   (orchestrator invocation) passes `queue_pending.txt` instead of
   `ordered_queue.txt`. Add a sentence to the "When back" section
   noting that `ordered_queue.txt` is the authoritative
   committed-run record (read by `/sr-status`) and
   `queue_pending.txt` is transient/internal to `/sr-start`.

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
  mechanical conversion. Add a per-test `local out_path; out_path="$(mktemp -u)"`
  setup line (use `mktemp -u` so the destination doesn't exist
  before invocation) and replace `[ "$output" = "..." ]` assertions
  with `[ "$(cat "$out_path")" = "..." ]` (or substring/regex
  matches as appropriate). Note: the output file contents are now
  *issue IDs only* — no header line.
- **New (atomicity guarantee):** "build_queue.sh with failing
  toposort.sh leaves the destination file unchanged" — pre-populate
  the destination with a known sentinel content (e.g.,
  `ENG-OLD\n`), set up an issue graph that triggers a toposort cycle
  (or stub `toposort.sh` to exit non-zero), invoke `build_queue.sh`,
  assert exit 1, assert destination contents are byte-identical to
  the sentinel.
- **New (empty-queue, distinct exit code):** "build_queue.sh with
  empty approved set exits 2 and leaves destination unchanged" —
  pre-populate the destination with sentinel content, set
  `STUB_APPROVED_IDS=""`, invoke `build_queue.sh`, assert exit 2,
  assert destination contents byte-identical to the sentinel. Also
  assert no tempfile lingers in the destination directory after the
  run (mirrors `orchestrator.bats` test 23 atomicity check). Closes
  codex finding 1.
- **New (empty-queue, no prior file):** "build_queue.sh with empty
  approved set and no destination file exits 2 and creates nothing"
  — invoke with a destination path that does not exist, assert
  exit 2, assert destination still does not exist.
- **Delete:** "no approved issues outputs nothing and exits 0"
  (line 77) — superseded by the two new empty-queue tests above
  AND by the exit-code change (empty no longer exits 0).

### `skills/sr-start/scripts/test/orchestrator.bats`

- **Helper sweep:** the `write_queue` helper (used throughout) is
  unchanged — it still produces a header-less file of issue IDs,
  which is now the correct format for `queue_pending.txt`. The
  variable named `queue_file` in tests is now semantically the
  pending-queue path, but the bash variable name need not change.
- **New (commitment publish):** "orchestrator publishes
  `ordered_queue.txt` with header before dispatch" — invoke
  orchestrator with a `queue_pending.txt` containing one issue,
  assert `ordered_queue.txt` exists at the expected path
  (`$REPO_DIR/.sensible-ralph/ordered_queue.txt`), assert its first
  line matches `^# run_id: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$`,
  assert its remaining lines are the issue IDs from the pending file.
- **New (header matches progress.json records):** "orchestrator's
  published header `run_id` matches every `progress.json` record's
  `run_id`" — invoke orchestrator with a multi-issue pending queue,
  assert that `head -1 ordered_queue.txt` parsed run_id is byte-equal
  to every `run_id` field in `progress.json`. This is the structural
  guarantee that `/sr-status` partitions records correctly.
- **New (atomic publish on commitment):** "orchestrator's
  `ordered_queue.txt` publish is atomic" — pre-populate
  `ordered_queue.txt` with sentinel content, run orchestrator with a
  pending queue, assert `ordered_queue.txt` is fully replaced (no
  partial mix of sentinel and new content) and no tempfile lingers
  in `.sensible-ralph/`.
- **New (missing pending queue):** "orchestrator with missing
  `queue_pending.txt`: errors and exits non-zero" — invoke
  orchestrator with a path that does not exist, assert non-zero
  status and a clear error message on stderr.
- **New (empty pending queue):** "orchestrator with empty
  `queue_pending.txt`: errors and exits non-zero" — write an empty
  file at the pending path, invoke orchestrator, assert non-zero
  status and a clear error message on stderr. Also assert
  `ordered_queue.txt` was NOT written (the contract violation must
  not pollute the committed-run state).
- **Update:** "two consecutive runs produce distinct run_ids"
  (line 1417) — each run still uses `write_queue` to produce a
  pending file. The orchestrator generates run_id internally, so
  the existing `sleep 1` between runs remains necessary (this is
  the inherited second-resolution constraint).

### `skills/sr-status/scripts/test/render_status.bats`

- **Helper sweep:** the `write_queue` helper (line 44) takes a
  `run_id` argument and prepends `# run_id: <run_id>` to the file.
  This helper now writes the *committed* `ordered_queue.txt`, which
  in production is only ever written by the orchestrator. In tests,
  we write it directly to set up rendered-state fixtures. Existing
  call sites pass an explicit id.
- **New (the regression test for ENG-287):** "queue header `run_id`
  takes precedence; new run with no progress.json records yet
  renders empty Done/Running and full Queued" — write
  `progress.json` with records under `run_id` `OLD`, write
  `ordered_queue.txt` with header `NEW` and three issue IDs, run
  renderer, assert: `Run started: NEW`, `=== Done (0) ===`,
  `=== Running (0) ===`, `=== Queued (3) ===` listing the issues
  from the queue. (No records from `OLD` should appear anywhere.)
- **New:** "ordered_queue.txt exists but has no header: error and
  exit non-zero" — write queue file with no header, assert non-zero
  status, assert stderr contains
  `missing '# run_id: <id>' header line`.
- **New (no-progress.json contract — codex round-4 finding 1):**
  "queue header present, progress.json missing: renders empty
  Done/Running, full Queued, exit 0" — write `ordered_queue.txt`
  with header `RID` and two issue IDs, do *not* create
  `progress.json`, run renderer, assert exit 0, assert
  `Run started: RID`, `=== Done (0) ===`, `=== Running (0) ===`,
  `=== Queued (2) ===` listing both issues. This guards against
  the `set -e` crash that would result if the renderer naively
  jq-reads a missing `progress.json`.
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

The original Linear description listed four acceptance criteria. Two
map directly. The third is superseded. The fourth maps with the
revised test surface. Three additional criteria emerged from the
codex rounds.

| Criterion | Status | Covered by |
| --- | --- | --- |
| `/sr-start` writes `# run_id: <id>` as first line of `ordered_queue.txt` | Met (publisher shifted) | The orchestrator (not `build_queue.sh`) is the publisher under Option β. `orchestrator.bats` new "commitment publish" test asserts the file shape. |
| `/sr-status` reads `run_id` from header instead of deriving from `progress.json` | Met | `render_status.bats` precedence test |
| Fall back to current derivation if header absent | **Superseded** | This spec drops the fallback; `/sr-status` errors loud on missing header. See "Backwards-compat" above for rationale (no existing users to compat for). |
| Tests cover both paths | Met (revised) | New tests above cover header-present and header-missing-error in both the orchestrator and renderer |
| **Added (codex round 1):** queue-file publish is atomic (race "closed" claim must hold) | Met | `orchestrator.bats` new "atomic publish on commitment" test |
| **Added (codex round 1):** `run_id` second-resolution constraint inheritance is documented | Met | "Failure modes" section, `run_id` second-resolution collision entry |
| **Added (codex round 2):** aborted previews and empty queues do not create phantom runs | Met | `ordered_queue.txt` is only written by the orchestrator's commitment step; structurally cannot exist with a header unless a run was committed. `build_queue.bats` empty-queue tests + `orchestrator.bats` commitment-publish test cover the runtime guarantees. |

## Failure modes

- **`run_id` second-resolution collision** (codex round-1 finding 3).
  Header values come from `date -u +%Y-%m-%dT%H:%M:%SZ` —
  second-precision. Two `/sr-start` invocations whose orchestrator
  startups land in the same UTC second produce `ordered_queue.txt`
  publications with the same `run_id`. `/sr-status` would group
  records from both invocations as one logical run. **This inherits
  today's behavior:** the orchestrator currently has the same
  collision (`orchestrator.bats:1447` notes "run_id is
  second-resolution by design; back-to-back runs within the same
  second would share an id"). Today the consequence is benign because
  /sr-status's chronological-sort derivation also can't distinguish
  same-second runs. Under this design, the consequence is the same:
  ambiguous grouping. The risk is bounded by the operator pattern
  (intentional rapid-fire `/sr-start`) and the constraint that
  `/sr-start` is single-invocation by design. **Mitigation:** none in
  this spec — widening the identifier (nanoseconds, PID-suffixed,
  random) is out of scope; see Out of scope below.

- **Setup-time gap between header publish and first `start` record**
  (codex round-3 finding 1). The orchestrator atomically publishes
  `ordered_queue.txt` near the top of its run, then enters the
  per-issue dispatch loop. The first `start` record lands at
  `orchestrator.sh:599`, *after* per-issue setup work (branch
  lookup, dag_base resolution, worktree create/merge, base-SHA
  write, Linear `In Progress` transition, Claude session setup).
  Between header publish and that first append, `/sr-status` renders
  `Done (0) / Running (0) / Queued (N)` with the new `run_id` —
  even though the orchestrator IS doing real work for the first
  issue. The window can be seconds to a minute or two, depending on
  worktree-create cost, network latency to Linear, and Claude
  startup. **This inherits today's behavior:** today's orchestrator
  also has the same setup window before the first `start` record;
  today's operator sees the additional ENG-287 mixed-state confusion
  on top of it, which Option β eliminates. Net: Option β reduces
  operator confusion, doesn't widen the setup window.
  Additionally, `_progress_append` for the first start record is
  best-effort (`|| true` at the call site); a write failure leaves
  the issue invisible to `/sr-status` until the end record lands.
  Same behavior as today.
  **Mitigation:** none in this spec — restructuring to publish the
  header after the first `start` record would invert the operator
  UX (no visible change after `/sr-start` until the first issue
  actually transitions). Acknowledged limitation; revisit only if
  operator confusion is observed in practice.

- **Orchestrator hard crash between Linear `In Progress` transition
  and first `start` record** (codex round-4 finding 2). The
  orchestrator transitions the first issue's Linear state to
  `In Progress` *before* appending the start record (see
  `orchestrator.sh:599` context). If the orchestrator is killed
  (signal, OOM) in this gap, the issue is left in `In Progress` in
  Linear with no `progress.json` record under the new `run_id`. The
  next `/sr-start`'s `build_queue.sh` will not pick the issue back
  up (it's no longer Approved), so the new `ordered_queue.txt` will
  not include it. `/sr-status` loses visibility into the stranded
  issue entirely. **This is NOT self-correcting** — earlier wording
  in this spec was wrong. **This inherits from today's
  orchestrator** — today the same crash leaves the same stranded
  state (just with the additional ENG-287 mixed-state confusion that
  this spec resolves on top of it). **Recovery:** operator manually
  transitions the stranded issue back to `Approved` (and labels it
  `ralph-failed` if appropriate per the orchestrator's existing
  outcome model). Operationally rare; pre-existing gap not
  introduced or widened by this spec.

- **Operator hand-edits `ordered_queue.txt`.** If an operator opens
  the queue file and edits issue IDs without preserving the header,
  the renderer errors loud on the next invocation. The error message
  points at re-running `/sr-start` to regenerate. Acceptable failure
  mode — operator gets clear guidance.

- **Direct `orchestrator.sh` invocation outside `/sr-start`** (e.g.,
  ad-hoc debugging). The orchestrator now requires a populated
  `queue_pending.txt` at the path passed as `$1`. Manual invocation
  must point at a valid pending file (or one constructed by hand
  with `printf 'ENG-X\nENG-Y\n' > /tmp/pending`). Documented in the
  orchestrator script's docstring.

- **Concurrent `/sr-start` invocations.** Already documented as
  unsupported (`orchestrator.sh:109–111`). The two-file mediation
  here inherits the same limitation: two parallel `/sr-start` runs
  could race the `queue_pending.txt` write and the
  `ordered_queue.txt` publish. Not a new failure mode. Both atomic
  publishes guarantee readers see one or the other in full, but
  inter-file consistency (pending vs. committed) is not protected.

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
