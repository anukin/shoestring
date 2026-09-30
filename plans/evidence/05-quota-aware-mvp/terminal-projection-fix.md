# Terminal-projection closeout: final projection after committed terminals

Branch `polly/iter5-terminal-projection-closeout`, base `70af28e`. Claim
labels follow `README.md` in this directory (`VERIFIED` = committed artifact
or command output from this run; otherwise `REPO-INSPECTION` or
`UNVERIFIED`).

## 1. Defect (VERIFIED live record + REPO-INSPECTION)

The standalone `lease_stop` run (`live-closeout-post85.md` §14) ended the
canonical trajectory at `lease.expired` → `lease.checkpoint_required` →
`checkpoint.created` → `run.completed` (seqs 740–743), but the stored
`harness_execution_leases` row still read `renewal_due` and the run row still
read `running`. L8 stays **FAIL as registered**; nothing below relabels it.

Mechanism (REPO-INSPECTION of `70af28e`):

- `LeaseRenewal.persist_and_settle/5` (`lib/shoestring/cobbler/lease_renewal.ex`,
  near 247) projects once, after the renewal snapshot, then appends the
  `admission.decided` and the `lease.expired` / `lease.checkpoint_required`
  markers without projecting again.
- `Elf.commit_terminal/2` (`lib/shoestring/elves/elf.ex`, near 2370)
  appended the terminal checkpoint + terminal with no projection after them.
- `Elf.crash_land/0` (near 615) likewise appended checkpoint + terminal with
  no projection.
- No other consumer projects the goal after the terminal (REPO-INSPECTION:
  the only in-Elf projection call was the once-per-Elf `load_lease/1`
  backfill), so the UI read the stale row. The three non-commit terminal
  writers (§5) likewise append without projecting. The trajectory was already
  authoritative and complete; only the read model lagged.

## 2. Fix (VERIFIED, committed here)

`lib/shoestring/elves/elf.ex`:

- `commit_terminal/2` calls `project_after_terminal/1` after
  `append_terminal_event/2` on the `{:terminal, state}` branch only — i.e.
  after the terminal append *attempt* (`_ = append_terminal_event(...)`,
  `elf.ex:2385`; the result is discarded, so the projection also runs when
  the append itself returned an error), promptly projecting the goal so the
  durable lease/run rows reflect the canonical terminal state with no caller
  manually projecting.
- `crash_land/0` mirrors it after its terminal append attempt (same
  `_ =`-discarded shape, `elf.ex:619-628`).
- `project_after_terminal/1` (near 1240) reuses the existing `project_own_goal/1`
  (application-repo gate, already rescue/catch-closed) and is itself
  rescue/catch-closed: projector errors are passed to `Logger.warning` as
  `elf terminal projection failed` with `run_id`, `dispatch_id` and the
  inspected reason (repo convention), then swallowed. Accuracy notes
  (REPO-INSPECTION, not log-observed): the default formatter
  (`config/config.exs:67-69`) prints only `request_id` metadata, so the
  run/dispatch/reason fields do not appear in printed log lines unless a
  collector captures metadata; and a projector *raise* logs twice — first
  `elf lease projection failed` from `project_own_goal/1`, then
  `elf terminal projection failed` with reason `:projection_raised`. That no
  error path undoes terminal events, crashes the Elf, or appends anything is
  REPO-INSPECTION of the rescue/catch-closed structure — no test exercises
  those paths, so it is not VERIFIED: projection advances read-model rows
  only, so no duplicate dispatch or terminal event can result.

Deliberately unchanged (REPO-INSPECTION of the diff):

- Stop / renewal / admission behavior: untouched. The duplicate branches of
  `commit_terminal/2` (`elf.ex:2374-2380`) return before projecting (they
  committed nothing). Follow-up, recorded not fixed: if the Elf process dies
  between the terminal append and the final projection, the rows stay stale
  with no automatic catch-up from this change. Resume, dispatch, wake, and
  explicit-cancellation paths are byte-identical apart from the shared commit
  call.
