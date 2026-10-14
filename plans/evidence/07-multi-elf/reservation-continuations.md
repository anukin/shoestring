# Reservation-backed continuations — 2026-10-13

REPO-INSPECTION addendum: [CLI inspection and recovery](reservation-cli-recovery.md)
subsequently added operator visibility and cancellation of provably never-started
intent. Counts and remaining-work notes below describe this package's point in
time; unknown-effect and lost-identity histories remain held.

## Scope

VERIFIED (user direction): continue iteration 7 directly on main without a PR,
overriding the standing worktree/PR workflow. Baseline:
`14f122a06ca0e7e58eadfe52bc39ca2c87e1931d`. No provider calls were made.

REPO-INSPECTION: this extends [atomic initial dispatch](atomic-plan-dispatch.md)
to same-provider wakes and explicitly authorized cross-provider handoffs.
Reserved continuations close verified predecessor consumption and acquire
fresh ownership, run/lease intent and delivery in one immediate transaction.
Wake completion status and the handoff pointer commit in that transaction too.
Admission observations/decisions precede it and remain diagnostic evidence if
intent creation fails. Unreserved legacy paths retain their existing behavior.

REPO-INSPECTION: initial reservations remain opt-in through trusted runtime
configuration. A continuation of an existing reserved run always uses its
predecessor's recorded policy, even if current configuration is disabled or
different. Planner output cannot select it. Parallel claims remain disabled;
this package does not change the sequential global claim or enable fan-out.

## Ownership and settlement

REPO-INSPECTION: the migration adds a nullable, restrictive parent foreign key,
retains root uniqueness for `(goal, execution, task, attempt)`, and enforces
one successor per parent with a unique index. No reservation or settlement
row is deleted. A continuation keeps the original execution/task/attempt and
records a new run, admission, snapshot, provider/scope and configured allowance.
The wake/handoff ID supplies its stable run and reservation identity.

REPO-INSPECTION: a predecessor must have a consumed/closed settlement, not
an unused release. The new canonical admission must name that predecessor's
run, and the child must retain its goal/execution/task/attempt. Existing
approval, checkpoint lineage, saved-role, claim and budget checks still apply
before fresh delivery. The hypothetical handoff preflight does not inherit a
reservation marker; the actual receiver binds its own fresh owner atomically.

REPO-INSPECTION: a terminal plus absent Elf and verified absent recorded groups
is required. Live/unknown groups, invalid or absent process identity, and a
suspended checkpoint without a terminal retain capacity. Uncertainty is
recorded durably without creating a child. A failed successor write rolls
back both predecessor settlement and fresh ownership. No deadline, quiet
period or missing response cancels/replaces useful work.

REPO-INSPECTION: reserved wakes leave the predecessor terminal and its old lease
history intact; they no longer mark that predecessor starting or renew its
consumed allowance. The successor gets its own lease chained to fresh admitted
capacity. Replays of committed wakes/handoffs do not re-observe, re-probe or
allocate another owner.

REPO-INSPECTION: explicit plan advancement now reconciles this goal's terminal
owners through the same evidence-backed probe before further dispatch or a
completed result. Nonterminal owners are untouched. This frees verified prior
consumption for the next dependency and closes the final task's allowance.
It introduces no background timer, cancellation, orphan cleanup or automatic
release based only on status projection.

## Verification

VERIFIED: new tests cover both wake and handoff ownership, immutable attempt
identity, fresh admissions/snapshots/leases, replay, live/unknown process groups,
and suspension without a terminal. Database triggers abort handoff pointer,
dispatch-event and wake-status writes; predecessor settlement, successor
ownership/run/delivery and wake completion roll back together. The ordinary
claim, plan authority, saved-role and lineage twin suites are also exercised.

VERIFIED: two competing child candidates produce exactly one successor and
one structured uniqueness conflict. Changed goal/execution/task/attempt
identities are refused. A populated-table upgrade test compares every
pre-existing SQL column/value before and after the migration, then proves
the original owner still replays. Scratch fixtures include all **22 migrations**.

VERIFIED: the isolated child node uses a normal connection pool and real local
Fake-owned process groups. Its new scenario drives quota refusal through the
production dispatch worker, restarts the application, invokes the production
wake worker with hermetic observed capacity, checks fresh child ownership,
restarts before child delivery, completes the child and dependent task, and
automatically settles all three owners during plan advancement. Task attempts
remain **2** (one continued attempt plus its dependent), and the source checkout
is unchanged. The child suite now requires **3 tests, 0 failures**; the full
gate counts its wrapper as one outer test. Existing natural-completion and
four-caller dispatch convergence scenarios remain in that suite.

