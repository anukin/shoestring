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
  backfill), so the UI read the stale row. The trajectory was already
  authoritative and complete; only the read model lagged.

## 2. Fix (VERIFIED, committed here)

`lib/shoestring/elves/elf.ex`:

- `commit_terminal/2` calls `project_after_terminal/1` after
  `append_terminal_event/2` on the `{:terminal, state}` branch only — i.e.
  after this Elf successfully committed terminal events, promptly projecting
  the goal so the durable lease/run rows reflect the canonical terminal
  state with no caller manually projecting.
- `crash_land/0` mirrors it after its terminal append.
- `project_after_terminal/1` (near 1240) reuses the existing `project_own_goal/1`
  (application-repo gate, already rescue/catch-closed) and is itself
  rescue/catch-closed: projector errors are logged observably as
  `elf terminal projection failed` with `run_id`, `dispatch_id` and the
  inspected reason (repo `Logger.warning` convention, as in the lease
  projection and terminal checkpoint paths), then swallowed. A failed
  projection never undoes the committed terminal events, never crashes the
  Elf, and never appends anything — projection advances read-model rows
  only, so no duplicate dispatch or terminal event can result.

Deliberately unchanged (REPO-INSPECTION of the diff):

- Stop / renewal / admission behavior: untouched. The duplicate branches of
  `commit_terminal/2` do not project (they committed nothing; a failed
  projection stays visible in the log rather than being silently healed by
  an observer). Resume, dispatch, wake, and explicit-cancellation paths are
  byte-identical apart from the shared commit call.
- No timers, no interruption, no forced cancellation, no provider calls, no
  new cleanup behavior. The `terminate/2` supervisor-crash marker path is
  out of scope (see §5).

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
the new regression tests). The gate log additionally shows the
failure-observability contract working: scenarios with no projectable run
row log `elf terminal projection failed` and continue green.

## 5. Limits (UNVERIFIED unless noted)

- No live remeasurement: the repair is validated hermetically only. A
  post-fix live pass is **not** claimed; the measured acceptance-8 negative
  result (`live-closeout-post85.md` §9) stands.
- The `terminate/2` supervisor-crash marker (an append that fires while the
  VM is shutting the process down) still does not project; recovery
  (`Shoestring.Elves.reconcile/2`) remains its authority (REPO-INSPECTION).
  No synthetic test pretends to prove an actual supervisor leak: the crash
  twin proves the `crash_land/0` projection, nothing about supervision.
- A projection that fails at the terminal leaves the rows stale until some
  later projector run advances them; the failure is observable in the
  `elf terminal projection failed` warning, not silent.
- Fixture convention: no new fixtures; synthetic ids are generated at
  runtime (`Ecto.UUID.generate/0`), never committed.
