# I2 — Elf-Loop Lease Accounting: Bounds, Renewal, Reactive Checkpoint

Milestone 05, work package C loop-closure slice I2. All factual claims below
are labeled per the evidence conventions (`VERIFIED` = proven by committed
code or exact command output in this run; `REPO-INSPECTION` = direct file
inspection; `UNVERIFIED` = not verified here).

## Problem (VERIFIED)

On the base commit, `Shoestring.Cobbler.LeaseBounds.advance/2` and
`drain/3` have zero lib callers: granted response/tool budgets and the
checkpoint cadence are unenforced in the Elf ingest loop (`after_ingest`
counts adapter events and progress only), and the `LeaseRenewal` helpers
have no execution-loop consumer.

## What changed (VERIFIED)

Only `lib/shoestring/elves/elf.ex` (ingest-hook region, struct fields for
lease context, and new private `lease_*` helpers) plus the new hermetic
test file `test/shoestring/elves/elf_lease_loop_test.exs`.

### Hook inventory — where the loop reads and writes what

| Hook | Reads | Writes |
| --- | --- | --- |
| `after_ingest/3` (one added line) | — | calls `lease_account/2` with the just-persisted normalized event |
| `ensure_lease_bounds/1` | `harness_execution_leases` by `run_id` (indexed `[:run_id, :deadline]`); durable `harness.event_recorded` payloads for spend rebuild | in-memory `lease_bounds`, `lease_grant_id`, `lease_deadline` |
| `LeaseBounds.advance/2` per event | live `HarnessEvent` only (never raw OS output) | in-memory bound counters |
| `due_path/2` | `:renewal_due` effect, inline deadline check | `lease.renewal_due` via `Leases.transition/4` (idempotent on the `lease-renewal-due:<grant>` key) |
| `stop_path/1` | live session lookup; bound `due` level; deadline | exactly one safe-stop: `LeaseBoundary.enforce/3` when a Codex session exists, otherwise a virtual in-memory flag (Fake has no session) |
| `renew_path/2`, `run_renewal/1` | counter delta (boundary), stop flag | `LeaseRenewal.maybe_renew/3` → `lease.renewed` (fresh snapshot chained) or `lease.expired` → `lease.checkpoint_required` |
| `quota_path/1` | `:quota_refused` effect | `LeaseRenewal.handle_quota_refusal/3` (immediate; provider already halted) |
| `write_reactive_checkpoint/2` | live counters (evidence text) | `checkpoint.created` via `CheckpointFallback` + `Checkpoints.record/3` (T3 writer used as-is) |
| `probe_capacity/1` | `adapter.probe/1` (Fake scenario capacity in tests) | nothing (snapshot struct feeds re-evaluation) |

Untouched by design: `commit_terminal/2`, `append_terminal_event/2`,
`stop_with_terminal/2` (I3 owns the terminal-commit region),
`LeaseWatcher`, `LeaseBoundary`, session semantics (stop-only invariant
stands), and every other file (read-only elsewhere).

## Pinned decisions P1–P5 (VERIFIED in code)

- **P1** — Accounting is called from the Elf normalized-event ingest path
  (`after_ingest` region), keyed by the run's lease loaded by `run_id`.
  No lease, or any unknown lease state, means no accounting; the whole path
  is exception-guarded and never crashes a leased-out run.
- **P2** — Counting follows the T2 rule already in `LeaseBounds` (message
  completions, never delta frames). The item.completed boundary is
  *derived* from the live counters (this event incremented responses or
  tools), never redefined.
- **P3** — On renewal-due or deadline: durable `lease.renewal_due` is
  marked, safe stop is ensured via the existing `LeaseBoundary` (never
  restopped — guarded by `lease_stop_requested?`), and at the
  item.completed boundary the T2 renewal sequence runs with a fresh
  snapshot (`stop: :already_requested`, `boundary: :item_completed`).
- **P4** — In-flight exhaustion (responses/tools at budget) enters the
  reactive checkpoint path: checkpoint contents via the T3 writer, stop at
  the safe boundary. The item that just completed is durable before the
  checkpoint append, and ingestion is never interrupted mid-item (no
  process-group, cancel, or terminal effects added).
- **P5** — No new trajectory event types (only `lease.*`,
  `checkpoint.created`, `run.*`); no timer processes (deadline evaluated
  inline on ingest with the Elf clock); counters derived from the live
  normalized buffer only (plus a durable rebuild on first load so a lease
  granted mid-stream still counts exactly, idempotent on
  `source_event_id`).

### Deviation from P3 (stated explicitly)

P3 says "ensure safe-stop requested via the existing `LeaseBoundary`".
When a live Codex session exists, `LeaseBoundary.enforce/3` is invoked.
Hermetic Fake runs have no session process, so the stop is recorded
virtually (the in-memory flag the renewal sequence requires) while
ingestion still runs every item to its own completion. No new effect is
added to `LeaseWatcher`/`LeaseBoundary`. (REPO-INSPECTION: `Fake` exposes
no session; `Elves.request_stop/2` likewise reports `:session_not_found`
for session-less runs.)

## Tests (VERIFIED)

`test/shoestring/elves/elf_lease_loop_test.exs` — 9 hermetic tests (Fake
scripted streams + FixedClock; no provider CLI, no network):

| Test | Result on branch | Result on base `85437ed` |
| --- | --- | --- |
| response spend exact, due one reserve early, renews | pass | **fails** (0 `lease.renewal_due`) — lock |
| tool + command-END spend once; START never spends | pass | **fails** — lock |
| delta frames never spend | pass | **fails** — lock |
| deadline marks due then renews on fresh snapshot | pass | **fails** — lock |
| refused renewal expires → checkpoints at boundary, items uninterrupted | pass | **fails** — lock |
| in-flight exhaustion checkpoints; turn still completes | pass | **fails** — lock |
| quota fast path expires immediately + checkpoints | pass | **fails** — lock |
| no-lease runs unaffected | pass | passes — documentation |
| lifecycle noise under lease spends nothing | pass | passes — documentation |

Fail-on-base was verified by checking out the base `elf.ex` over the
committed branch and running the file: 7 behavioural failures (all
`left: 0` on lease/checkpoint counts), 2 passes, matching the table.
Existing suites stay green: `elf_test` + `lease_bounds_test` +
`lease_renewal_boundary_test` + `lease_boundary_test` = 50 tests,
0 failures (VERIFIED).
Full gate (VERIFIED): `mix precommit` → 1068 tests, 0 failures, 1 skipped
(6 excluded) plus the hermetic JS probe matrix: 52 pass, 0 fail.

## Limitations (UNVERIFIED beyond the suite)

- One renewal/checkpoint per Elf run (`lease_settled?` latches); a second
  exhaustion after a successful renewal is counted but not re-renewed.
- A quota error consumed before the lease row exists misses the fast path
  (spend rebuild covers counts, not the effect); the grant is expected to
  precede the stream in production ordering.
- Post-crash `Elf` processes rebuild spend from durable events but do not
  restore the stop/settled flags; a crash between due-marking and renewal
  re-marks (idempotent) and retries at the next boundary.
