# `linear_remove_label` uses GraphQL throughout

## Context

The spec for `linear_remove_label` (ENG-280) described two possible
implementation paths: use `linear issue update --label` to overwrite
the label set with the target removed (for the non-empty reduced-set
case), and fall back to a GraphQL `issueRemoveLabel(id, labelId)`
mutation only when the reduced set would be empty (since `--label`
with no flags has ambiguous semantics across CLI versions).

## Decision

Implement `linear_remove_label` using GraphQL exclusively: a single
query fetches the issue UUID and currently-attached labels (with IDs);
a follow-up `issueRemoveLabel(id, labelId)` mutation removes the
target. The CLI path is not used at all.

## Reasoning

Mixing paths (CLI for non-empty, GraphQL for empty) creates two
distinct failure surfaces with different diagnostic messages, and it
requires the function to special-case an empty reduced set in the
middle of logic that would otherwise be uniform. The spec explicitly
said "the implementer picks one path consistently" — GraphQL-throughout
satisfies that, eliminates the cross-version CLI ambiguity entirely,
and keeps the failure surface (and error messages) uniform regardless
of how many labels are on the issue.

`linear_get_issue_blockers`, `linear_get_issue_blocks`, and
`linear_list_initiative_projects` already use the GraphQL path via
`linear api`, so the same pattern is established for other helpers in
this file.

## Consequences

Future modifications to `linear_remove_label` should stay on the
GraphQL path. If Linear's `issueRemoveLabel` mutation shape changes
(field rename, payload restructure), fix it in one place rather than
in two split paths. Switching back to `linear issue update --label`
would require re-introducing the empty-reduced-set special case.
