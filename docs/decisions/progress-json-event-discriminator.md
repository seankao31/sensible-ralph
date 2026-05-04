# progress.json event discriminator — flat array with `event` field

## Context

ENG-241 added `/sr-status`, which needs to distinguish dispatch-start
moments (issue in-flight) from final outcomes (issue done). The orchestrator
already writes per-issue end records; we needed a corresponding start signal.

## Decision

Added an `event: "start" | "end"` discriminator field to every record in
`.sensible-ralph/progress.json`, leaving the outer structure (a flat JSON array,
appended atomically via `mktemp + jq + mv`) unchanged.

## Reasoning

Alternatives considered and rejected:

- **Separate start file** (`.sensible-ralph/running.json`): two files to maintain
  atomically, races between write and read across files, complicates pruning.
- **Nested structure** (`{"runs": [...], "in_flight": [...]}`): breaks the
  existing atomic-append pattern — `jq '. + [$rec]'` no longer works; would
  require read-modify-write of a nested key.
- **Status update to existing end record** (mutate "in_review" → "completed"):
  requires finding and overwriting a record by key, losing append-only semantics.
- **`status: "running"` field on end records written retroactively**: same
  problem — requires mutation.

The discriminator field keeps the format additive: old consumers that read
only `outcome` still work (start records have no `outcome` field — they filter
out implicitly when looking for outcome values). The legacy-record case
(no `event` field) is handled by `/sr-status` via run_id filtering: the
latest run always has new-schema records, so legacy records from older runs
are never reachable.

## Consequences

- `/sr-status` must filter by `event` before classifying. The jq idiom is
  `select(.event == "end")` / `select(.event == "start")`.
- Tools that inspect `progress.json` directly (operators, future skills) must
  know that the array may contain both start and end records for the same issue.
- Pre-ENG-241 records (no `event` field) remain readable by `jq` but are
  filtered out by `/sr-status` before event-discrimination — they render as
  "No ralph runs recorded" until the first new run completes.
