# Milestone 05: Deterministic Checkpoint + Sleep/Reset/Recovery (Work Package D+E, T3)

- **Status**: Work package D+E (Milestone 05, stacked on `d3ca088`: T1 goal
  lifecycle + T2 lease wiring + T5 UI merged).
- **Scope**: No-model checkpoint template (pure), durable checkpoint writer,
  `cobbler_wakeups` intents with an Oban `wakeup` queue, wake-to-reobserve
  orchestration, startup reconcile wiring, the sleeping-state lifecycle gap
  (P5), and manual operator recheck (P6). Projection/resume/handoff
  services belong to the parallel track and are untouched.
- **Evidence Labels**: `VERIFIED` (hermetic ExUnit runs in this worktree),
  `REPO-INSPECTION` (committed code), `UNVERIFIED` (explicitly marked).

---

## 1. Executive Summary

1. **CheckpointFallback** (`VERIFIED`): `Shoestring.Harness.CheckpointFallback`
   (pure) builds a `Checkpoint` from durable-state inputs only, with
   truncation budgets that hard-fail on overflow (never silent truncation)
   and forced provenance
   `"shoestring:synthesized_without_model" => "checkpoint-fallback-v1"`.
   Zero adapter calls by construction (asserted via `RequestLog` equality).
2. **Checkpoints writer** (`VERIFIED`): `Shoestring.Harness.Checkpoints`
   mirrors the `Commands`/`Dispatches` idempotency contract — run-ownership
   check, `Checkpoint.new/1`, artifact pre-check mirroring the projector,
   `EventPayload.checkpoint/1` (no second mapping), `Trajectory.append/3`
   with key `"checkpoint-created:<id>"`, replay returns the recorded
   checkpoint with `outcome: :replayed` and no new events. No projector
   change (`REPO-INSPECTION`: `harness/projector.ex` untouched).
3. **Wake intents** (`VERIFIED`): `cobbler_wakeups` (new table, P1) plus
   `Shoestring.Cobbler.Wakeups` (`schedule/2`, `reconcile/1`,
   `request_recheck/2`, `perform_wakeup/2`, `cancel_pending/2`,
   `lifecycle_state/2`) and `Shoestring.Cobbler.WakeupWorker` on the new
   `wakeup` queue (`dispatch: 5` kept). Idempotency keys derive from durable
   identity only (P2); Oban uniqueness is `period: :infinity` on the key.
4. **Wake-to-reobserve** (`VERIFIED`): fixed §P4 order — fresh snapshot
   (persisted `capacity.snapshot_observed`, probe failure leaves the intent
   due) → `AdmissionEvaluation.evaluate/5` with explicit `now` + claim
   occupancy → admit (renew + resume, dispatch stays gated), defer_until
   (expire + checkpoint + resleep with a new `wake_at`, run stays
   suspended), require_confirmation (stay asleep, operator surface),
   reject (handing_off + cancel intents). The row is marked `woken` only
   after branch writes commit; re-performing a `woken` row is a no-op.
5. **Startup reconcile** (`VERIFIED`): `Shoestring.Cobbler.WakeupReconciler`
   runs one `Wakeups.reconcile/1` pass at boot (E4: supervision placement
   only, no new wake semantics, disabled in test like the dispatch
   reconciler).
6. **Sleeping-state gap** (`VERIFIED`, true locks): the three missing
   `GoalLifecycle` clauses (P5) — sleeping waits in place on `defer_until`
   and `require_confirmation`; a release while sleeping returns to
   `evaluating`.

---

## 2. Modules and Boundary

