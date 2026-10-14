# Iteration 7: explicit scope-conflict resolution

Implementation date: 2026-10-14. Baseline: `15bfd17` (pre-fan-out
prerequisites). The user's direct-main/no-PR authorization for iteration 7
overrides the standing worktree/PR workflow. Verification uses Fake, local Git
fixtures and injected gate runners; no provider run was made.

## Decision boundary

REPO-INSPECTION: before this package, a fan-out `scope_blocked` attempt could not
be cleared. Every later `dispatch_ready` returned
`:fanout_scope_resolution_required` until a new plan revision superseded the
execution. `mix shoestring.execution resolve-scope` now records one explicit
human decision for exactly one blocked attempt, as
`cobbler.plan.task.scope_resolved` version 1:

- `accept`: the blocked attempt's tested commit and passed gate evidence become
  the task's accepted result. The blockers recorded in that event's bounded
  `decision_json` are acknowledged by exact value. Later fan-out assessments
  ignore exactly those values, and any other overlap still blocks. If any
  source listed fewer blockers than it counted, the original count stands and
  admission stays sequential. Acceptance needs bound final-scope evidence: an
  attempt whose final files could not be observed can only be rejected.
- `reject`: the attempt resolves as failed with retry state `retry`, `escalate`
  or `needs_user`, computed from the plan's task and total attempt limits.
  Any replacement must pass normal admission.

REPO-INSPECTION: the event names the exact blocked event id and the human
identity (`human:` only; the registry refuses others), with a reason of 1 to
2,000 characters. Validation and append share one immediate transaction behind
the serialized reservation writer. A replayed identical command converges on the
same event. A different decision, command id or reason for the same attempt is
`:scope_resolution_conflict`. A stale execution, unknown task or unblocked
attempt is `:scope_resolution_mismatch`.

REPO-INSPECTION: projection is deterministic. A resolved blocker leaves
`scope_blockers`. Status adds `acknowledged_scope_blockers`; a rejected child
reports `scope_rejected`. Gate duration from the blocked event counts once,
because the resolution carries no duration. Projector rebuild reproduces the
same status. Nothing merges. A dependent task still needs its inputs integrated
at the approved base, so it stays blocked with
`:fanout_inputs_require_integration` until a human integrates the branches and
approves an amendment. Superseding the plan through an amendment remains the
alternative to either decision.

REPO-INSPECTION: there is deliberately no override to run concurrently when
declared scopes overlap or are unknown. Uncertain independence keeps the
existing default: fan-out refuses with `:independence_unverified`, and work
proceeds sequentially.

## Verification

VERIFIED: the regression file was copied into an independent archive of
`15bfd17` with its own build and state.
`mix test test/shoestring/cobbler/plan_scope_resolution_regression_test.exs`
exited 2: **1 test, 1 failure**, seed 370530. The baseline CLI refuses the
operator's `resolve-scope` request with `Invalid arguments`, so the recorded
blocker stays permanent. This is the CLI's refusal path, not a missing module.
It also passed on the fix.

VERIFIED: `mix test test/shoestring/cobbler/plan_scope_resolution_test.exs`
exited 0: **5 tests, 0 failures**, seed 611119. Covered: acceptance (commit
kept, single gate charge, acknowledged blocker no longer stops the sibling's
acceptance, dependent still requires integration, rebuild parity); rejection
(retry state, `scope_rejected`, no `needs_user`); replay and conflicts;
invalid-command refusal; registry shape.

VERIFIED: the existing executor event-type enumeration test was updated from 8
to 9 declared types and now also asserts the new type is present.
`mix test test/shoestring/cobbler/plan_executor_test.exs` exited 0: **20 tests,
0 failures**.

## Remaining limits

UNVERIFIED: no live provider run. Acknowledgement is value-exact and
file-level; it does not establish semantic compatibility of the accepted
overlap. Integration of accepted branches remains a human Git operation.

VERIFIED: `mix precommit` exited 0: **4 doctests, 2136 tests, 0 failures,
1 skipped, 6 excluded**, seed 333493, 320.9 s (9.2 s async, 311.7 s sync).
JavaScript passed **52/52** and **8/8**. The first gate attempt failed format
checking on the CLI task; after formatting, the next attempt had one failure:
the event-type enumeration test above. Neither failure is hidden by this
result.
