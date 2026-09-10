# Lease Re-Loop: Re-Renewal, Decline→Suspend+Sleep, Stop-Flag Hygiene

Round-2 finding 4 follow-up (work package C). All factual claims are labeled
per the evidence conventions (`VERIFIED` = proven by committed code or exact
command output in this run; `REPO-INSPECTION` = direct file inspection;
`UNVERIFIED` = not verified here).

## 1. Problem (VERIFIED)

In `lib/shoestring/elves/elf.ex` the renewal loop was single-shot:
`renew_path` short-circuited on `lease_settled?` (latched after the first
renewal), so a second exhaustion never re-evaluated; decline wrote a
checkpoint but never suspended the run or scheduled sleep; `stop_path` set
`lease_stop_requested?` even when `LeaseBoundary.enforce/3` answered
`within_lease` (no session stop actually requested), and `renew_path` then
depended on that conflated flag.

## 2. What changed (REPO-INSPECTION)

Only `lib/shoestring/elves/elf.ex` (renew/stop/decline regions + no new
struct fields), `lib/shoestring/cobbler/lease_bounds.ex` (`epoch` support),
and tests. `Wakeups` is call-only (`schedule/2` from the decline path —
read the schedule API first, no restructure); `LeaseWatcher`,
`LeaseBoundary`, `RunStateMachine`, `Leases`, `LeaseRenewal`, the terminal
region, and every other file are untouched (`git diff --stat` shows only
the two lib files plus tests).

| Area | Change |
| --- | --- |
| P1 re-arm | `run_renewal` on `:renewed` calls `rearm_epoch/1`: `LeaseBounds.new_epoch/1` resets spend + due latch (same budgets/deadline, `seen` kept so nothing double-spends) and both latches clear, so a later due/deadline re-fires the full sequence with a fresh snapshot + re-evaluation each time |
| P2 decline | `decline_lease/2` (shared by boundary-expired and quota-expired): existing checkpoint writer → `run.pausing`/`run.suspended` via the existing `append_run_event` helper → `Wakeups.schedule` sleep wake (`wake_at = now + admission delayed-recheck default`, synthetic command id `"elf-lease-decline:<dispatch_id>"`, idempotent by wakeup key) → settle |
| P3 hygiene | `stop_path` sets the flag only on actual `:stop_requested`; `renew_path` is re-gated to boundary + (due or deadline-passed) + (stop requested OR deadline does not require one) via `stop_satisfied?/1` |
| Epoch support | `LeaseBounds.new_epoch/1` (minimal: `epoch` counter, counters + due/quota latches reset, budgets/identity/`seen`/command correlation kept) |

## 3. Pinned decisions P1–P4 — conformance and deviations

- **P1** (`VERIFIED` in code + tests): multi-renewal re-arms as specified.
  One load-bearing subtlety found during implementation: lease trajectory
  keys are per-grant (`lease-renewed:<grant>`), and `Trajectory.append` is
  idempotent on the key, so the second `:renewed` outcome replays rather
  than appending a second `lease.renewed` event. "Two renewed outcomes"
  is therefore proven by two probe calls plus the grant ending chained to
  the second epoch's snapshot — not by two events (asserted exactly so in
  the multi-renewal test). Deadlines still bound total renewals: the epoch
  keeps the grant's deadline, and a past deadline keeps declining.
- **P2** (`VERIFIED` in code + tests, with a load-bearing limitation, see
  §5): decline checkpoints, suspends, schedules the sleep wake, and
  settles, all idempotent per dispatch (checkpoint id, run-event keys,
  wakeup key all stable). No timers; the Oban job is durable delivery.
- **P3** (`VERIFIED` in code + tests): flag set only on `:stop_requested`;
  budget-due renews at the boundary with no session stop; the deadline
  path still stops the session first. I2-era gating tests: no existing
  test asserted the old gating internally, so none needed gating updates;
  the one I2 line that changed is the projection assert below (§5).
- **P4** (`VERIFIED`): no new trajectory event types (`run.pausing`,
  `run.suspended`, `lease.*`, `checkpoint.created` all pre-date this
  slice); stop-only `LeaseWatcher`/`LeaseBoundary` untouched; quota *fast
  path gating* unchanged (immediate, no stop/boundary wait).
- **Twin check** (`REPO-INSPECTION`): quota-renewed still settles without
  starting a new epoch (unlike boundary-renewed). Deliberate: the quota
  path is zero-spend, so the live counters still describe the grant's
  remaining allowance and must not be forgiven by an epoch reset. Noted
  inline at the quota branch.

## 4. Tests (VERIFIED)

