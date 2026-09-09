# Milestone 05: Production Wakeups — Observe Config, Admitted Dispatch, Manual Recheck (Loop-Closure I4)

- **Status**: Loop-closure I4 on `85437ed` (branch `polly/iter5-i4-wakeup`).
- **Scope**: Production `:wakeup_observe` wiring (P1), admitted-branch
  continuation dispatch through the durable pipeline (P2), goal-page manual
  wake/recheck control (P3), sleep-card producer/countdown rewrite (P4).
  `dispatches.ex` is called read-only (never modified); `elf.ex`,
  `elves.ex`, `goal_lifecycle` states, and presentation/timeline derivation
  are untouched.
- **Evidence Labels**: `VERIFIED` (hermetic ExUnit runs in this worktree),
  `REPO-INSPECTION` (committed code), `UNVERIFIED` (explicitly marked).

---

## 1. What changed (`REPO-INSPECTION`)

| File | Change |
| :--- | :--- |
| `lib/shoestring/cobbler/wakeup_observe.ex` (new) | `observe/0`: freshest Observatory ledger observation across provider/mode/scope targets (ordered by provider `observed_at`); fail-closed `:no_observation` on an empty ledger, `:observation_unavailable` on read crash. |
| `config/runtime.exs` | `:prod` only: `config :shoestring, :wakeup_observe, {WakeupObserve, :observe, []}`. Test/dev keep explicit `:observe` injection. |
| `lib/shoestring/cobbler/wakeup_worker.ex` | `:wakeup_observe` accepts a zero-arity fun **or** an MFA tuple (applied at perform time); anything else keeps the fail-closed `missing_observe_fun`. |
| `lib/shoestring/cobbler/wakeups.ex` | Admitted branch now dispatches one continuation via `Dispatches.enqueue/3` (never `Elves.start_run/3`); see §2. `perform_wakeup/2` accepts `:identity` (default `Fake.identity/0`, mirroring `Leases`). |
| `lib/shoestring_web/live/cobbler_goal_live.ex` + `.html.heex` | Sleep card rewritten (P4) with the pending durable wake intent as the countdown source; new `request_recheck` control (P3) with explicit operator identity. |

## 2. Admitted → dispatch → Elf chain (`REPO-INSPECTION`)

`wakeup` row (due) → `WakeupWorker.perform/1` → `Wakeups.perform_wakeup/2`
(fresh snapshot → `AdmissionEvaluation` with claim occupancy) → `:admit` →
renew lease + resume run (`run.starting` on the suspended run) →
`Dispatches.enqueue/3` with a **new** continuation run of the same goal+task
(workspace, prompt, policy, capabilities carried from the suspended run's
durable record; `continuation: nil`; `dispatch_id = wakeup.id`;
`require_cobbler_command: true`) → `harness_dispatches` record + Oban
`dispatch`-queue job → `DispatchWorker` claims → Elf executes.

- Waking dispatches work exactly when persisted intent + trajectory allow:
  the admission evaluation (persisted decision + live claim occupancy) gates
  `:admit`, and the enqueue-time `DispatchGate` re-authorizes the live claim
  — an admit without the claim fails closed and the intent stays due.
- A crash between enqueue and the `woken` mark re-performs into the dispatch
  pipeline's own recovery (`Runs.recover_existing_run/2` +
  `ensure_delivery/2`) because the `dispatch_id` is deterministic per wakeup
  row: one dispatch record, one job, never a direct Elf start.
- With no run there is nothing to continue: dispatch stays `:gated` and the
  goal still reaches queued to wait for the claim flow.

## 3. Pinned decisions — conformance

- **P1** (`VERIFIED` by tests §4, `REPO-INSPECTION` for the file wiring):
  production observe is configured in `config/runtime.exs`; the worker keeps
  fail-closed `missing_observe_fun` when unconfigured. Minor deviation:
  stored as an **MFA tuple** rather than a fun capture (captures do not
  belong in config), so the worker resolves fun-or-MFA. Test env keeps Fake
  injection (explicit `:observe`; no `:wakeup_observe` outside `:prod`).
