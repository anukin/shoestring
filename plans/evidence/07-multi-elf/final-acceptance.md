# Iteration 7 final acceptance packet

**Decision status:** awaiting human acceptance.
**Prepared:** 2026-10-14.

This packet is an assistant assessment, not a human review or an independent
model judgment. No provider call was made for iteration 7. The user's
direct-main/no-PR authorization applied throughout. The user said "start with
the pre-fan-out fixes … continue with the work till iter 7 is finished"; this
packet does not treat that as acceptance of the iteration.

## Packages

| Package | Evidence |
| --- | --- |
| B reservations | [foundation](reservation-foundation.md), [settlement](reservation-settlement.md), [continuations](reservation-continuations.md), [CLI recovery](reservation-cli-recovery.md) |
| A dispatch coordinator | [atomic dispatch](atomic-plan-dispatch.md), [reservation-owned dispatch](reservation-dispatch-ownership.md), [internal coordinator](internal-fanout-coordinator.md), [production activation](production-activation.md) |
| C worktrees | [sibling workspaces](sibling-workspaces.md) |
| D independence/overlap | [scope policy](scope-policy.md), [final scope](final-scope-acceptance.md), [scope resolution](scope-resolution.md) |
| E inbox/wakeups | [child inbox](child-inbox-wakeups.md) |
| F partial failure | [recovery and cancellation](partial-failure-recovery.md) |
| Pre-fan-out prerequisites | [goal rows, verification budget, Claude output](pre-fanout-prerequisites.md) |

## Acceptance gate

| Condition | Evidence |
| --- | --- |
| Concurrency never exceeds configured limits | `reservations_test.exs` "eight concurrent independent connections cannot double-claim three shared units"; the provider-cap eval; the fairness simulation's zero violations and zero false parallel admissions |
| Reservations are durable, explainable and released on every terminal path | settlement/recovery evidence; live child and goal cancellation; restart recovery then explicit cancellation; simulation `leaked_owners: []` |
| Restart never duplicates an admitted child | `plan_fanout_integration_test.exs` intent restart; `plan_fanout_eval_test.exs` restart while two children run (groups survive and are not re-spawned or re-admitted) |
| Sibling branches/events/artifacts are isolated and survive partial failure | private stores per attempt; eval "one passing and one crashing sibling"; demo steps 2–5 |
| Conflict/uncertainty policy prevents unsafe automatic integration | declared/actual scope policy; final-scope blockers; explicit human resolution; no merge, with human-recorded integration required; demo step 7 |
| Planner output cannot allocate slots or capacity | REPO-INSPECTION: reservations accept only trusted policy plus canonical admission; fan-out is chosen only by configuration and deterministic driver rules |
| CLI exposes slots, reservations, children, blockers and provider evidence | `mix shoestring.reservations`; execution `status` (children, `stop_class`, `scope_blockers`, `child_inbox`, `cancellations`, `integration`, budget); the UI scope is unchanged |

## Required evaluations

| Eval | Result and location |
| --- | --- |
| Independent fan-out | VERIFIED: two concurrent live Fake children in separate private stores (`plan_fanout_integration_test.exs`, demo step 2) |
| Provider cap | VERIFIED: three ready tasks, provider limit one, exactly one reservation (`plan_fanout_eval_test.exs`) |
| Shared headroom | VERIFIED: concurrent connections cannot double-claim shared units (`reservations_test.exs`) |
| Restart after intent | VERIFIED: one reconciled dispatch, no duplicate admission (`plan_fanout_integration_test.exs`) |
| Restart while running | VERIFIED: two live children survive restart, are recovered once and later stopped explicitly (`plan_fanout_eval_test.exs`) |
| Sibling failure | VERIFIED: passing evidence and both branches retained across restart (`plan_fanout_eval_test.exs`) |
| Overlap known | VERIFIED: overlapping declared scopes refuse fan-out and run sequentially (`plan_fanout_driver_test.exs`, demo step 7) |
| Overlap discovered | VERIFIED: unexpected actual overlap blocks visibly, with gates retained (`plan_final_scope_test.exs`) |
| Quota sleep | VERIFIED: a quota-stopped child sleeps while a sibling is replaced and accepted (`plan_fanout_integration_test.exs`) |
| Cancel one | VERIFIED: a live child's process group stops; the sibling runs on and is accepted (`plan_fanout_integration_test.exs`) |
| Cancel goal | VERIFIED: every live child stopped within the bounded grace; further work fenced (`plan_fanout_eval_test.exs`) |

