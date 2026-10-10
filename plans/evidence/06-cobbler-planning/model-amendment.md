# Bounded model-assisted amendment

VERIFIED: implementation follows the user's instruction to commit and push
directly on main without a branch or PR, overriding the standing workflow rule.

REPO-INSPECTION: one canonical amendment request reuses the existing per-goal
planner ledger. Initial calls, amendment and repair share two lifetime calls
and the original full output reservation per admitted call. The initial input
and all outcomes remain in canonical history; the cached current context is
replaced only by the explicit amendment event. New keys, configuration changes,
restart, rejection and adoption cannot replenish allowance. A manual initial
plan has the same two-call cap. A third execution revision cannot obtain a new
amendment allowance after the bounded activation limit is spent.

REPO-INSPECTION: model context binds the reviewed approved parent number/digest,
current canonical plan, fixed goal constraints, all accepted task IDs, a human
reason of at most 500 characters and up to 15 canonical checkpoint/gate
summaries. The projection remains capped at 24,576 bytes and security scanned;
unsafe or oversized context is refused rather than truncated. Replay verifies
the parent approval/content and accepted IDs against earlier canonical events.
No raw transcript or hidden model reasoning enters this context.

REPO-INSPECTION: every approved task ID remains present. Accepted task contracts
and existing human retirements remain exact. Models cannot author retirements;
those require human JSON edits. Inference requires fresh capacity admission and
cannot release an unresolved plan run to obtain a planning claim. Only the
explicit request can release a resolved plan dispatch claim. Running or lost
inference stays owned across restart, retaining its charge; transport failure
never starts an automatic repair. Schema/unsafe output permits one explicit
repair only when the shared allowance remains.

REPO-INSPECTION: `mix shoestring.plans replan`, `generate-amendment`, `repair`,
`planner` and `adopt` provide the CLI path. Generation owns one bounded local
Task supervisor and starts no application workers. A candidate remains inert.
Human adoption checks the exact result digest, reviewed parent authority inside
the plan store transaction and current accepted evidence. Separate approval and
execution activation remain mandatory and recheck accepted evidence again.
The initial and amendment candidates have distinct durable proposal IDs.

VERIFIED: focused final command:

```sh
perl -e 'alarm 180; exec @ARGV' mix test test/shoestring/cobbler/planner_amendment_test.exs test/shoestring/cobbler/plan_amendment_parent_test.exs test/shoestring/cobbler/planner_test.exs test/shoestring/cobbler/planner_ollama_test.exs test/mix/tasks/shoestring_plans_test.exs < /dev/null
```

64 tests, 0 failures; seed 118266; 3.3 seconds (0.6 async, 2.7 sync). The
composed fixture flow accepts alpha, fails beta's gate, spends the remaining
planner call, adopts and approves revision two, preserves alpha evidence and
retries only beta. Other coverage includes lost-result supervisor restart,
in-flight refusal, exhausted allowance, active-run preservation, forged
canonical context, evidence arriving after inference, stale parents, retained
retirements, oversized context and the ordinary CLI generation/adoption path.
New model-amendment APIs are feature coverage, not claimed as regression tests
against a commit that lacked those APIs.

VERIFIED: the two parent authority checks use the existing Plans.propose API
and were run against isolated pre-change source
`9682602b4ae73834609f373804b87cbc214e3b5f`:

```sh
cd "$REGRESSION"
perl -e 'alarm 180; exec @ARGV' mix test test/shoestring/cobbler/plan_amendment_parent_test.exs --only amendment_parent_regression < /dev/null
```

2 tests, 2 failures, 1 excluded; seed 63966; 0.1 seconds. Old code ignores
the supplied parent digest and persists a stale-parent proposal. Failures are
behavioral, without missing modules or changed signatures. Identical already
recorded adoption still replays after authority moves; it creates no new proposal.

VERIFIED: development failures exposed the need to preserve existing repair
error semantics, accept underscores in canonical gate-failure references,
unwrap `:ok` guard results, and keep adoption inside the plan store transaction
instead of nesting a second planner transaction. Each was corrected before the
final focused run. No assertion was loosened and no retry/sleep was introduced.

VERIFIED: final full gate:

```sh
perl -e 'alarm 600; exec @ARGV' mix precommit < /dev/null
```

Exit 0. 4 doctests, 1857 tests, 0 failures, 1 skipped, 6 excluded; seed 550953;
169.3 seconds (8.8 async, 160.4 sync). JavaScript: 52/52 and 8/8, zero failures.

UNVERIFIED: live provider behavior and semantic model quality were not tested.
Fixture inference, synthetic scoped capacity and local gate evidence were used.
Activation still refuses unresolved runs, including stopped quota attempts
without canonical resolution; checkpoint-bound amendment activation remains
separate lifecycle work. Cross-provider plan handoff also remains open.
