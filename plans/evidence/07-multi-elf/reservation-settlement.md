# Reservation settlement and late-intent fences — 2026-10-13

## Scope

VERIFIED (user direction): continue iteration 7 directly on main without a PR,
overriding the standing branch/worktree/PR workflow. The implementation baseline
is `e64687ee7f7c0fb701fd0383263183985c78bbd1`. No provider calls were made;
tests use synthetic events, Fake and trivial local commands.

REPO-INSPECTION: this extends the
[acquisition foundation](reservation-foundation.md) with explicit reconciliation,
append-only settlement records and late-intent fences. It does not enable
production parallel execution or automatically reconcile on a timer.

## Release policy

| Evidence | Outcome |
| --- | --- |
| No run row, dispatch row, run activity or live Elf | Release unused allowance, preserving the owner and a durable fence |
| Canonical terminal, no live Elf, every recorded group verified absent | Close consumed allowance, retaining terminal/running event references |
| Live Elf or nonterminal run | Keep capacity held |
| Terminal plus live/unknown group, missing/malformed identity, unavailable Elf lookup | Keep capacity; mark reconciliation required |
| Existing ambiguous intent or orphan with activity | Keep capacity; no inferred never-started verdict |
| Existing settlement | Replay the same settlement without probing or writing again |

REPO-INSPECTION: `effect_completed` records successful delivery of an Elf,
not completion of its work. Dispatch failure, ambiguity, cancellation and job
state alone never free a reservation. All four canonical terminal classes
(`completed`, `failed`, `cancelled`, `interrupted`) require ownership evidence.
Projection status alone is insufficient. Deadlines never cancel, release or
replace useful work.

REPO-INSPECTION: the production process probe uses isolated Python
`os.killpg(group, 0)` for at most 64 recorded running identities, with a
2-second/1024-byte helper bound. Only `ESRCH` proves absence; permission errors,
invalid identities, unexpected exits and helper failures remain unknown.
Every group in the bounded history is checked, not just the latest one.
Post-terminal running evidence blocks settlement. The helper owns its own
process-group cleanup; reconciliation does not terminate the target group.
Settlement evidence stores app-domain event references and absence verdicts,
not OS process identifiers or provider transcripts.

REPO-INSPECTION: settlements are inserted once in a separate table, so the
original ownership, policy, admission and uncertainty evidence remain intact.
Outstanding counts exclude settled rows. Settled IDs cannot be held again,
rebound or flagged back into active ownership. A new candidate can acquire the
freed allowance through ordinary validated admission.

## Ordering and fences

REPO-INSPECTION: a reservation must precede its run intent. Acquiring against
an already-existing run is refused. Run-ID lookup enforces the fence even when
the caller omits a reservation extension. `PlanBinding.authorize/2` checks
reservation goal, admitted adapter, active state and settlement before the
existing profile/plan/lineage checks. All `Runs` intent inserts now perform the
authority check and insertion inside one immediate write transaction, including
unplanned requests. `Dispatches` already calls this authority boundary inside
its intent/effect transactions. Orphan settlement uses the same write lock:
either the intent exists and capacity stays reserved, or the settlement wins
and a late insert rolls back without leaving a run or dispatch.

REPO-INSPECTION: reserved runs cannot use the direct adapter resume shortcut;
it returns `reserved_run_requires_coordinator` before adapter invocation.
Coordinator-owned fresh continuation admission remains required. Unreserved
legacy resume behavior is preserved and included in the full gate.

REPO-INSPECTION: explicit reconciliation calls use a supervised local FIFO
writer. It holds no ownership state and performs no retries. SQLite immediate
transactions and uniqueness enforce durable correctness. Calls already inside
a coordinator transaction retain that connection; future coordinators must
continue to serialize their outer transactions. A caller timeout does not
cancel ownership or erase a committed result; stable IDs allow later inspection.
Acquisition's independent-connection checks remain separate from this queue.

## Verification and failures retained

