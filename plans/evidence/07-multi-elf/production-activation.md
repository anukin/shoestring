# Iteration 7: production fan-out activation and human integration

Implementation date: 2026-10-14. Baseline: `42318d7` (partial-failure
recovery). The user's direct-main/no-PR authorization for iteration 7 overrides
the standing worktree/PR workflow. Verification uses Fake admission, local Git
fixtures and injected or real local gates; no provider run was made.

## Activation boundary

REPO-INSPECTION: `PlanExecutionWorker` keeps the sequential executor unless
trusted configuration sets `config :shoestring, :plan_fanout, enabled: true`.
The committed default is `enabled: false`. No plan or model field selects
fan-out. When enabled, concurrency follows `:plan_reservation_policy`; every
limit and unit defaults to one.

REPO-INSPECTION: `PlanFanoutDriver` (queue policy version 1) chooses
deterministically. A new execution uses fan-out only when all three hold:

- the policy admits at least two concurrent children (global, provider-account
  and goal limits of at least 2, and enough shared units);
- at least two first attempts are ready;
- the independence assessment is eligible.

With the default limits of one, fan-out would add integration work and no
concurrency, so the sequential executor runs. An `:independence_unverified`
assessment also falls back to the ordinary sequential executor. The
assessment event is still recorded. Once a child is dispatched, the canonical
dispatch mode fixes the choice for that execution.

REPO-INSPECTION: in fan-out mode each worker step does the following:

- admits ready first attempts and bounded replacements, and waits while
  children run (the existing 5 s worker snooze);
- blocks for an operator when every unresolved child is cancelled or
  interrupted, and waits for quota-sleep children;
- blocks on unresolved scope conflicts (`scope_resolution_required`);
- completes when every required task is accepted and no child is unresolved.

`PlanExecutor.complete_fanout/2` runs the global gates; it refuses while work
is outstanding or the execution is cancelled.

## Human-controlled integration

REPO-INSPECTION: iteration 6 forbids amending the repository contract of
accepted tasks, so a new base cannot be approved after acceptance. Integration
is therefore a separate human fact, `cobbler.plan.integration.recorded`
version 1, recorded with `mix shoestring.execution integrate`. The human
merges the retained private branches in their own repository. Shoestring then
verifies, with read-only Git in that repository, that the named full commit
exists and has the approved base and every accepted commit as ancestors. A
cherry-pick does not qualify. Shoestring never merges or writes to the user's
checkout.

REPO-INSPECTION: an integration covers the execution when it lists every
accepted fan-out commit and no fan-out child is unresolved. From then on,
remaining work uses the ordinary sequential executor:

- the first successor's private store starts from the integration commit;
  later successors chain on accepted commits as before;
- global gates verify in the last accepted worktree, or, when that does not
  contain every accepted commit, in a deterministic private store copied at
  the covering integration commit (or the approved base) for that execution.

Without a covering integration, a dependent stays blocked with
`fanout_inputs_require_integration`, and completion of committed siblings
reports `integration_required`. Children that changed no files are trivially
integrated, so their dependents unlock as soon as both siblings are accepted.

## Verification

VERIFIED: the regression file and the updated fixture helper were copied into
an independent archive of `42318d7` with its own build and state. The helper
change only adds test-only request overrides. `mix test
test/shoestring/cobbler/plan_fanout_activation_regression_test.exs` exited 2:
**1 test, 1 failure**, seed 526879. With fan-out enabled, the baseline
production worker ignored the configuration and dispatched one sequential task
(`dispatch_mode: :sequential`). It passes on the fix.

VERIFIED: `mix test test/shoestring/cobbler/plan_fanout_driver_test.exs` exited
0: **11 tests, 0 failures**. Covered:

- the default-off configuration;
- eligible concurrent dispatch, and waiting without re-admission;
- default limits and uncertain scopes falling back to sequential;
- fan-out completion that also completes the goal row;
- committed siblings blocked for integration with the user repository HEAD
  unchanged, then a verified integration completing in a private verification
  store;
- a dependent blocked until integration, refusal of an integration missing
  accepted work, the dependent starting at the integration commit, and full
  completion;
- integration validation;
- an operator block after cancellations;
- worker routing in both configurations.

VERIFIED: `mix test test/shoestring/cobbler/` exited 0 at **891 tests,
0 failures** before the executor event-type enumeration was updated to 10.
The re-run of that file plus the driver suite exited 0: **29 tests,
0 failures**.

VERIFIED: `mix precommit` exited 0: **4 doctests, 2157 tests, 0 failures,
1 skipped, 6 excluded**, seed 606976, 368.4 s (9.5 s async, 358.9 s sync).
JavaScript passed **52/52** and **8/8**.

## Remaining limits

UNVERIFIED: no live provider fan-out was run, and production enablement was not
exercised against a real Codex or Claude account. Coordinator wakeups rely on
the existing 5 s worker snooze; a cancelled (needs-user) job is re-queued by
`mix shoestring.execution continue` after an operator acts. After integration,
remaining dependents run sequentially even if several are independent.
