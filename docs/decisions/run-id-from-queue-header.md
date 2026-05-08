# `/sr-status` reads `run_id` from `ordered_queue.txt`'s header, with no fallback

## Context

`/sr-start` step 2 used to rewrite `.sensible-ralph/ordered_queue.txt` for a
new run before invoking the orchestrator. The orchestrator generated `run_id`
internally and wrote it into every `progress.json` record. Between the queue
rewrite and the orchestrator's first `_progress_append` call, there was a
window — typically seconds, sometimes minutes — where the queue file
described the new run but `progress.json` only contained the previous run's
records. `/sr-status` derived `latest_run_id` via a chronological-sort
pipeline over `progress.json`, so during the window it returned the
*previous* run's `run_id` and partitioned the new queue against stale
records (operator saw a status mixing the new queue with old completion
data).

## Decision

The orchestrator (not `build_queue.sh`) is the sole publisher of
`ordered_queue.txt`. At startup, before any `progress.json` write, the
orchestrator generates `run_id` and atomically writes
`# run_id: <iso8601>` plus issue IDs to `ordered_queue.txt` via
tempfile + same-directory `mv`. `/sr-status` reads `run_id` directly from
the header and partitions `progress.json` records by `select(.run_id ==
$header_run_id)`. The previous chronological-sort derivation
(`render_status.sh:46–52`'s `[.[].run_id] | unique | sort_by(fromdateiso8601)
| last`) is removed entirely. Header-less `ordered_queue.txt` files (legacy
from prior plugin versions) cause `/sr-status` to error loud with a pointer
to re-run `/sr-start`.

`/sr-start`'s build phase writes to a separate file, `queue_pending.txt`
(issue IDs only, no header). Aborted previews and empty queues never touch
`ordered_queue.txt`, so they cannot create phantom runs.

## Reasoning

Alternatives considered and rejected:

- **Fallback to derivation when header is absent.** Adds dead-code
  maintenance for an indefinite period after every consumer-repo upgrade.
  The single existing operator (Sean) is one-step recoverable per repo
  (re-run `/sr-start` for active repos; `rm` the file for idle ones). Cost
  of recovery vs. cost of the dual-path forever is asymmetric.
- **Have `build_queue.sh` write the header.** Reintroduces the same race in
  a different shape: `build_queue` runs in step 2; the orchestrator runs in
  step 4; the operator can abort between steps 3 and 4. With the header
  written at build time, an aborted preview leaves `ordered_queue.txt`
  carrying a `run_id` that was never dispatched — `/sr-status` would render
  Done(0)/Running(0)/Queued(N) for a run that does not exist. The
  commitment-phase publish ensures `ordered_queue.txt` only carries
  `run_id`s that an orchestrator actually ran with.
- **Publish the header *after* the first `start` record.** Eliminates a
  smaller setup-time window but inverts the operator UX: a fresh
  `/sr-start` would show no visible change in `/sr-status` until the first
  issue actually transitions, which feels broken (the operator just
  dispatched and sees nothing). Honest "new run, no issues running yet"
  rendering is the right trade.
- **Widen `run_id` resolution beyond second-precision UTC** to defuse
  same-second collision. Out of scope here — inherits today's identifier
  format; widening would propagate through every record consumer. Tracked
  separately if real collisions are observed.

## Consequences

- `ordered_queue.txt` becomes a strict-contract file: by construction it
  either does not exist (no orchestrator run has ever committed in this
  repo) or has a valid `# run_id: <iso>` header on line 1. The renderer
  enforces this invariant — any drift surfaces as a loud error pointing
  at `/sr-start`.
- The legacy chronological-sort path in `render_status.sh` is removed.
  Tests that exercised it (chronological selection across run_ids,
  legacy pre-`event` records filtered by run_id selection) are removed
  with it; the new structural protection — `select(.run_id == $run)`
  with `$run` sourced from the header — covers the same correctness
  invariant on a smaller code path.
- The orchestrator's `$1` argument is `queue_pending.txt`, not
  `ordered_queue.txt`. Direct `orchestrator.sh` invocations outside
  `/sr-start` (ad-hoc debugging) must construct or point at a valid
  pending file.
- A setup-time gap remains between header publish and the first `start`
  record landing (per-issue branch lookup, worktree create/merge,
  Linear `In Progress` transition, Claude session setup). During that
  window `/sr-status` honestly renders Done(0)/Running(0)/Queued(N) with
  the new `run_id` — strictly better than today's mixed-state confusion.
- Operators upgrading from a prior plugin version with a header-less
  `ordered_queue.txt` on disk recover with one step per repo: re-run
  `/sr-start` (for active repos with pickup-ready Approved issues) or
  `rm .sensible-ralph/ordered_queue.txt` (for idle repos). Decision is
  firm; not revisited absent a population of operators larger than one.