Hermetic: `Fake` scripted streams (+ a delegating scripted-probe adapter
in `test/support/scripted_probe_fake.ex`), `FixedClock`, synthetic UUIDs —
no provider CLI, no network. (`ManualClock` is process-dictionary local,
so the cross-process Elf ingest path uses `FixedClock` per the I2
precedent — explicit deviation from the brief's clock mention.)

New `test/shoestring/elves/elf_lease_reloop_test.exs` (5 tests) plus one
`LeaseBounds.new_epoch/1` unit test:

| Test | On branch | On base `4d2df5a` |
| --- | --- | --- |
| second exhaustion re-renews (2 probes, admitted == S2) | pass | **fails** (`calls == 1`, admitted == S1) — lock |
| decline suspends + sleep wake (suspended, wakeup row) | pass | **fails** (0 `run.suspended`, no row) — lock |
| quota decline twin (suspended, wakeup row) | pass | **fails** (0 `run.suspended`, no row) — lock |
| budget-due, no session stop: trajectory half (renewed, zero stop calls) | pass | passes — documentation |
| budget-due, no session stop: flag hygiene half (`lease_stop_requested? == false` via `:sys.get_state`) | pass | **fails** (flag `true`) — lock |
| deadline path requests session stop (call observed, renewed) | pass | passes — documentation |
| `new_epoch` unit (reset, seen kept, due re-fires) | pass | errors (`UndefinedFunctionError`) — documentation |

Fail-on-base was verified by stashing `lib/` over the committed base and
running the files: 5 behavioural failures with the values above, all for
the stated reasons; the documentation rows pass on both (labeled as such
in the test moduledoc). The base run also confirmed the pre-existing
deadline test needs no gating update (nil session → virtual flag, both
versions).

Intentionally updated (1 line): `elf_lease_loop_test.exs` "refused
renewal" now asserts the documented projection halt (§5) instead of
`{:ok, _}`, keeping its lease-status assert. Nothing else in the
elf/lease suites changed.

Existing suites stay green: `elf_test` + `elf_lease_loop_test` +
`elf_terminal_checkpoint_test` + `lease_bounds_test` +
`lease_renewal_boundary_test` + `lease_boundary_test` + `lease_grant_test`
+ `elf_lease_reloop_test` = 78 tests, 0 failures (VERIFIED).

Full gate (VERIFIED): `mix precommit` → exit 0: 1160 tests, 0 failures,
1 skipped (6 excluded) plus the hermetic JS probe matrix: 52 pass, 0 fail.
(Two compile warnings appear in other slices' test files —
`wakeup_continuation_test.exs:26` unused `Oban.Job` alias and
`wake_reobserve_test.exs:89` unused `dispatch_jobs_before` — left alone as
out of scope; the gate stays green.)

## 5. Known load-bearing limitation: harness projection halts at the post-suspend terminal (VERIFIED)

Appending `run.pausing`/`run.suspended` at decline is projection-safe, but
the Elf still reports its in-flight verdict afterwards, and
`suspended → complete` / `suspended → fail` are not legal
`RunStateMachine` edges (read-only here): `Projector.project/2` applies
everything up to the terminal (lease `checkpoint_required`, run
`suspended` — exactly what the wakeup resume path requires) and then
returns `{:error, {:invalid_transition, ...}}`, leaving the goal position
failed. The trajectory keeps the terminal as durable evidence, and all
event-based readers (Elf convergence, `terminal_event` queries, notify)
are unaffected — but a future `Projector.project` for the goal (notably
inside `Wakeups.perform_wakeup`) fails until the owning track decides the
terminal-after-suspend story (e.g. projector tolerance vs. a dedicated
terminal mapping — explicitly out of scope: machine, `Leases`, and the
terminal region are other tracks' files). Fixing it unilaterally here
would break the wakeup resume contract (`resume_run` requires
`suspended`), so it is reported, not improvised.

## 6. State machine in words (re-arm + gating)

Per ingested normalized event: advance bounds → quota fast path (unchanged
gating) → mark due at boundary/deadline → ensure stop (flag only on real
`:stop_requested`; virtual with no session) → at item.completed, renew iff
due/deadline AND (stop requested OR deadline live). `:renewed` re-arms a
new spend epoch and clears both latches (repeat indefinitely; deadline
bounds the total). `:expired` declines (checkpoint → suspend → sleep wake →
settle). Lease-terminal-elsewhere with exhaustion checkpoints and settles
without suspending (unchanged); without exhaustion it just settles
(unchanged).

No live provider runs were made; no run budget was authorized. Fixtures
use format-valid synthetic identifiers only; no credentials, tokens,
paths, or machine identifiers are committed.
