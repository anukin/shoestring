# Iteration 7: pre-fan-out prerequisites

Implementation date: 2026-10-14. Baseline:
`4421167` (durable child inbox). The user's direct-main/no-PR authorization for
iteration 7 overrides the standing worktree/PR workflow for this checkpoint.
All verification uses Fake, local Git fixtures and injected gate runners; no
provider run was made.

The [iteration-6 closure](../06-cobbler-planning/final-acceptance.md) and every
earlier iteration-7 package retained three activation prerequisites: generic
goal-row synchronization, whole-lifecycle verification budgeting and bounded
public Claude output. This package addresses all three.

## Generic goal-row synchronization

REPO-INSPECTION: `Shoestring.Cobbler.PlanGoalStatus` treats the generic goal
row as a derived cache of two canonical facts.
`cobbler.plan.execution.completed` sets the row to `completed`, and a later
`cobbler.plan.execution.requested` sets it back to `active`. `archived` and the
protected observatory status never move. A single pure transition
(`status_after/2`) is shared by three callers: the trajectory writer, the
direct `Plans` event insertion path, and the goal/task projector.

REPO-INSPECTION: capture runs inside the append transaction, so the source event
and row update commit or roll back together. An inserted completion naming any
execution other than the latest request is refused with
`:stale_plan_execution_completion`. Because the log cannot contain a stale
completion, event order alone determines status, and projector replay and the
writer derive the same row.

REPO-INSPECTION: `PlanExecutionReconciler` now first re-derives every planned
goal at startup, in bounded 128-goal pages, then repairs execution delivery.
Each pass is failure-isolated and logged; neither appends events or touches
runs. This repairs rows completed before this change.

REPO-INSPECTION: consequences of a `completed` row: the existing wakeup path
already treats `completed` as terminal, and model planner requests require an
`active` goal. A completed planned goal therefore stops wakeups and refuses new
model planning until an approved execution request reopens it. No call site's
semantics were changed to achieve this.

## Whole-lifecycle verification budget

REPO-INSPECTION: fan-out final-scope verification (`PlanFanout.final_scope/5`)
was bounded per Git command but uncharged. The executor now measures it with a
monotonic clock before the serialized write transaction, so writer waiting is
not charged. It records the result as `verification_overhead_ms` on the
`cobbler.plan.task.accepted` or `cobbler.plan.task.scope_blocked` event. The
registry accepts only integers from 0 to 86,400,000. `PlanBudget` adds it to
`total_duration_ms` and exposes `total_verification_overhead_ms`. It is
goal-level overhead and is never charged to the task's own allowance. Replay
neither re-measures nor double-charges it.

REPO-INSPECTION: `ScopeEvidence.final_scope_bound_ms/1` states the worst case:
the tested commit is observed twice (7 commands each), the source base once (3)
and each known child once (at most 7), so `17 + 7 × children` commands at 5 s
each. Fan-out duration admission now reserves, beyond each held owner's task
allowance and every global gate at its command timeout, one final-scope bound
per held owner. The child count is bounded by the plan's lifetime attempt limit.
These are conservative configured bounds, not forecasts. No deadline interrupts
an Elf.

REPO-INSPECTION: dispatch-time scope preflight is admission evidence. Like
capacity admission, it is bounded per command and is not charged to run
duration. Sequential (non-fan-out) budgeting is unchanged. The receipt
evaluation's tight sequential worst case, recorded in iteration 6, remains a
recorded property of that plan rather than an enforced reserve.

## Bounded public Claude output

REPO-INSPECTION: the Claude normalizer previously cut assistant/user text to
500 characters without marking it. Separately, any text containing a credential
marker (e.g. `token:`) failed contract validation and the whole public output
event was dropped with only a log warning. Both were silent losses.

REPO-INSPECTION: public text blocks are now retained in full after
`Security.redact_retained/1`. That function applies every existing redaction
pattern without the 200-character diagnostic limit, then replaces each remaining
credential marker together with its value. The retained text always passes the
secret filter, and surrounding prose survives. A block over 262,144 bytes (the
default transport frame cap) fails the run with a terminal `:task_failed`
`output_oversized` error event and its byte count; it is never truncated. Tool
stdout, stderr and result text remain 500-character diagnostic previews.
Truncation is now explicit (`*_truncated` and `*_bytes` extensions). Thinking
and reasoning blocks are still never persisted.

## Regression and focused verification

VERIFIED: three regression files were copied into an independent archive of
the baseline commit, with its own `_build` and test state directory. The
user's source checkout was not reset.
`mix test test/shoestring/cobbler/plan_goal_status_regression_test.exs
test/shoestring/cobbler/plan_verification_budget_regression_test.exs` exited 2:
**2 tests, 2 failures**, seed 947464, 1.1 s. The baseline left the goal row
`active` after `completed?: true` and dispatched `north` with no verification
allowance. `mix test
test/shoestring/harness/claude_headless/public_output_regression_test.exs`
exited 2: **2 tests, 2 failures**, seed 541596. The baseline kept 500 of 2,400
characters and returned `{:ok, []}` for a credential-marker text. All failures
are behavioral assertions, not missing modules or signatures.

VERIFIED: focused runs on the fix exited 0: goal status **5 tests, 0 failures**
(stale refusal, reopen, archived, paged repair, projector parity); verification
budget **5 tests, 0 failures** (bound arithmetic, exact admission boundary,
measured charge excluded from the task, replay/rebuild, field bounds); Claude
headless plus security **49 tests, 0 failures**. The latter covers secret
removal in both directions, full user text, the exact byte boundary, oversized
failure and explicit preview flags.

VERIFIED: `mix precommit` exited 0: **4 doctests, 2130 tests, 0 failures,
1 skipped, 6 excluded**, seed 125912, 302.4 s (9.4 s async, 293.0 s sync).
Format checking and compilation with warnings-as-errors passed. JavaScript
passed **52/52** and **8/8**, with zero failures or skips.

## Remaining limits

UNVERIFIED: no live Claude run exercised full-output retention; the transport
frame cap and redaction are verified hermetically only. Redaction is
pattern-based and does not claim to detect every secret shape. A large retained
history increases trajectory storage; its throughput was not measured.
Production fan-out remains disabled. Explicit conflict resolution, bounded
replacement and goal cancellation follow in subsequent packages.
