# Durable CLI execution and worker delivery

VERIFIED: this slice follows the user's explicit instruction to work, commit
and push directly on main without a new branch or PR, overriding the standing
branch/isolation/PR rule for this implementation.

REPO-INSPECTION: `mix shoestring.execution start/status/continue` uses
repository-only startup plus a queue-only Oban client. Start atomically records
an exact approved-plan/saved-agent/repository/human-attribution intent and its
delivery job. Jobs carry goal/execution IDs only. Replay checks the full stored
payload. A dedicated ordinary worker advances the sequential executor, and a
startup-only reconciler restores lost delivery jobs without replacing active
Elves or resetting attempts. CLI status exposes the latest historical admission
and cached provider/scope observation availability.

VERIFIED: the hermetic CLI integration test queues without a run, then ordinary
workers make two material code changes in owned Git worktrees. Alpha's test
passes before beta dispatches; beta inherits alpha's accepted commit and both
tests pass globally. An application restart between tasks preserves acceptance,
two lifetime attempts and the selected agent/model. Source HEAD, contents and
Git status remain unchanged. No provider CLI, network or paid inference is used.

VERIFIED: focused verification before the final two regression additions:

```sh
perl -e 'alarm 180; exec @ARGV' mix test test/mix/tasks/shoestring_execution_test.exs test/shoestring/cobbler/plan_executor_integration_test.exs test/shoestring/cobbler/execution_profile_test.exs < /dev/null
```

13 tests, 0 failures; seed 201066; 8.3 seconds. The isolated integration node
contains two passing tests. Earlier development runs failed due to a fixture
workdir lookup, an incomplete capacity fixture, an incorrect option-list index,
and a wrong goal-schema reference; these were corrected, not retried unchanged.

VERIFIED: both new admission assertions fail behaviorally against pre-fix
`37e6e65b21eddad3f0cc66457361cb6e7e1bf527`, using its source archive plus the new
test file. Command:

```sh
cd "$REGRESSION"
perl -e 'alarm 180; exec @ARGV' mix test test/shoestring/cobbler/execution_profile_test.exs --only execution_boundary_regression < /dev/null
```

2 tests, 2 failures, 6 excluded; seed 897175; 0.3 seconds. The old code refuses
configured execution intent without admission and dispatches using the old
decision while ignoring the fresh-admission callback. Neither failure is a
missing module/API/signature.

VERIFIED: final repository gate:

```sh
perl -e 'alarm 600; exec @ARGV' mix precommit < /dev/null
```

Exit 0. 4 doctests, 1814 tests, 0 failures, 1 skipped, 6 excluded; seed 717227;
169.1 seconds (8.7 async, 160.3 sync). JavaScript suites: 52/52 and 8/8, zero
failures. Existing deliberate fault tests emit warnings/error logs; the observed
suite result above is authoritative.

UNVERIFIED: live provider execution and unknown-capacity manual confirmation
are not proved here. Plan-bound wake/handoff adoption, full run-duration
accounting, model-assisted amendment and explicit retirement remain open.
