# Iteration 7: goal row follows goal cancellation

Implementation date: 2026-10-14. Baseline: `4b1d0c4` (iteration 7 closure). The
user asked to close retained limit 6 of the final acceptance packet ("a goal
cancellation leaves the generic goal row `active`"). The direct-main/no-PR
authorization for iteration 7 still applies. Verification is hermetic; no
provider run was made.

## Change

REPO-INSPECTION: `Shoestring.Cobbler.PlanGoalStatus` already derived the
generic goal row from `cobbler.plan.execution.requested` (`active`) and
`cobbler.plan.execution.completed` (`completed`). It now also treats a
goal-scope `cobbler.plan.cancellation.requested` as `cancelled`:

- The row moves at the request, the same moment `PlanExecutor.status` reports
  `cancelled?: true` and dispatch, advance, completion and continuations start
  refusing with `:execution_cancelled`. Whether every child has stopped stays
  in the status `cancellations` view (`completed?`, outcomes), not in the row.
- A child-scope cancellation never changes the row.
- A later execution request reopens the row to `active`. `archived` and the
  protected observatory goal are never moved, as before.
- The same rule runs in the writer transaction, in startup repair
  (`PlanGoalStatus.reconcile/1`) and in the goal/task projector rebuild.
- `Goal` accepts `cancelled` as a status. The column is a plain string with no
  database constraint, so there is no migration.
- Wakeups treat `cancelled` as a terminal goal status, like `completed` and
  `archived`: a recheck is refused and a live wakeup is retired.

The UI goal state is derived from the trajectory, not this row, so it is
unchanged.

## Regression verification

VERIFIED: the new and changed tests were copied into an independent archive of
`4b1d0c4` with its own `_build` and test state directory. The user's checkout
was not reset. `mix test test/shoestring/cobbler/plan_goal_status_test.exs
test/shoestring/cobbler/plan_partial_failure_test.exs
test/shoestring/cobbler/manual_recheck_test.exs` exited 2: **23 tests,
5 failures**. Every failure is a behavioral assertion:

| Test | Baseline result |
| --- | --- |
| partial failure: goal cancellation (real `PlanCancellation.request/3`) | row `active`, expected `cancelled` |
| goal status: cancellation cancels, later request reopens | row `active` |
| goal status: projector rebuild parity | row `active` |
| goal status: paged startup repair | did not repair the cancelled goal |
| manual recheck: cancelled goal is terminal | recheck scheduled a wakeup |

The child-scope and archived assertions pass on both commits; they guard the
"never moves" direction rather than lock the regression.

VERIFIED: the same files on the fix: **24 tests, 0 failures** (12.6 s).

## Test-order defect found by the gate

VERIFIED: the first full gate on this change exited 0. The second exited 2
with **4 doctests, 2165 tests, 1 failure, 1 skipped (6 excluded)**, seed
530150: `shoestring_execution_test.exs` "worker with no matching observation
waits" raised `FunctionClauseError` in `Keyword.get(nil, :clock, …)` from
`PlanExecutionWorker.options/1`. This was intermittent, 1 of 2 gate runs.

REPO-INSPECTION: cause: `plan_fanout_activation_regression_test.exs` (added
in `e63314c`) restored unset application keys with `put_env(key, nil)`.
`Application.get_env(:shoestring, :plan_execution_opts, [])` returns the
default only for an absent key, so any later worker test in the run received
`nil`. The fix restores with `fetch_env`, deleting keys that were absent.
No other test file used that restore pattern. Production code was not changed
for this.

VERIFIED: in the baseline archive (made a throwaway Git repository so the CLI
repository check passes), the two files together failed **9 tests, 1 failure**
with that `FunctionClauseError` on seeds 1–6 (6 of 6). On the fix, the same
pair passed **9 tests, 0 failures** on seeds 1–6 and on seed 530150.

## Gate

VERIFIED: `mix precommit` exited 0: **4 doctests, 2165 tests, 0 failures,
1 skipped (6 excluded)**, seed 408687, 430.4 s (9.5 s async, 420.9 s sync).
JavaScript passed **52/52** and **8/8**.
