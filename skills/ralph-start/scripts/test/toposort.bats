#!/usr/bin/env bats
# Tests for scripts/toposort.sh
# Exercises Kahn's algorithm: ordering, priority tiebreaking, cycle detection, empty input.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
TOPOSORT="$SCRIPT_DIR/toposort.sh"

# ---------------------------------------------------------------------------
# 1. Linear chain: C blocked by B, B blocked by A → A, B, C
# ---------------------------------------------------------------------------
@test "linear chain emits issues in dependency order" {
  run bash -c "printf 'ENG-A 2\nENG-B 2 ENG-A\nENG-C 2 ENG-B\n' | '$TOPOSORT'"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "ENG-A" ]
  [ "${lines[1]}" = "ENG-B" ]
  [ "${lines[2]}" = "ENG-C" ]
  [ "${#lines[@]}" -eq 3 ]
}

# ---------------------------------------------------------------------------
# 2. Diamond: A unblocked; B and C blocked by A; D blocked by B and C.
#    B has priority 1 (Urgent), C has priority 2 (High) → B before C.
# ---------------------------------------------------------------------------
@test "diamond emits A then B then C then D with priority tiebreaker" {
  run bash -c "printf 'ENG-A 2\nENG-B 1 ENG-A\nENG-C 2 ENG-A\nENG-D 2 ENG-B ENG-C\n' | '$TOPOSORT'"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "ENG-A" ]
  [ "${lines[1]}" = "ENG-B" ]
  [ "${lines[2]}" = "ENG-C" ]
  [ "${lines[3]}" = "ENG-D" ]
  [ "${#lines[@]}" -eq 4 ]
}

# ---------------------------------------------------------------------------
# 3. Disconnected: two independent chains, interleaved by priority.
#    Chain 1: ENG-X (priority 2) → ENG-Y (priority 2)
#    Chain 2: ENG-P (priority 1) → ENG-Q (priority 3)
#    Both ENG-X and ENG-P start unblocked; ENG-P (priority 1) emits first.
#    After ENG-P, ENG-Q (priority 3) joins queue alongside ENG-X (priority 2);
#    ENG-X emits next. After ENG-X, ENG-Y (priority 2) joins alongside ENG-Q (priority 3);
#    ENG-Y (lower number) emits before ENG-Q.
# ---------------------------------------------------------------------------
@test "disconnected chains interleave by priority" {
  run bash -c "printf 'ENG-X 2\nENG-Y 2 ENG-X\nENG-P 1\nENG-Q 3 ENG-P\n' | '$TOPOSORT'"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "ENG-P" ]
  [ "${lines[1]}" = "ENG-X" ]
  [ "${lines[2]}" = "ENG-Y" ]
  [ "${lines[3]}" = "ENG-Q" ]
  [ "${#lines[@]}" -eq 4 ]
}

# ---------------------------------------------------------------------------
# 4. Cycle → exit 1, stderr contains "cycle"
# ---------------------------------------------------------------------------
@test "cycle exits 1 with cycle in stderr" {
  run bash -c "printf 'ENG-A 2 ENG-B\nENG-B 2 ENG-A\n' | '$TOPOSORT'" 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"cycle"* ]]
}

# ---------------------------------------------------------------------------
# 5. Empty input → exit 0, empty output
# ---------------------------------------------------------------------------
@test "empty input exits 0 with empty output" {
  run bash -c "printf '' | '$TOPOSORT'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# 6. Priority tiebreaker: two unblocked issues with different priorities
# ---------------------------------------------------------------------------
@test "priority tiebreaker emits lower priority number first" {
  run bash -c "printf 'ENG-LOW 4\nENG-HIGH 1\n' | '$TOPOSORT'"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "ENG-HIGH" ]
  [ "${lines[1]}" = "ENG-LOW" ]
  [ "${#lines[@]}" -eq 2 ]
}

# ---------------------------------------------------------------------------
# 7. Blocker not in input set is ignored (treated as already done)
# ---------------------------------------------------------------------------
@test "blocker not in input set is ignored" {
  run bash -c "printf 'ENG-A 2 ENG-DONE\nENG-B 2 ENG-A\n' | '$TOPOSORT'"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "ENG-A" ]
  [ "${lines[1]}" = "ENG-B" ]
  [ "${#lines[@]}" -eq 2 ]
}