| Module | Role |
| :--- | :--- |
| `Shoestring.Harness.CheckpointFallback` | Pure no-model template: `build/1`, `provenance_key/0`, `provenance_value/0`. |
| `Shoestring.Harness.Checkpoints` | Durable writer: `record/3`, `idempotency_key/1`. |
| `Shoestring.Cobbler.WakeupRecord` | Ecto schema over `cobbler_wakeups`. |
| `Shoestring.Cobbler.Wakeups` | Context: `schedule/2`, `reconcile/1`, `request_recheck/2`, `perform_wakeup/2`, `cancel_pending/2`, `lifecycle_state/2`. |
| `Shoestring.Cobbler.WakeupWorker` | Oban `wakeup`-queue delivery; delegates to `perform_wakeup/2`. |
| `Shoestring.Cobbler.WakeupReconciler` | Boot-only reconcile pass (E4). |
| `Shoestring.Cobbler.GoalLifecycle` | P5 clause additions only (otherwise untouched). |

`LeaseWatcher`, `LeaseBoundary`, and session semantics are untouched — no
evaluation or effects were added there (`REPO-INSPECTION`: no diff).
`shoestring_web/`, eval-matrix files, `lease_grant` / `leases` /
`lease_bounds` / `lease_renewal` internals (read-only calls only), and
dispatcher semantics/flag defaults are untouched (`REPO-INSPECTION`).

### Pinned decisions — conformance