- No timers, no interruption, no forced cancellation, no provider calls, no
  new cleanup behavior.

## 3. Regression (VERIFIED hermetic)

`test/shoestring/elves/elf_terminal_projection_test.exs` (3 tests, FixedClock
+ Fake + trivial local commands; no provider CLI, no network). No test in
this file calls `Projector.project/2` after the terminal — that absence is
the assertion: the Elf must have projected already (the `{:elf_terminal,
...}` notify, and the crash-twin's `DOWN`, both follow the final
projection).

- Completed outcome with refused lease (the live L8 shape: grant →
  `renewal_due` → mid-flow projection → refusal on the completed outcome →
  expiry markers → terminal checkpoint → `run.completed`): without any
  post-terminal test projection the lease row reads `checkpoint_required`
  (no live status), the run row reads `completed`, the canonical counts hold
  (`renewal_due` 1, `renewed` 0, `expired` 1, `checkpoint_required` 1, one
  renewal decision, one terminal checkpoint, zero reactive checkpoints,
  exactly one terminal, 4 `harness.event_recorded`), the checkpoint precedes
  the completion, and there is no suspension, wake, or redispatch (1 run, 1
  dispatch row, 1 `run.starting`, 1 terminal).
- Interrupted-decline twin: same, through suspend + sleep wake to
  `run.interrupted` (lease `checkpoint_required`, run `interrupted`,
  `pausing`/`suspended` 1 each, wake `scheduled`, reactive + terminal
  checkpoints 1 each, projector caught up).
- Launch-crash twin (`crash_land/0` via a raising adapter): durable
  `run.failed` / `elf_launch_crashed` with its checkpoint before it, the run
  row `failed`, the projector caught up.

Base-failure ledger (VERIFIED against base `70af28e`, `mix test
test/shoestring/elves/elf_terminal_projection_test.exs --seed 0` with the
`elf.ex` fix stashed, test file present): **3 tests, 3 failures**, each for
the stale-row reason —

- completed twin: `lease.status == "checkpoint_required"` fails with left
  `"renewal_due"`;
- interrupted twin: same `"renewal_due"` left value;
- crash twin: `RunRecord.status == "failed"` fails with left `"requested"`.

Canonical event-count assertions pass on base; the rows and the projector
position lag. These are regression locks, not documentation.

## 4. Proof runs (VERIFIED)

Focused suites, each `mix test ... --seed 0`, all hermetic:

- New file + lease loop + reloop:
  `test/shoestring/elves/elf_terminal_projection_test.exs`,
  `test/shoestring/elves/elf_lease_loop_test.exs`,
  `test/shoestring/elves/elf_lease_reloop_test.exs` → **34 tests, 0 failures**.
- Terminal / cancel / decline twins:
  `elf_terminal_checkpoint_test.exs`, `terminal_checkpoint_test.exs`,
  `request_stop_test.exs`, `interruption_test.exs`,
  `elf_checkpoint_resume_test.exs`,
  `elf_claude_decline_quiescence_test.exs`,
  `test/shoestring/cobbler/observatory_snapshot_twins_test.exs` →
  **54 tests, 0 failures**.
- Explicit cancellation is preserved by the unchanged existing paths
  (`request_stop_test.exs`, `interruption_test.exs` green above); the cancel
  path commits through the same `commit_terminal/2` and now projects too.

Full gate: `mix precommit` → **4 doctests, 1509 tests, 0 failures, 1 skipped,
6 excluded; Node 52/52; UI 7/7** (baseline at `70af28e`: 4 doctests, 1506
tests, 0 failures, 1 skipped, 6 excluded; Node 52/52; UI 7/7 — the +3 are
the new regression tests).

