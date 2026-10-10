# Approval-gated checkpoint amendment

VERIFIED: this work follows the user's explicit main/no-PR instruction,
overriding the standing isolation and PR workflow rules.

REPO-INSPECTION: an explicitly activated, approved new revision can supersede
the current attempt at a definitive quota failure, interruption or cancellation
with an owned checkpoint. The terminal event must carry the Elf's dispatch-bound
terminal idempotency key. A suspension record alone is insufficient: it can be
written while a safe stop is still pending. No Elf may still own any run in the
attempt, and an undelivered competing continuation prevents replacement.

REPO-INSPECTION: activation appends `cobbler.plan.task.superseded` and the new
execution request in the same canonical transaction. It does not create a run,
accept the stopped work, cancel a process or reset lifetime attempts/durations.
The old checkpoint, task/worktree bindings and accepted evidence remain intact.
Old attempt continuations are then refused. Model-assisted replan can use the
same stopped boundary, but proposal/adoption/approval alone do not supersede it.
Successful runs awaiting gates and transport failures still need normal task
resolution. This closes the checkpoint activation gap recorded historically in
`model-amendment.md`.

VERIFIED: focused final command:

```sh
perl -e 'alarm 180; exec @ARGV' mix test test/shoestring/cobbler/plan_checkpoint_amendment_test.exs test/shoestring/cobbler/plan_amendment_test.exs test/shoestring/cobbler/plan_continuation_test.exs test/shoestring/cobbler/planner_amendment_test.exs < /dev/null
```

46 tests, 0 failures; seed 344731; 2.1 seconds. The new file covers activation
and replay, approval refusal, model amendment after accepted work, live ownership,
missing checkpoints, unowned terminal evidence, suspension, competing intent,
multiple continuation ancestors, duration carryover, interruption and cancellation.
An initial fixture compilation error (reserved module attribute) was corrected.
Two earlier full-gate invocations stopped at formatting before running tests;
formatting was corrected without weakening the gate.

VERIFIED: two regression assertions were run against pre-fix source
`37923839a24c1cd7c876c29ac1791f528243080d`, with the new test file copied into
an isolated archive:

```sh
perl -e 'alarm 180; exec @ARGV' mix test test/shoestring/cobbler/plan_checkpoint_amendment_test.exs --only checkpoint_amendment_regression < /dev/null
```

2 tests, 2 failures, 11 excluded; seed 356112; 0.4 seconds. Both fail through
existing public APIs with `active_plan_execution`: approved checkpoint activation
and model amendment at a stopped checkpoint were previously blocked. Neither
failure depends on a missing API or changed signature.

VERIFIED: final full gate command:

```sh
perl -e 'alarm 600; exec @ARGV' mix precommit < /dev/null
```

4 doctests, 1870 tests, 0 failures, 1 skipped, 6 excluded; seed 728599;
172.7 seconds (9.5 async, 163.2 sync). JavaScript: 52/52 and 8/8, zero failures.
The complete gate output was inspected; its process exit return was not retained
across the session handoff. No tests were skipped or retried to make this change pass.

UNVERIFIED: no live provider, network or model quality evaluation was performed.
Cross-provider plan handoff remains separate work.