## Failures retained and exact focused results

VERIFIED: the first focused run failed in the existing eight-caller exact
acquisition replay test with native SQLite `BEGIN IMMEDIATE` lock errors.
Standalone acquisitions now share the supervised local FIFO writer already
used for reconciliation/atomic intent. Calls inside a transaction keep the
caller's connection. There are no SQL retries, sleeps, longer busy timeouts or
weaker assertions. The eight-caller acquisition checks now exercise queued
local delivery; they are not presented as eight simultaneous SQLite writers.
The distinct intent-versus-release race still uses separate processes and
connections. No distributed or multi-node contention guarantee is claimed.

The focused file set evolved as follows:

```text
mix test test/shoestring/cobbler/reservations_test.exs test/shoestring/cobbler/plan_dispatch_test.exs test/shoestring/cobbler/plan_handoff_test.exs test/shoestring/cobbler/wakeup_continuation_test.exs
```

Run 2 adds `test/shoestring/cobbler/reservation_continuation_test.exs`.
Runs 3–5 also add `test/shoestring/cobbler/plan_dispatch_integration_test.exs`.

| Run | Exit | Actual result | Seed | Duration | Finding/change before next run |
| --- | --- | --- | --- | --- | --- |
| 1 | 2 | 63 tests, 1 failure | 547544 | 8.4s sync | Acquisition busy-lock failure; serialize acquisition with the existing writer |
| 2 | 0 | 72 tests, 0 failures | 737392 | 3.7s sync | Fresh ownership, uncertainty and rollback checks passed |
| 3 | 2 | 73 tests, 1 failure | 494101 | 9.4s sync | Child quota fixture lacked weekly capacity, so admission correctly required confirmation; its retained owner blocked the next child test. Also corrected a test aggregate call |
| 4 | 0 | 73 tests, 0 failures | 116850 | 13.1s sync | Complete capacity fixture; real quota wake/restart lifecycle passed |
| 5 | 0 | 76 tests, 0 failures | 446028 | 12.8s sync | Added populated migration, one-successor and immutable-identity checks |

VERIFIED: the first `mix precommit` exited **1** at formatting after
**0.941 seconds**, before tests. A second format pass applied the remaining
multiline migration/helper layout. No test assertion or timeout was changed.

VERIFIED: the final `mix precommit` exited **0**: **4 doctests, 1992 tests,
0 failures, 1 skipped (6 excluded)**, seed **342664**, **197.0 seconds**
(10.7 async, 186.3 sync), wall **200.923 seconds**. JavaScript passed **52/52**
and **8/8**, with zero failures or skips. Mix commands ran in the foreground
with stdin closed; focused runs used a 180-second bound, the full gate a
480-second bound, and the isolated child its existing 90-second bound.

VERIFIED: all **15 relative Markdown links** across iteration-7 milestone and
evidence documents resolve. New artifacts pass home-path, credential-pattern
and authorship-trailer checks. The final staged diff passes
`git diff --cached --check`.

REPO-INSPECTION: the continuation and migration tests are new-capability checks;
no regression lock against the baseline is claimed. The acquisition failure
was observed in this run before its implementation change; it was not rerun
unchanged until green. Its repeat rate is unknown, so no intermittent frequency
is claimed. The existing focused suite emits an unused `Oban.Job` alias warning
from `wakeup_continuation_test.exs`; that file is unchanged.

## Remaining work and limits

REPO-INSPECTION: CLI ownership inspection/reconciliation, explicit cancellation
and release of existing never-started/ambiguous intents, independence/overlap
policy, sibling base isolation, durable child inbox/wakeups and partial-failure
recovery remain. Keep reservation-backed initial execution opt-in until those
operator recovery paths are available. Iteration-6 status, public output and
verification-budget follow-ups also remain before fan-out.

UNVERIFIED: I did not verify live providers, parallel runs, distributed fairness,
release of every ambiguous launch state or recovery from arbitrary process
identity loss. A suspension without canonical terminal/ownership proof still
blocks fresh consumption; it is not silently converted into cancellation.
