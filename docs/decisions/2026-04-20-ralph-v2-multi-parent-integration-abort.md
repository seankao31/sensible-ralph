# Ralph v2: Multi-Parent Integration Merge Aborts on Conflict

## Context

The design spec (Decision 7, "Branch DAG awareness") describes integration-merge setup as: create the worktree from `main`, sequentially `git merge` each in-review parent, and if any merge conflicts, "leave them. The agent resolves." The rationale emphasized v2's distinguishing property — "v1 would have skipped B and blocked progress; v2's whole point is keeping chains moving."

Reading the spec alone, a maintainer would expect that language to apply uniformly — single-parent and multi-parent integration both leave conflicts for the agent. The implementation deliberately diverges from that reading for multi-parent cases.

## Decision

`lib/worktree.sh::worktree_create_with_integration` behaves differently based on parent count:

- **Single parent with conflict:** leave conflicts in place; return 0; the agent resolves during its session. Matches spec verbatim.
- **Multi-parent with conflict on any parent:** abort the in-progress merge (`git merge --abort`), clean up the worktree, return non-zero. The orchestrator records `setup_failed` with `failed_step = worktree_create_with_integration`, applies `ralph-failed`, and taints descendants.
- **Multi-parent with no conflicts:** proceeds cleanly (the common success case).

## Reasoning

Once `git merge` exits with a conflict, the worktree is in MERGING state. Git refuses to start a second merge until the first is resolved or aborted. A naive "leave conflicts, continue through the parent list" implementation would silently drop parents 2, 3, ... after a conflict on parent 1 — the only work that would actually happen in that worktree is parent 1's integration. The dispatched agent would see conflicts only for parent 1, resolve them, and hand the result off as a successful in-review branch whose scope is provably wrong. There is no git command that produces "resolvable state for parent 1, queued merges for parent 2+" — the tool does not expose that mode.

Alternatives considered and rejected:

1. **Invoke `claude -p` mid-orchestrator to resolve parent N before attempting parent N+1.** Requires the orchestrator to hand control to a nested autonomous session, reason about when the agent is "done", and retry the merge. Multiplies complexity and breaks the "one `claude -p` per issue" model that keeps the orchestrator easy to reason about. Deferred to v3 if multi-parent conflict chains become a common operational bottleneck.
2. **Octopus merge (`git merge parent1 parent2 ...`).** Git's octopus strategy refuses to produce any merge commit if any parent conflicts — it aborts uniformly with no resolvable state. This is strictly worse UX than the current sequential-with-fast-fail behavior.
3. **Leave conflicts in place anyway and accept silent drops.** Unacceptable — the spec's correctness contract requires that an in-review branch for B represents a real integration of B's parents.

Fail-fast is the conservative choice. It partially regresses toward v1's "skip on conflict" behavior, but only in the narrow multi-parent-with-conflicts case. Single-parent conflicts (the common case — most dependency chains are linear) still behave per spec. Multi-parent conflicts between two already-approved parents are rare in practice when blocker relations are well-structured.

## Consequences

- Multi-parent integration with any conflict → `ralph-failed`, descendants tainted, worktree cleaned up. Operator resolution options:
  1. Merge the conflicting parent into `main` first (promotes one parent to Done), then re-queue.
  2. Re-sequence the dependency graph so only one parent is in In Review at a time.
  3. Review and merge one parent manually, then re-run `/ralph-start`.
- Single-parent integration with conflict → unchanged from spec. Agent resolves during its session.
- The behavior is opaque from the spec alone. A future maintainer reading Decision 7 should cross-reference this decision doc before modifying `worktree_create_with_integration`.
- v3 backlog: if multi-parent workflows become common and manual resolution is a real bottleneck, revisit option 1 (mid-orchestrator agent dispatch for iterative conflict resolution). Not worth building speculatively.