- **P2** (`VERIFIED`): admitted dispatches through `Dispatches.enqueue/3`
  with the wakeup-derived idempotent `dispatch_id`; `dispatches.ex` is
  called read-only (`REPO-INSPECTION`: no diff). Documented in the
  `Wakeups` moduledoc and §2 above.
- **P3** (`VERIFIED`): goal-page `request_recheck` control calls
  `Wakeups.request_recheck/2` with an explicit, trimmed operator identity
  (anonymous rejected, P6 convention); duplicate rechecks replay the queued
  intent (idempotency-key dedupe) instead of duplicating it; no timers.
- **P4** (`VERIFIED`): the stale "wake producer lands in T3" text is gone;
  the card names the real producer (Oban wakeup-queue deliveries for
  `cobbler_wakeups` rows, re-observing before acting) and the countdown
  source (the decision `defer_until` plus the pending durable wake intent's
  `wake_at`). No timestamps invented: `pending_wakeup` renders only the
  persisted row's `wake_at`.

## 4. Verification (`VERIFIED`)

Hermetic only (`Fake` + `ManualClock`, Oban `:manual`; no provider CLI, no
network, no live runs). New/updated tests:

- `test/shoestring/cobbler/wakeup_production_test.exs` (8 tests): admitted
  dispatches exactly one record + one job; double perform is one effect;
  admitted-through-worker dispatches; admit-without-run stays `:gated`;
  worker-without-observe fails closed with the intent due; worker-with-observe
  reaches the deferred branch; `WakeupObserve` ledger re-probe;
  runtime-config wiring contract.
- `test/shoestring_web/live/cobbler_goal_recheck_test.exs` (5 tests):
  control renders; attributed recheck schedules one intent + one job;
  anonymous rejected with nothing scheduled; duplicate recheck is a single
  effect; corrected sleep text with no invented timestamp.
- Updated: `wake_reobserve_test.exs` admit row (dispatch assertions replace
  `:gated`), `cobbler_goal_live_test.exs` sleep-text row (no `T3`).

Fail-on-base (scratch worktree at `85437ed`, new/updated test files copied
in, `mix test` run there). `wakeup_production_test.exs`: 8 tests,
5 failures — the three admitted-dispatch count assertions (`left: 0,
right: 1` on `harness_dispatches`), the `WakeupObserve` ledger test
(`UndefinedFunctionError`, missing module), and the runtime-config wiring
test (base file lacks `:wakeup_observe`). Combined
`wake_reobserve_test.exs` + `cobbler_goal_recheck_test.exs` +
`cobbler_goal_live_test.exs`: 28 tests, 7 failures — the updated admit
matrix row (dispatch count `0` vs `1`), all 5 recheck-control tests (no
`#cobbler-recheck-form` element on base), and the updated sleep-text test
(base card lacks `cobbler_wakeups`, still carries `T3`).

- True locks (fail on base for the behavioural reason): admitted-dispatch
  ×3 in the new file + ×1 updated matrix row; recheck control ×4
  (presence, submit, anonymous, duplicate); sleep text ×2 (new producer
  test + updated honesty test); config-wiring ×1 (base file has no
  `:wakeup_observe`).
- Documentation (pass-or-error on base, no behaviour change, stated
  honestly in each file's moduledoc): no-run admit twin, worker
  fail-closed, worker-refused reachability, `WakeupObserve` ledger cases.

## 5. Known seams (`UNVERIFIED`, not introduced here)

- Crash between branch writes and the `woken` mark still re-validates lease
  steps against stored status (pre-existing ordering assumption from the T3
  slice); the new dispatch step itself is retry-safe via the deterministic
  `dispatch_id`.
- The resumed-then-superseded run ends at `run.starting` with no effect of
  its own while the continuation run executes; orphan reconciliation for
  that shape belongs to the Elf-owning slice (I5) and was not touched.
- Multi-scope deployments: `WakeupObserve` returns the freshest reading
  across scopes; evaluation still judges freshness/state/occupancy, but
  scope-pinned selection is future work (documented in the module).

No live provider runs were made; no run budget was authorized. Fixtures use
format-valid synthetic identifiers only (`01950000-…` shape); no
credentials, tokens, paths, or machine identifiers are committed.
