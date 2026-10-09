# Plan-bound quota continuation

VERIFIED: implementation follows the user's instruction to commit and push
directly on main without a branch or PR, overriding the standing workflow rule.

REPO-INSPECTION: plan attempts reconstruct continuation chains from canonical
run requests, checkpoints and durable dispatch events. The child must preserve
task identity, full plan/agent binding, provider and workspace. Intent creation
and dispatch authorization refuse an active parent, competing continuation,
changed binding/workspace, or already-resolved attempt. Identical existing
intents remain replayable. A request without durable dispatch does not replace
the active plan run. Replayed projection/gates use the latest descendant, but
attempt counters count the original plan dispatch once. Gate resolution of a
descendant resolves its ancestors for subsequent approved amendment activation.

VERIFIED: the composed CLI integration test makes material fixture code changes,
encounters a scripted quota refusal, records deterministic checkpoint evidence,
restarts the application, rechecks synthetic provider-scoped capacity through the
ordinary wake worker and completes the continuation through a dispatch worker.
The ordinary plan worker accepts alpha before dispatching beta; beta inherits
the accepted commit and final global tests pass. Three provider attempts are
two plan-task attempts. The saved model/profile, task, worktree and checkpoint
survive; duplicate wake delivery adds no run. Source checkout contents/HEAD/Git
status remain unchanged. No provider CLI, network or paid inference is used.

VERIFIED: this integration exposed a producer/consumer identity defect.
Elves writes terminal idempotency keys using dispatch ID. Quota wake eligibility
looked them up using run ID, which differs for plan dispatch. The corrected
lookup uses dispatch ID; explicit cancellation already uses that identity too.

VERIFIED: focused final command:

```sh
perl -e 'alarm 180; exec @ARGV' mix test test/shoestring/cobbler/plan_continuation_test.exs test/shoestring/cobbler/wakeup_continuation_test.exs test/shoestring/cobbler/plan_executor_integration_test.exs < /dev/null
```

20 tests, 0 failures; seed 675133; 8.8 seconds. This includes multi-hop
continuation, exact old-intent replay, dependency unlocking, amendment activation
and refusal before persisting invalid intents. Two untagged tests document
existing no-delivery and invalid-profile protections; they are not claimed as
new regression locks. Earlier development failures exposed incomplete quota
fixture setup, the terminal-key defect and a replay test that incorrectly used
the composed execution prompt instead of the original request; each was fixed.

VERIFIED: isolated pre-fix source is
`7c5fb068b40232ace368c0ecca1e5624ba9c2889`. With the new test file copied into
that archive:

```sh
cd "$REGRESSION"
perl -e 'alarm 180; exec @ARGV' mix test test/shoestring/cobbler/plan_continuation_test.exs --only plan_continuation_regression < /dev/null
```

8 tests, 8 failures, 2 excluded; seed 79165; 0.3 seconds. Failures are behavioral:
continuations remain unknown/unaccepted, dependent tasks stay waiting, and
invalid/competing intents are accepted. No missing module/API failure is used.
Running the new integration file against that same pre-fix source separately
fails at the real wake worker with `unexpected_run_state: failed`: 1 outer test,
1 failure; seed 993082; 5.1 seconds (child: 2 tests, 1 failure, seed 0, 3.9 seconds).

VERIFIED: final full gate:

```sh
perl -e 'alarm 600; exec @ARGV' mix precommit < /dev/null
```

Exit 0. 4 doctests, 1824 tests, 0 failures, 1 skipped, 6 excluded; seed 776098;
164.3 seconds (8.7 async, 155.5 sync). JavaScript: 52/52 and 8/8, zero failures.

UNVERIFIED: cross-provider plan handoff remains unsupported by this binding;
it cannot silently switch the pinned agent/provider/model. Full elapsed run-time
budget accounting, model-assisted amendment and explicit retirement remain open.