VERIFIED: the first focused command
`mix test test/shoestring/cobbler/reservation_policy_test.exs test/shoestring/cobbler/reservations_test.exs`
exited **2**, **27 tests, 1 failure**, seed **493241**, **7.2 seconds**
(0.4 async, 6.8 sync). The eight-caller orphan settlement race failed with
SQLite lock errors; the other 26 checks passed. A standalone scratch-database
trace reproduced the lock failure: the successful immediate transaction's
`harness_runs` read took 5364.6 ms while competing native `BEGIN IMMEDIATE`
waits timed out. This is the observed contention, not a claim about every
SQLite workload or an intermittent failure hidden by reruns.

REPO-INSPECTION: the supervised reconciliation writer prevents those competing
reconciliation calls from occupying native busy waits together. It does not
retry SQL, change busy timeouts, reduce the eight-caller race or loosen its
assertions. One settlement is written and seven callers replay it. The distinct
intent-versus-release race still runs on separate processes/connections and
permits exactly the two safe outcomes described above.

VERIFIED: after that implementation change and adding runtime checks,
`mix test test/shoestring/cobbler/reservation_policy_test.exs test/shoestring/cobbler/reservations_test.exs test/shoestring/cobbler/reservation_runtime_test.exs`
exited **0**, **29 tests, 0 failures**, seed **361648**, **2.2 seconds**
(0.4 async, 1.7 sync). Scratch databases include all 21 migrations. The tests
are new-capability checks; no regression lock against the baseline commit is
claimed because settlement/reconciliation does not exist there.

VERIFIED: two runtime tests hold a reservation, persist dispatch/run intent,
and launch a supervised Fake Elf owning a real local process group. Natural
completion and explicit cancellation each record canonical terminals, exit the
Elf, and close the reservation through the production OS probe. The cancellation
test first proves a live Elf retains capacity. Tests await terminal and monitor
`DOWN` messages; no sleeps, assertion retries, provider CLIs or network are used.
Separate assertions cover all terminal classes, unknown/failed probes, every
recorded group, history bounds, immutable restart/replay, capacity reuse,
foreign goal/provider refusals, resume refusal, and delayed intent rollback.

VERIFIED: the first full `mix precommit` exited **2**: **4 doctests, 1966 tests,
5 failures, 1 skipped (6 excluded)**, seed **903180**, **179.8 seconds**
(9.4 async, 170.3 sync), wall **183.343 seconds**. JavaScript still ran and
passed **52/52** and **8/8**; that does not make the gate green. All five failures
were `HandoffCrashWindowTest.CrashingRepo.transaction/2` missing from the injected
repository facade, before its intended receiver-insert crash. The facade now
delegates that method to the real repository. Its crash injection and recovery
assertions are unchanged.

VERIFIED: the subsequent focused command adding
`test/shoestring/cobbler/handoff_crash_window_test.exs` to the three reservation
files exited **0**, **42 tests, 0 failures**, seed **345963**, **2.5 seconds**
(0.5 async, 2.0 sync). No test was skipped or retried unchanged to hide a failure.

VERIFIED: the final full `mix precommit` exited **0**: **4 doctests, 1966 tests,
0 failures, 1 skipped (6 excluded)**, seed **831426**, **180.0 seconds**
(9.1 async, 170.8 sync), wall **186.400 seconds**. JavaScript passed **52/52**
and **8/8**, with zero failures or skips. The command ran in the foreground
with stdin closed and a 480-second bound.

## Remaining integration

REPO-INSPECTION: parallel dispatch remains disabled. Next, atomically connect
approved dependency-ready tasks, reservation ownership, leases and dispatch
intent; enforce ownership before external effects while preserving the existing
claim/admission checks. Add CLI inspection/reconciliation commands, independent
sibling bases, overlap decisions, inbox/wakeups and partial-failure recovery.

UNVERIFIED: I did not verify live provider fan-out, cross-provider concurrency,
fairness, distributed coordination or release of every ambiguous launch state.
A terminal with no recorded process identity deliberately retains capacity;
an existing never-started intent needs a separately proven cancellation/fence
path before release. Earlier iteration-6 status/output/budget follow-ups remain.
