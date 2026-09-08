# Milestone 05: Cobbler Goal Lifecycle, First Gated Dispatch Consumer, and Projector Survival

- **Status**: Work package A remainder (Milestone 05, stacked on the durable commands slice at `d618030`)
- **Scope**: Goal-level lifecycle machine above the command machine, first gated dispatch consumer with an explicit execution-disabled boundary, opt-in Cobbler gate on the direct dispatch path, and goal/task projector survival across `cobbler.*` / `admission.decided` events.
- **Evidence Labels**: `VERIFIED` (hermetic ExUnit runs in this worktree), `REPO-INSPECTION` (committed code), `UNVERIFIED` (explicitly marked).

---

## 1. Executive Summary

1. **Goal lifecycle machine** (`VERIFIED`): `Shoestring.Cobbler.GoalLifecycle` is a pure machine with states `evaluating | queued | dispatching | working | checkpointing | sleeping | handing_off`, driven by admission decisions and persisted command outcomes. It adds a level *above* the command machine; command semantics are unchanged.
2. **First gated dispatch consumer** (`VERIFIED`): `Shoestring.Cobbler.Dispatcher` reads `cobbler_commands` rows, re-validates the admission reference and live claim ownership, preserves identical-replay / conflict semantics, and stops validated claims at an explicit execution-disabled boundary. Nothing is spawned or enqueued.
3. **Direct dispatch paths gain opt-in protection** (`VERIFIED`): `Dispatches.enqueue/3` (and `Elves.start_run/3` via option forwarding) accept `require_cobbler_command: true` and reject goals holding no live claim with `{:error, {:no_claimed_command, _}}` instead of bypassing commands. Off by default; the default path is byte-for-byte the old behavior.
4. **Projector no longer halts on `cobbler.*`** (`VERIFIED`): the goal/task projector passes `admission.decided` and all `cobbler.*` events through (unknown future `cobbler.*` types/versions advance without halting). Non-cobbler unknown events still halt visibly, as before.
5. **No timers, no leases, no backfill** (`REPO-INSPECTION`): sleeping goals wake only on an explicit `:recheck_due` event; `handing_off` is terminal; the consumer performs no execution and no provider backfill exists.

---

## 2. Modules and Boundary

| Module | Role |
| :--- | :--- |
| `Shoestring.Cobbler.GoalLifecycle` | Pure goal machine: `transition/2`, `initial/0`, `terminal?/1`, `decision_event/1`, `command_event/1`, `apply_decision/2`, `apply_command/2`. |
| `Shoestring.Cobbler.Dispatcher` | Gated consumer: `claim_and_gate/3` (submit, then gate), `dispatch/3` (gate an existing row). |
| `Shoestring.Cobbler.DispatchGate` | Read-only claim check used by direct paths: `authorize/2`. |
| `Shoestring.Cobbler` | Facade additions: `lifecycle_transition/2`, `claim_and_gate/3`, `dispatch_command/3`, `authorize_dispatch/2`. |

Lifecycle transitions of note (`REPO-INSPECTION`):

- `evaluating + admit -> queued`; `evaluating + defer_until -> sleeping`; `require_confirmation` waits in place; `reject -> handing_off` (terminal).
- `queued + claimed -> dispatching`; `needs_user` waits recoverably in `queued`; `rejected`/`abandoned` return to `evaluating`.
- `dispatching + dispatch_blocked -> dispatching` (the gate holds; it never bypasses); `dispatch_started -> working`.
- `working <-> checkpointing` cycle; `run_terminal -> evaluating`; `sleeping + recheck_due -> evaluating` (explicit wake-up only).
- Illegal transitions return `{:error, {:invalid_transition, state, event}}` and coerce nothing.

---

## 3. Execution-Disabled Boundary

A fully validated dispatch returns (`VERIFIED`):

```elixir
{:error, {:execution_disabled, %{boundary: "execution_disabled", goal_id: _, command_id: _, outcome: _, claim_id: _, admission_event_id: _}}}
```

`detail` names exactly what a future enabled execution path must consume. Hermetic proof: gated flows leave `oban_jobs` at zero (`Repo.aggregate(Job, :count, :id) == 0`) and `dispatch/3` on a non-claimed row returns `{:error, {:no_claimed_command, _}}`.

---

## 4. Projector Survival

- `ProjectorTransition` passes `admission.decided` and any `"cobbler." <> _` type through with `task_action: :none` (`REPO-INSPECTION`).
- `Projector.project_event_from_storage/1` degrades only `{:unknown_event_type, _}` and `{:unknown_event_version, _, _}` failures for `cobbler.*`-prefixed types into an unvalidated passthrough; every other validation failure still halts visibly, and registered `cobbler.*` events still validate exactly as before (`REPO-INSPECTION`).
- Projector implementation version stays `1`: the change is additive, existing positions remain valid, and no migration was required (`REPO-INSPECTION`).
- `elf.*` events are untouched (owned by a parallel work package) (`UNVERIFIED` beyond this note).

---

## 5. Verification

Gate: `mix precommit` in `$WORKSPACE` (exact command and counts in the accompanying report).

New hermetic tests (`VERIFIED`), all using `Shoestring.Harness.Fake` idioms, synthetic UUID fixtures, or trivial local state — no provider CLI, no network:

- `test/shoestring/cobbler/goal_lifecycle_test.exs` — pure machine: full admit-to-terminal walk, gate-wait, explicit wake-up, terminal handoff, illegal-transition rejection.
- `test/shoestring/cobbler/dispatcher_test.exs` — consumer: execution-disabled boundary with zero Oban jobs, identical-replay re-gating without new events, conflict rejection, held-claim operator wait, `dispatch/3` rejection and gating.
- `test/shoestring/trajectory/projector_cobbler_test.exs` — projector advances past `goal.created`, `admission.decided`, registered `cobbler.*`, and an unknown future `cobbler.future_probe` event to sequence 5 with status `"ok"`, then keeps projecting later `task.created` events.
- `test/shoestring/harness/dispatches_cobbler_gate_test.exs` — gated enqueue rejected with no claim and with a foreign claim (nothing persisted, nothing enqueued), admitted with a live claim, ungated default unchanged.

Regression-against-base checks (each run against the pre-fix commit `d618030` by stashing this slice's tracked `lib/` changes while keeping the new test files):

- Projector test **fails on `d618030` for the right behavioural reason**: `{:error, {:projection_failed, 2, {:invalid_transition, :unsupported_event, "admission.decided"}}}` — the documented §8 halt. True regression lock.
- Gate tests **fail on `d618030` for the right behavioural reason**: both rejection tests (`no claim`, `foreign claim`) fail because the old code ignores the unknown flag and enqueues. True regression lock (the proceed-with-claim and ungated-default tests pass on both, documenting preserved behavior).
- Dispatcher tests **pass on `d618030`** (6/6 with old store code): the consumer is new surface and the replay/conflict semantics it relies on predate this slice, so per the standing contract these are documentation, not a behavior-change lock. Stated honestly here rather than claimed as coverage.

---

## 6. Honest Limitations

- Direct run paths are protected only when callers pass `require_cobbler_command: true`; the default remains unprotected. Wiring the flag on by default (or into schedulers/Oban workers) is future work owned alongside the execution-enablement slice.
- The consumer performs at most one gating decision per call; there is no background poller or queue over `cobbler_commands` rows yet.
- `handing_off` has no outgoing transitions (terminal by design); recovery flows out of handoff are future work.
- No live provider runs were made; no run budget was authorized.
