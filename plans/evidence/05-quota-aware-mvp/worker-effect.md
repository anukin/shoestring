# Loop-closure W2 — Production dispatch-worker effect: worker delivery starts the Elf

## Problem (VERIFIED)

`Shoestring.Harness.DispatchWorker.dispatch_effect/0`
(`lib/shoestring/harness/dispatch_worker.ex:88`) defaults to
`Shoestring.Harness.Dispatch.UnconfiguredEffect`
(`:dispatch_effect_not_configured`), and no environment configured a
production effect: `git show 4735d9f:config/runtime.exs` contains no
`:dispatch_effect` entry (REPO-INSPECTION). Every Oban-delivered automatic
dispatch (wakeup continuations, crash-recovery requeues) therefore recorded
`effect_failed` without starting anything. UI manual runs worked only
because `ShoestringWeb.RunNewLive.gated_dispatch/5` enqueues AND calls
`Elves.start_elf/3` directly.

## What changed (VERIFIED — committed code)

- **New** `lib/shoestring/harness/dispatch/elf_effect.ex`:
  `Shoestring.Harness.Dispatch.ElfEffect`, a `@behaviour
  Shoestring.Harness.Dispatch.Effect` production effect. `perform/2`
  rebuilds the `RunRequest` via `Elves.request_from_run/1` (read-only CALL;
  `elves.ex`, `dispatches.ex`, `runs.ex`, `run_new_live.ex` unmodified) and
  calls `Elves.start_elf/3` with fire semantics: it reports delivery, it
  does not wait for run terminal (contrast the blocking
  `Shoestring.Elves.DispatchEffect` used by operator/test paths).
- `config/runtime.exs`: `config :shoestring, :dispatch_effect,
  Shoestring.Harness.Dispatch.ElfEffect` inside `if config_env() == :prod`
  only. The `DispatchWorker` fail-closed default is unchanged; `test.exs`
  is untouched (tests inject `:dispatch_effect` per test).
- **New** `test/shoestring/harness/dispatch/elf_effect_test.exs`: 6 hermetic
  tests (Oban `:manual`, `Fake` adapter, trivial `sleep` command, isolated
  Elf supervisor per test; no provider CLI, no network).

## Start/outcome mapping (VERIFIED — `elf_effect.ex` + worker clauses)

| Effect return | Worker mapping (`dispatch_worker.ex:41`) | Dispatch outcome |
|---|---|---|
| `:ok` (fresh `start_elf`) | `complete_effect` | `effect_completed` |
| `{:ok, :already_running}` (2-tuple; the 3-tuple is normalized in the effect because the worker maps any other shape to unknown) | `complete_effect` | `effect_completed`, no second Elf |
| `{:error, reason}` (e.g. `{:error, :max_children}`) | `failed_outcome` | `effect_failed` (failed, not unknown; `outcome_code` stays `"effect_failed"` per locked persistence) |
| `{:unknown, :invalid_persisted_request}` (unrebuildable request) | catch-all | `effect_unknown`; no execution invented |
| `{:unknown, :unknown_provider}` (unrecognized `provider_id`) | catch-all | `effect_unknown`; no execution invented |

Provider launch defaults mirror the manual-run UI's provider branches
(read-only reference): `shoestring.harness.fake` → `Fake`/`sleep 30`;
`codex_app_server_stdio` → `CodexAppServer`; `claude_headless_stream_json`
→ `ClaudeHeadless`. `:elf_dispatch_opts` env overrides per key.

## Pinned decisions ledger

- P1 (new production effect calling `start_elf`, UI mapping mirrored): kept,
  no deviation.
- P2 (outcome mapping above): kept, no deviation. One deliberate
  conservative reading: `invalid persisted request → unknown` is realized
  through the worker's existing catch-all (`{:unknown, reason}` return)
  with **zero changes to `dispatch_worker.ex`**, so all locked worker
  behavior (including `outcome_code == status` persistence) is byte-for-byte
  preserved. The file ownership granted `dispatch_worker.ex` access but no
  edit was required; the default is untouched per P3.
- P3 (prod wiring; test keeps manual override; unconfigured stays
  fail-closed): kept, no deviation.
- P4 (already-running → complete, one Elf; crash resolves via existing
  reconcile → requeue → outcome paths): kept, no deviation. No waiting, no
  timers, no new mechanisms in the effect.
- P5 (no new trajectory event types; no claim/gate changes): kept —
  only pre-existing `dispatch.requested` / `dispatch.effect_*` /
  `run.*` events are emitted, all by pre-existing code paths.

## Lock vs documentation ledger (VERIFIED — executed)

Fail-on-base was verified two ways against base `4735d9f`: (A) implementation
file moved out + `runtime.exs` wiring stashed (base tree + new tests), and
(B) worker pointed at `UnconfiguredEffect` (true base-default behavior,
module present). Exact observations:

- `configured effect starts exactly one Elf and the run reaches terminal` —
  **LOCK**. Fails on A (`{:cancel, :effect_outcome_unknown}` where `:ok`
  asserted, no Elf, no terminal); fails on B (`effect_failed` where started
  asserted).
- `already-running Elf completes the delivery without a second Elf` —
  **LOCK** (effect idempotency + 2-tuple completion mapping). Errors on A
  (module absent — mechanical, not behavioural; noted honestly); passes on B
  (direct effect calls are wiring-independent by design). Guards
  duplicate-Elf regressions of the new code.
- `invalid persisted request records effect_unknown` — **LOCK** (P2's exact
  failed-vs-unknown distinction). Fails on B (`effect_failed` where
  `effect_unknown` asserted). Passes on A only via the missing-module rescue
  coincidence (also `effect_unknown`), recorded here rather than claimed.
- `recovery requeue after a crashed delivery executes through the effect` —
  **LOCK**. Fails on A and B (no Elf started, wrong outcome).
- `unconfigured effect still fails closed` — **documentation** of locked
  behavior (passes on base and fixed: `effect_failed`, no Elf, no terminal).
- `start error records effect_failed` — **documentation** of preserved
  classification (passes under base-default wiring; fails on A with
  `effect_unknown`, pinning failed-not-unknown). Includes a direct
  `{:error, :max_children}` return assertion.

## Gate (VERIFIED)

- `mix precommit` (format check + `compile --warnings-as-errors` + full
  ExUnit + node gate): exit `0`.
- ExUnit: `1137 tests, 0 failures, 1 skipped (6 excluded)` — includes the 6
  new tests.
- Node gate (`gate_0a.node_test`): `52 pass, 0 fail`.

## File ownership

Touched only: the new effect module, `config/runtime.exs`, the new test
file, this note (+ one-line README inventory addition). `dispatch_worker.ex`
required no edit (see P2 note). W1-owned files (`wakeup_observe.ex`,
`admission_evaluation.ex`, `wakeups.ex` observe plumbing) and read-only
references (`elves.ex`, `dispatches.ex`, `runs.ex`, `run_new_live.ex`) were
not modified. No deviations to report beyond the documented P2 reading.