- **P1** (`VERIFIED`): new `cobbler_wakeups` table (`id`, `goal_id` FK,
  `run_id` FK nullable, `command_id` nullable, `wake_at` not null, `reason`,
  `status`, `idempotency_key` unique, index on `status + wake_at`) — no
  dispatch row is reused. Reading note: the brief's `reason
  scheduled|due|woken|cancelled-adjacent status` is implemented as a
  free-text `reason` column plus a `status` column over
  `scheduled|due|woken|cancelled` (sibling cancellation lands rows in
  `cancelled`).
- **P2** (`VERIFIED`): keys are `"wakeup:<goal_id>:<command_id>"` or
  `"wakeup:<goal_id>:<decision_id>:<defer_until>"`; Oban `unique:
  [period: :infinity, states: :incomplete, keys: [:idempotency_key]]`.
  Manual rechecks key on `"wakeup:<goal_id>:manual:<operator>"`. When a
  terminal row already holds a base key, the next intent takes a durable
  `":r<N>"` suffix derived from row state (never time/randomness).
- **P3** (`VERIFIED`): fallback template uses durable-state inputs only,
  budgets mirror the `Checkpoint` contract and hard-fail with
  `{:error, {:checkpoint_overflow, _}}`, provenance key forced (a caller
  value under it is overwritten). No provider-output input exists.
- **P4** (`VERIFIED`): the worker follows the fixed order. Two documented
  readings: (a) a renewed lease rests at `:renewed` chained to the fresh
  snapshot — no `lease.continued` event type exists in the registry and
  `Leases` exposes no `:continue` action, so re-activation happens on the
  next grant; (b) snapshot events are recorded at observation time
  (Observatory precedent), so a wake delayed past the freshness window
  still persists the reading it acted on while evaluation judges staleness
  against perform-time `now`.
- **P5** (`VERIFIED`, true locks): three new `GoalLifecycle` clauses (see
  §5). `goal_lifecycle.ex` is otherwise byte-identical
  (`REPO-INSPECTION`: `git diff` shows only the clause addition).
- **P6** (`VERIFIED`): `request_recheck/2` returns
  `{:error, :anonymous_operator}` without an explicit operator identity,
  rejects derived `:handing_off` (and fail-closed `:unknown`) and terminal
  goals, and otherwise schedules an immediate due wake.

---

## 3. Deviations (explicit, with justification)

1. **New file `lib/shoestring/cobbler/wakeup_record.ex`** (`REPO-INSPECTION`):
   the E1 schema lives in its own file rather than inside `wakeups.ex`
   because the repo guidelines forbid multiple modules per file. Same for
   `wakeup_reconciler.ex` (E4 needs a process module; supervision placement
   only).
2. **One-token nil-safety fix in `admission_evaluation.ex:580`**
   (`REPO-INSPECTION`): `extract_snapshot_reset_at/1` (struct clause) used
   `&1.reset_at`, which raises `KeyError` on unknown windows — and every
   refused struct snapshot has unknown-only windows (both the contract
   constructor and the capacity normalizer build unknown windows without
   the key). The map clause was already nil-safe; the fix (`Map.get/2`)
   changes nothing for well-formed inputs. Without it the P4 refused row
   cannot run (verified: base code fails that test with the `KeyError`;
   fixed code passes). Reported here as an explicit deviation; the owning
   track may lift it verbatim.

---

## 4. Ordering Assumptions (documented limitations)

1. **Projection lags appends.** Chained lease transitions pre-validate
   with an explicit `:from` logical predecessor (same pattern as
   `LeaseRenewal`); the worker projects after each append phase so rows
   reflect the new state before the `woken` mark.
2. **Crash between branch writes and the `woken` mark re-performs safely:**
   the checkpoint id is the wakeup id (replay, not duplicate), the resume
   append is skipped when the run is already `starting`, and lease steps
   re-validate against stored status.
3. **Refused grants leave the claim standing** (unchanged T2 semantics).
4. **No new auto-wake semantics**: the reconciler repairs delivery only;
   the next wake after `require_confirmation` comes from an explicit
   operator `request_recheck/2`.
5. **Checkpoint contents need a run.** A deferral with no run resleeps
   without checkpoint contents (`checkpoint: :skipped_no_run`).

---

## 5. Verification

Gate: `mix precommit` in `$WORKSPACE` (exact command and counts in the
accompanying report).

New hermetic tests (`VERIFIED`), all using `Fake` idioms, `ManualClock` /
`FixedClock`, and synthetic UUID fixtures — no provider CLI, no network:

- `test/shoestring/harness/checkpoint_fallback_test.exs` (10 tests) —
  provenance present-and-forced, budgets hard-fail, determinism,
  `RequestLog` equality (zero adapter calls), no transcript interpolation.
- `test/shoestring/harness/checkpoints_test.exs` (7 tests) — record +
  project, identical replay, `run_not_owned` / `run_not_found`,
  `artifact_not_owned` mirroring the projector, invalid attrs fail closed.
- `test/shoestring/cobbler/wake_reobserve_test.exs` (4 tests, `ManualClock`
  matrix) — fresh→renew+resume (lease `renewed` chained to the fresh
  snapshot, run `starting`, zero `dispatch`-queue jobs); refused→expire +
  checkpoint (fallback provenance) + resleep with a new `wake_at` (run
  stays suspended); stale→`require_confirmation` with no resume and no
  lease change; probe failure leaves the intent due with nothing appended.
- `test/shoestring/cobbler/wakeup_reconcile_test.exs` (5 tests) — boot
  repair, no-dupe second pass, past-due flip, future rows untouched,
  terminal-goal cancel.
- `test/shoestring/cobbler/wakeup_idempotency_test.exs` (5 tests) — same
  command/decision key twice → one effect; terminal-row suffix reschedule;
  re-performing a `woken` row is a no-op; missing identity fails closed.
- `test/shoestring/cobbler/manual_recheck_test.exs` (7 tests) — anonymous
  rejected, handing_off rejected, terminal rejected, unknown derivation
  fails closed, live and sleeping goals get an immediate due wake, no
  prior decision fails closed.
- `test/shoestring/cobbler/goal_lifecycle_sleeping_test.exs` (5 tests) —
  the P5 clauses plus preserved sleeping twins.

Fail-on-base verification (against `d3ca088`):

- `goal_lifecycle_sleeping_test.exs`: 4 of 5 **fail on base for the right
  behavioural reason** (`{:error, {:invalid_transition, :sleeping, _}}`
  where `{:ok, _}` is asserted) — true regression locks. The twins test
  passes on both (preserved behavior, labeled as such).
- Refused matrix row with base `admission_evaluation.ex`: **fails on base**
  (`KeyError` in `extract_snapshot_reset_at/1`) — the deviation fix is
  load-bearing.
- All other new tests error on base via missing modules/table —
  **documentation, not locks** (stated in each file's moduledoc per the
  standing contract).

Fixtures use format-valid synthetic identifiers only; no credentials,
tokens, paths, or machine identifiers are committed.

No live provider runs were made; no run budget was authorized.
