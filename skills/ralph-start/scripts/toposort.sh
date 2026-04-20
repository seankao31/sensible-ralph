#!/usr/bin/env bash
set -euo pipefail

# Kahn's algorithm over blocked-by relations. Priority is the tiebreaker.
#
# Input (stdin): one line per issue
#   <issue_id> <priority> [<blocker_id>...]
# priority: 1=Urgent … 4=Low (lower number = higher urgency)
# blockers: space-separated IDs this issue is blocked by; may be empty
#
# Output (stdout): issue IDs in topological order, one per line.
# When multiple issues are ready at the same time they are emitted
# in ascending priority order (1 before 4).
#
# Exits 1 if a cycle is detected; prints "error: cycle detected" to stderr.
# Exits 0 for empty input.

# ---------------------------------------------------------------------------
# Use a tmpdir as a key-value store for bash 3.2 (no declare -A).
# Each issue gets a directory: $tmpdir/<id>/
#   priority   – numeric priority
#   indegree   – count of unresolved blockers still in the input set
#   dependents – newline-separated list of issues that list this one as a blocker
# ---------------------------------------------------------------------------

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

# Pass 1: read all input lines; record every issue id so we can later
# distinguish "blocker in input set" from "blocker already done".
declare -a issue_ids=()
declare -a all_lines=()

while IFS= read -r line || [[ -n "$line" ]]; do
  # Skip blank lines
  [[ -z "${line//[[:space:]]/}" ]] && continue
  all_lines+=("$line")
  id="${line%% *}"            # first token
  issue_ids+=("$id")
  mkdir -p "$tmpdir/$id"
done

# Empty input → nothing to do.
if [[ "${#issue_ids[@]}" -eq 0 ]]; then
  exit 0
fi

# Helper: test whether an id is in the input set.
in_input_set() {
  [[ -d "$tmpdir/$1" ]]
}

# Pass 2: populate priority, in-degree, and dependents for each issue.
for line in "${all_lines[@]}"; do
  read -ra tokens <<< "$line"
  id="${tokens[0]}"
  priority="${tokens[1]}"

  # Linear returns priority=0 for "no priority". Ascending numeric sort would
  # put unprioritized issues ahead of priority=1 (Urgent), which lets a
  # disconnected no-priority issue jump the queue. Remap 0 to 5 so it sorts
  # after Low (priority=4).
  [[ "$priority" -eq 0 ]] && priority=5

  echo "$priority" > "$tmpdir/$id/priority"
  echo "0"         > "$tmpdir/$id/indegree"
  touch              "$tmpdir/$id/dependents"

  for (( i=2; i<${#tokens[@]}; i++ )); do
    blocker="${tokens[$i]}"
    # Only count blockers that are themselves in the input set.
    if in_input_set "$blocker"; then
      # Increment this issue's in-degree.
      deg="$(cat "$tmpdir/$id/indegree")"
      echo $(( deg + 1 )) > "$tmpdir/$id/indegree"
      # Record that this issue depends on blocker.
      echo "$id" >> "$tmpdir/$blocker/dependents"
    fi
  done
done

# ---------------------------------------------------------------------------
# Kahn's algorithm.
#
# The "queue" is a sorted list stored in a temp file, one entry per line:
#   <priority> <issue_id>
# We keep it sorted by priority (ascending) so the head is always the
# highest-urgency ready issue.
# ---------------------------------------------------------------------------

queue_file="$tmpdir/_queue"
: > "$queue_file"   # create/empty

# Seed queue with all zero-in-degree issues.
for id in "${issue_ids[@]}"; do
  deg="$(cat "$tmpdir/$id/indegree")"
  if [[ "$deg" -eq 0 ]]; then
    pri="$(cat "$tmpdir/$id/priority")"
    echo "$pri $id" >> "$queue_file"
  fi
done

emitted=0
total="${#issue_ids[@]}"

while [[ -s "$queue_file" ]]; do
  # Sort queue by priority (numeric, ascending) and pick the first entry.
  sorted="$(sort -n "$queue_file")"
  first_line="$(head -1 <<< "$sorted")"
  pri="${first_line%% *}"
  id="${first_line#* }"

  # Rewrite queue without this entry (exact-match first occurrence).
  grep -v "^$pri $id$" "$queue_file" > "$queue_file.tmp" || true
  mv "$queue_file.tmp" "$queue_file"

  echo "$id"
  (( emitted++ )) || true   # bash 4+: (( )) with result 0 triggers set -e; || true ensures portability

  # For each issue that was waiting on this one, decrement its in-degree.
  while IFS= read -r dep || [[ -n "$dep" ]]; do
    [[ -z "$dep" ]] && continue
    deg="$(cat "$tmpdir/$dep/indegree")"
    new_deg=$(( deg - 1 ))
    echo "$new_deg" > "$tmpdir/$dep/indegree"
    if [[ "$new_deg" -eq 0 ]]; then
      dep_pri="$(cat "$tmpdir/$dep/priority")"
      echo "$dep_pri $dep" >> "$queue_file"
    fi
  done < "$tmpdir/$id/dependents"
done

# If we didn't emit every node, there is a cycle.
if [[ "$emitted" -ne "$total" ]]; then
  echo "error: cycle detected" >&2
  exit 1
fi