Gate history on this tree (VERIFIED from the saved outputs, same tree modulo
prose): three full `mix precommit` runs — ExUnit seeds 839803, 796367,
31501. Seeds 796367 and 31501: green as quoted above. Seed 839803: **4
doctests, 1509 tests, 1 failure, 1 skipped (6 excluded); Node 52/52; UI
7/7**. The single failure was `CodexAppServerContractTest` "normalized
start, stream, completion, failure, and cancellation"
(`test/shoestring/harness/codex_app_server_contract_test.exs:13`):
`GenServer.call(pid, {:cancel, %{}}, 15000)` exited `no process` — the
cancel raced a dead session process. That suite drives the adapter/session
directly with no Elf, Repo, or Harness.Projector in the path, so no direct
causal path from this diff was found; an indirect load-timing contribution
is unestablished, not ruled out. The file passes in isolation (7 tests, 0
failures, `--seed 0`). Reported as intermittent, 1 of 3 full-gate runs, not
re-run until green.

The gate log also shows `elf terminal projection failed` warnings in
scenarios with no projectable run row (e.g. `run_not_found` vehicles).
Those application-repo-gate skips are expected-skip noise, not proof of the
failure-observability contract (REPO-INSPECTION: they exercise the skip
branch, never a genuine projection failure).

## 5. Limits (UNVERIFIED unless noted)

- No live remeasurement: the repair is validated hermetically only. A
  post-fix live pass is **not** claimed; the measured acceptance-8 negative
  result (`live-closeout-post85.md` §9) stands.
- Three other terminal writers still do not project, and recovery never
  projects (REPO-INSPECTION): (1) `Elf.terminate/2`'s `supervisor_crash()`
  marker (`elf.ex:305-320`) — the Elf never traps exits
  (`Process.flag(:trap_exit, ...)` appears only in `dispatch_effect.ex`, a
  different process), so this fires on ordinary callback crashes after
  launch, not on supervisor shutdown; (2) `cancel_without_elf/3` →
  `append_cancelled/2` (`elves.ex:693-783`: `run.cancelling` plus
  `run.cancelled` with no Elf running); (3) `append_reconciled_terminal/3`
  (`elves.ex:916-930`) on every `reconcile/2` orphan path
  (`reconcile_exited/2`, `reconcile_never_spawned/2`). `reconcile/2` itself
  (`elves.ex:295-310`) calls no projector. Any of these can leave lease/run
  rows stale; no healing consumer is implied. The fix covers
  `commit_terminal/2` and `crash_land/0` only. No synthetic test pretends to
  prove an actual supervisor leak: the crash twin proves the `crash_land/0`
  projection, nothing about supervision.
- A failed terminal projection does not imply later healing
  (REPO-INSPECTION): a transaction that rolls back without persisting
  `fail/4` leaves the projector position unchanged, so a later `project/2`
  may catch up — but once `Projector.fail/4` persists (`projector.ex:549-560`,
  `status: "failed"`), every later `project/2` returns the stored failure
  (`projector.ex:111`) until an explicit `rebuild/2` (`projector.ex:42-47`).
  There is no automatic recovery guarantee.
- The `{:duplicate, state}` branches (in-memory terminal already set, or a
  terminal already recorded durably) return before projecting, as do
  redeliveries converging on them — and a crash of the Elf process between
  the terminal append and the final projection leaves the rows stale.
  Recorded as a follow-up, not fixed here.
- Each terminal now costs one extra per-goal projection transaction; under
  SQLite contention that projection can itself hit busy/locked errors (the
  pre-existing projector-busy caveat stands), in which case the rows stay
  stale per the paragraphs above.
- The crash twin attaches its `Process.monitor/1` after an async start and
  a Repo read (`elf_terminal_projection_test.exs:263-270`); if the Elf has
  already exited, the monitor fires `:noproc` instead of `:normal` and the
  test would fail. Unverified race risk, recorded without changing the test.
- Fixture convention: no new fixtures; synthetic ids are generated at
  runtime (`Ecto.UUID.generate/0`), never committed.
