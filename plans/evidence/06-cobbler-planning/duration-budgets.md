# Lifetime execution duration

VERIFIED: implementation follows the user's instruction to commit and push
directly on main without a branch or PR, overriding the standing workflow rule.

REPO-INSPECTION: canonical run starting/running and terminal timestamps account
for provider time, including each checkpoint descendant. Task and global gate
evidence contributes gate time. Accounting retains all approved execution
revisions and task attempts; queue time and stopped quota-wait intervals are
excluded. New dispatch and continuation require remaining task and goal time.
Elapsed time alone never interrupts, replaces or duplicates an active Elf.
An active run may finish after its declared duration; the ensuing gate/dispatch
boundary fails closed rather than treating timeout as cancellation authority.

REPO-INSPECTION: gate timeout is the minimum of the configured timeout and
remaining allowance, reduced after each gate. Production wall-clock gate time
is charged even on failure. Injected test runners use synthetic durations.
Global acceptance failures are canonical durable events, block further delivery
and cannot silently rerun after restart. A separately approved amendment is the
bounded recovery path; all consumed gate/provider time remains charged.

VERIFIED: focused final command:

```sh
perl -e 'alarm 180; exec @ARGV' mix test test/shoestring/cobbler/plan_duration_test.exs test/shoestring/cobbler/plan_executor_test.exs test/shoestring/cobbler/plan_amendment_test.exs test/shoestring/cobbler/plan_continuation_test.exs test/shoestring/cobbler/plan_executor_integration_test.exs < /dev/null
```

47 tests, 0 failures; seed 599299; 9.4 seconds. Coverage includes task and goal
exhaustion, amendment carryover, bounded gates, durable global failure, active
run ownership, and exclusion of the interval between stopped quota attempts.
The active-run and paused-interval cases document preserved policy; they are
not claimed as new regression locks.

VERIFIED: isolated pre-fix source is
`0f4e3c78687c384098691af1d83646343ca6c354`. With the new duration test copied
into that archive:

```sh
cd "$REGRESSION"
perl -e 'alarm 180; exec @ARGV' mix test test/shoestring/cobbler/plan_duration_test.exs --only duration_regression < /dev/null
```

5 tests, 5 failures, 1 excluded; seed 961953; 0.3 seconds. The old executor
incorrectly retries or accepts tasks after provider time exhausts their budget,
waits indefinitely for an exhausted quota attempt, and completes global
acceptance beyond the goal allowance. Failures reach existing behavioral APIs;
none depends on a missing module or changed signature.

VERIFIED: final full gate:

```sh
perl -e 'alarm 600; exec @ARGV' mix precommit < /dev/null
```

Exit 0. 4 doctests, 1831 tests, 0 failures, 1 skipped, 6 excluded; seed 69283;
170.6 seconds (9.5 async, 161.1 sync). JavaScript: 52/52 and 8/8, zero failures.
The first full-gate invocation stopped at formatting before tests; the
test-environment formatter corrected it before this final run.

UNVERIFIED: live provider behavior and semantic planning quality were not tested.
All new coverage uses synthetic canonical events, Fake adapters and local gates.