## Economic and fairness simulation

VERIFIED: [simulation.json](fairness/simulation.json) was written by `mix test
test/shoestring/cobbler/plan_fanout_fairness_test.exs` (seed 210003, 37.3 s).
It is a deterministic run over the real reservation and coordinator boundary,
with Fake admission and no live Elf. Setup: four goals of three independent
tasks, split across two account buckets. The policy allows global 3,
provider-account 2 and goal 2. One bucket's admission window is closed in
rounds 1–2. Scripted outcomes: one crash then replacement, one quota stop, and
one unstarted cancellation; every other task completes. Queue policy version 1
is a rotating round-robin over goals in declared task order; provider-blocked
tasks are skipped.

| Metric | Result |
| --- | --- |
| Max simultaneous (global / per goal / per bucket) | 3 / 2 / 2: equal to the limits, never above |
| False parallel admissions | 0 |
| Reservation leaks after every failure state | 0 |
| Ready-goal waits behind unrelated blocked work | 0 rounds (8 rounds waited only on configured limits) |
| Successful tasks preserved per partial failure | 10 of 12 accepted, 0 regressions; the quota-stopped and cancelled tasks stay unresolved |
| Observed capacity delta per verified child | Not available: Fake fixtures report no provider consumption |

## Demo

VERIFIED: [transcript.json](demo/transcript.json) was written by the isolated-node
demo (`plan_fanout_demo_test.exs`, seed 410321) through the production driver
with live supervised Fake Elves:

1. fan out north/south into separate stores;
2. south crashes while north is accepted;
3. restart reconstructs that state with no outstanding owners;
4. south is replaced as attempt 2 while join stays locked;
5. join unlocks only after both acceptances, the execution completes and the
   goal row becomes `completed`;
6. an overlapping-scope fixture refuses fan-out and runs sequentially.

The Fake children change no files, so integration is trivial here. Committed
siblings instead require recorded human integration
(`plan_fanout_driver_test.exs`).

## Verification

VERIFIED: the final `mix precommit` exited 0: **4 doctests, 2161 tests,
0 failures, 1 skipped, 6 excluded**, seed 805622, 430.3 s (9.6 s async, 420.7 s
sync). JavaScript passed **52/52** and **8/8**. It includes the isolated-node
lifecycle (6 scenarios), eval (3) and demo (1) wrappers, the fairness
simulation and every package's regression file. The isolated-node eval suite
passed 3 of 3 consecutive runs, and no `sleep` test processes remained
afterwards.

## Retained limits

- UNVERIFIED: no live Codex/Claude fan-out, provider concurrency, account
  discovery or real capacity delta. Reservation units are conservative
  configured allowances, not forecasts.
- Production fan-out ships default-off. Enabling it is an operator
  configuration decision.
- Automatic merging remains out of scope. Committed siblings need a human merge
  plus `integrate`, after which dependents run sequentially even when several
  are independent.
- Coordinator progress relies on the existing 5 s worker snooze. After an
  operator acts on a blocked execution, `continue` re-queues it.
- Scope evidence is file-level and does not prove semantic independence.
- Large-history throughput, populated on-disk upgrades and live
  provider-session continuation of fan-out children were not verified.
- A goal cancellation leaves the generic goal row `active`.

## Requested decision

Whether this evidence, with the limits above, satisfies iteration 7 and
unlocks iteration 8 (verification and cross-review).
