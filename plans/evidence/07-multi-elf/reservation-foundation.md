# Configured reservation foundation — 2026-10-13

## Scope and authorization

VERIFIED (conversation): the user accepted iteration 6 and authorized starting
iteration 7. Its [accepted closure](../06-cobbler-planning/final-acceptance.md)
retains all evidence limits. Implementation started from commit
`727f7d324c0801150886744d69b0f89b8ebf94b0`.

VERIFIED (user direction): work is directly on main without a PR. This overrides
the standing isolation/branch/PR workflow for this change. No provider calls
were made. No UI execution controls were added; execution remains a CLI workflow.

## Implemented boundary

REPO-INSPECTION: `ReservationPolicy` version 1 defaults global,
provider-account and goal concurrency limits, shared account units and per-task
weight to **one**. Values must be integers from 1 to 64 and a task's weight
cannot exceed the shared allowance. These are configured weights, not provider
percentage predictions or guarantees. The caller supplies trusted operator
configuration; model output does not choose the limits.

REPO-INSPECTION: `Reservations.hold/3` serializes reads and acquisition inside an
immediate SQLite write transaction. It retains stable reservation, goal,
execution, logical plan-task, attempt and future run identities; the admitted
canonical event; observation identity/age at grant; admission policy; configured
concurrency policy; configured units; and admission lease bounds/deadline.
Provider and submission scope come from the admission event. Until account
discovery exists, all local goals sharing that pair share a single bucket.
Observation changes cannot create another allowance bucket. Missing observation
time remains unknown; a snapshot identity is mandatory. A missing/refused,
foreign-goal, foreign-run or expired admission cannot grant a new reservation.

REPO-INSPECTION: an exact replay returns the original row, including after a
deadline or repository restart. Changed ownership or policy cannot rebind it.
Database uniqueness also prevents reuse of a run, admission event or
goal/execution/task/attempt under a different reservation ID. No run is created
by holding capacity. Existing ownership must be reconciled before changing the
global configured policy; raising a limit does not erase prior ownership.

REPO-INSPECTION: states currently implemented are `held` and
`reconciliation_required`. Both occupy all applicable allowances. Explicit
reconciliation flags retain a bounded reason and cannot silently overwrite it.
Elapsed time never frees a slot, interrupts a process or authorizes replacement.
No release, expiry, timer, cleanup or reaper path was introduced.

## Runtime verification

VERIFIED: the focused command
`mix test test/shoestring/cobbler/reservation_policy_test.exs test/shoestring/cobbler/reservations_test.exs`
exited **0**, **16 tests, 0 failures**, seed **768434**, **0.9 seconds**
(0.2 async, 0.7 sync). Tests are new-capability checks; they are not claimed as
regression locks against the pre-change commit, which has no reservation API.

VERIFIED: the tests migrate the complete 20-migration history into fresh scratch
SQLite databases using one connection, then reopen with eight independent
connections. There is no SQL sandbox serialization in the race tests. A start
barrier releases eight supervised tasks together: three independent candidates
acquire the three shared units, five receive `account_units` refusals. Eight
concurrent exact replays all return one durable reservation. Reopening the
repository preserves exact ownership and does not create a second row.

VERIFIED: separate assertions cover global, provider-account, goal and weighted
unit caps, unrelated-provider progress, immutable replay, duplicate attempt/run/
admission ownership, unknown observation time, malformed identity, refused and
expired admissions, overdue ownership, and policy-change refusal. No provider
CLI, network, sleep or retry is used. Scratch databases are retained rather than
adding cleanup behavior.

VERIFIED: the first focused run had **15 tests, 13 failures**, seed **905288**,
**3.8 seconds**; all reservation tests failed during setup before assertions when
historical table rebuilds encountered an existing capacity-window index. The
fixture originally ran the entire migration history on eight connections.
Historical rebuilds use connection-local PRAGMA switches; existing foundation
migration tests use one connection. The corrected fixture migrates on one
connection before reopening eight for the actual races. A separate standalone
one-connection fresh-history trace also exited 0. No historical migration or
test assertion was weakened, and this does not claim a production migration fix.

VERIFIED: the second focused run had **15 tests, 1 failure**, seed **202225**,
**0.9 seconds**. The new attempt uniqueness constraint had a custom name, while
SQLite's error exposed the generated column-based name. The migration and
changeset now agree on that name, preserving the uniqueness check and returning
a structured conflict. An additional boundary check brought the final focused
suite to 16 tests. Neither failure is described as intermittent.

VERIFIED: `mix precommit` exited **0**: **4 doctests, 1953 tests, 0 failures,
1 skipped (6 excluded)**, seed **958330**, **179.5 seconds** (9.2 async,
170.2 sync). The JavaScript suites passed **52/52** and **8/8**, zero skips.
The foreground process had closed stdin and a 480-second timeout; wall time
was **185.978 seconds**. Test-file unused-alias/variable and migration-module
redefinition warnings did not fail the gate. No tests were skipped, retried or
loosened by this change.

VERIFIED: all **20** numbered production migrations are included in the scratch
fixture. All **4** relative links in the new iteration-7 documents resolve;
new artifacts passed the path/credential/attribution scan, and
`git diff --check` passed. These checks did not modify captured iteration-6
evidence or unrelated local directories.

## Remaining before fan-out

REPO-INSPECTION: this completes the initial durable acquisition portion of
package B, not all of package B or iteration 7. The sequential production
dispatcher and its global exclusive claim remain in effect. No production
parallelism, fairness simulation, live provider fan-out, or terminal-release
proof is claimed.

- Integrate terminal/confirmed-orphan reconciliation, with explicit proof that
  owned effects stopped or never began. An uncertain owner must still count.
- Bind approved execution/revision/task authority and readiness in the
  coordinator. The ledger itself does not validate plan approval or dependencies.
- Persist reservation ownership and deterministic dispatch intent atomically;
  require valid held ownership at effect claim, and reconcile intent/effect
  ambiguity before retrying. A successful replay alone never permits a relaunch.
- Coordinate the legacy global task claim, lease admission and cancellation with
  multiple children; prove no bypass of existing admission or ownership checks.
- Add independence/overlap policy, sibling bases/branches, durable inbox/wakeups,
  partial failure/replacement and CLI reporting.
- Resolve the inherited canonical/generic goal status, global gate budget margin
  and bounded full public Claude output follow-ups before enabling fan-out.

UNVERIFIED: I did not verify production parallel execution or a live model run
with this layer. The implementation is deliberately not wired to launch Elves.
