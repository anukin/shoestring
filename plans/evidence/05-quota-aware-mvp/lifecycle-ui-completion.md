# Milestone 05: Lifecycle Terminal States + Interleaved Presentation (Loop-Closure I6)

- **Status**: Loop-closure I6 (Milestone 05, stacked on `85437ed`: attribution slice).
- **Scope**: Outcome-carrying goal lifecycle terminals (`completed` / `failed` /
  `needs_user`) with a preserved outcome-less recycle dual-path, a
  sequence-ordered timeline derivation in `CobblerPresentation`
  (decisions + commands + run progress interleaved by sequence), a
  read-only handoff card plus capacity-evidence block on the goal page,
  and hermetic regression coverage. No sleep-card, recheck-control,
  wakeup, registry, projector, dispatcher, or elf-ingest changes.
- **Evidence Labels**: `VERIFIED` (hermetic ExUnit runs in this worktree),
  `REPO-INSPECTION` (committed code), `UNVERIFIED` (explicitly marked).

---

## 1. Modules and Boundary (`REPO-INSPECTION`)

| Module | Role |
| :--- | :--- |
| `Shoestring.Cobbler.GoalLifecycle` | Pure goal machine: new states `completed` / `failed` / `needs_user`, new `{:run_terminal, outcome}` events, `run_outcomes/0`, `run_terminal_event/1`; bare `:run_terminal` recycle preserved (deprecated dual-path). |
| `ShoestringWeb.CobblerPresentation` | New `derive_goal_state/1` folds ONE sequence-ordered timeline (trajectory structs, `%{sequence, kind, value}` maps, or `{sequence, event}` tuples); legacy `derive_goal_state/2` kept and marked deprecated; new `completed` / `failed` / `needs_user` presentations with distinct `data-status` tags; `:unknown` fallback kept, never raises. |
| `ShoestringWeb.CobblerGoalLive` | `load_detail` derives state from the replay timeline; new read-only handoff card (`#cobbler-handoff*`) from persisted `handoff.created` events; admission card gains a capacity-evidence block (`#cobbler-decision-observation`). Sleep card, recheck affordances, streams, and the attribution-gated respond path untouched. |
| `ShoestringWeb.CobblerDashboardLive` | `goal_summary` derives state from the same replay timeline; no template change (status tags flow through). |

Lifecycle transitions of note (`REPO-INSPECTION`):

- `working` / `checkpointing` + `{:run_terminal, :completed}` → `:completed` (terminal).
- `working` / `checkpointing` + `{:run_terminal, :failed}` → `:failed` (terminal).
- `working` / `checkpointing` + `{:run_terminal, :needs_user}` → `:needs_user` (waiting, non-terminal).
- `working` / `checkpointing` + bare `:run_terminal` → `:evaluating` (legacy recycle, deprecated but supported).
- `:needs_user` waits on `{:command_outcome, :needs_user}` and
  `require_confirmation`; returns to `:evaluating` on `abandoned` /
  `released` / `rejected` (the attribution-gated respond path); admits
  `admit` → `:queued`, `defer_until` → `:sleeping`, `reject` /
  `:handoff_requested` → `:handing_off`.
- `:completed` / `:failed` are terminal like `:handing_off`: every event
  (including `:handoff_requested`) is rejected with
  `{:error, {:invalid_transition, _, _}}`.
- Timeline run-signal mapping (read-only, no writes): `run.starting` /
  `run.running` → `:dispatch_started` (no-op when already working /
  checkpointing), `checkpoint.created` → `:checkpoint_started` (no-op when
  already checkpointing), `run.completed` / `run.failed` → outcome-carrying
  terminals, `run.interrupted` / `run.cancelled` / `run.cancelling` →
  legacy `:run_terminal`, `run.suspended` / `run.pausing` while working or
  checkpointing → `:sleeping`, `handoff.created` → `:handoff_requested`.
  Lifecycle-irrelevant types (`lease.*`, `capacity.*`, `task.*`, `goal.*`,
  `dispatch.*`, `harness.*`, `elf.*`) are skipped; idempotent claim
  replays (`acquired` beside its `accepted`, release while already
  `:evaluating`) keep state instead of halting to `:unknown`.

---

## 2. Pinned Decisions — Conformance

- **P1** (`VERIFIED`): terminal outcome states exist with transitions from
  `working` / `checkpointing` carrying the outcome class; the
  evaluating-recycle path still works for outcome-less callers
  (dual-path). The consumer inventory below was taken before changing
  call sites; `Wakeups` (I4) and `Elves.handoff_transition` (I5) needed
  no changes (their events still behave identically). Deprecation note
  lives in `GoalLifecycle` moduledoc and here: new producers should pass
  outcomes; the bare path is supported, not removed.
- **P2** (`VERIFIED`): presentation derives from one sequence-ordered
  timeline with the `:unknown` fallback kept and never raising; run
  progress contributes working/checkpointing/sleeping signal as a
  read-only derivation (no new writes — `git diff` shows no writer,
  registry, or projector changes).
- **P3** (`VERIFIED`): `handing_off` stays terminal and the handoff card
  states the I5 contract (a handoff targets a NEW run of the SAME goal);
  `completed` / `failed` are terminal; `needs_user` waits with the
  existing respond path (attribution-gated; `do_respond` untouched).
- **P4** (`VERIFIED`, `REPO-INSPECTION`): no sleep-card, recheck-control,
  wakeup, registry, or projector-schema changes — `git diff --stat`
  shows only `goal_lifecycle.ex`, `cobbler_presentation.ex`,
  `cobbler_dashboard_live.ex`, `cobbler_goal_live.ex`, and
  `cobbler_goal_live.html.heex` under `lib/`. The sleep countdown +
  manual recheck UI stays with I4 (see §5).
- **P5** (`VERIFIED`): every template still opens with `<Layouts.app
  flash={@flash} current_scope={@current_scope}>`; `<.icon>` / `<.input>`
  / streams discipline unchanged; existing element IDs untouched —
  additions only (`#cobbler-handoff`, `#cobbler-handoff-empty`,
  `#cobbler-handoff-{sequence}`, `#cobbler-handoff-source-{sequence}`,
  `#cobbler-handoff-receiver-{sequence}`,
  `#cobbler-decision-observation`).

No deviations from P1–P5.

---

## 3. Consumer Inventory + Dual-Path Justification (`REPO-INSPECTION`)

| Consumer | What it calls today | What changes for it |
| :--- | :--- | :--- |
| `Cobbler.lifecycle_transition/2` (facade) | Pass-through to `GoalLifecycle.transition/2` | None (type widens automatically). |
| `Wakeups.lifecycle_state/2` + wake branches (I4-owned, read-only) | Grouped decisions + command-kind fold; `:recheck_due`, `:admit`, `defer_until` / `require_confirmation` / `reject` transitions | None — untouched; its folded subsets contain no run-terminal events, and all its transitions behave identically. |
| `Elves.handoff_transition/1` (I5-owned, read-only) | `:handoff_requested` from a live goal state | None — untouched; additionally `:needs_user` may now hand off. |
| `CobblerPresentation.derive_goal_state/2` callers (dashboard, goal page) | Grouped fold, run progress invisible | Migrated to `derive_goal_state/1` (timeline); `/2` kept deprecated for T1/T3 consumers. |
| T1/T3 outcome-less terminal drivers | Bare `:run_terminal` | Preserved byte-for-byte (twins); migrate to `run_terminal_event/1` outcomes at their own pace. |

Dual-path justification: removing the bare recycle would break T1/T3
callers that drive terminals without an outcome class (their producers
do not know success vs failure vs needs-user yet). Both paths are
locked by twins; the bare path is deprecated, not removed.

---

## 4. Verification

Gate: `mix precommit` in `$WORKSPACE` (`VERIFIED`, exit 0):

- `format --check-formatted` clean, `compile --warnings-as-errors` clean.
- Elixir: **1082 tests, 0 failures, 1 skipped (6 excluded)**.
- Node (`gate_0a.node_test`): **52 tests, 52 pass, 0 fail**.

New hermetic tests (`VERIFIED`), Fake + fixtures + synthetic UUIDs only,
no provider CLI, no network:

- `test/shoestring/cobbler/goal_lifecycle_outcomes_test.exs` (9 tests) —
  6 TRUE LOCKS (outcome terminals from working/checkpointing, terminality
  of completed/failed, needs_user waits/exits, full walk; each fails on
  `85437ed` with `{:error, {:invalid_transition, _, {:run_terminal, _}}}`
  where `{:ok, _}` is asserted), 1 DOCUMENTATION (`run_terminal_event/1`
  is new surface: `UndefinedFunctionError` on base), 2 preserved-behavior
  twins (bare recycle; outside-state rejection shape passes on both).
- `test/shoestring_web/live/cobbler_timeline_test.exs` (9 tests) —
  1 TRUE LOCK (10 distinct status tags: 8 vs 10 on base),
  7 DOCUMENTATION (new `derive_goal_state/1`: `UndefinedFunctionError`
  on base), 1 preserved-behavior twin (legacy `/2` results pass on
  both).
- `test/shoestring_web/live/cobbler_goal_terminal_test.exs` (5 tests) —
  5 TRUE LOCKS (completed / failed / interrupted-recycle statuses,
  handoff card, observation block; each fails on `85437ed` with a missing
  or wrong `data-status` / element ID for the right behavioural reason:
  run progress and handoff events were invisible to the grouped fold).

Fail-on-base verification (`VERIFIED`): `lib/` stashed to `85437ed`
with the new test files kept, per-file `MIX_ENV=test mix test`, then
`lib/` restored byte-identical (stash pop): **23 tests, 20 failures**,
each failing for the documented reason above; the 3 passes are the
labeled twins.

Updated existing test (`REPO-INSPECTION`): `goal_lifecycle_test.exs`
"initial state ..." now asserts `completed` / `failed` terminal and
`needs_user` non-terminal — an intended contract change of this slice,
not a weakening (the old assertion contradicts P1).

Fixtures use generated UUIDs and format-valid synthetic shapes only; no
credentials, tokens, paths, or machine identifiers are committed.

---

## 5. Honest Limitations

- Goal-level `needs_user` has no trajectory producer yet: no current
  `run.*` type maps to `{:run_terminal, :needs_user}` (it is reachable
  via timeline maps and the machine, unit-covered). Run producers should
  emit it when a run finishes awaiting an operator; until then the page
  reaches operator-wait through the command-level `needs_user` confirm
  forms (unchanged).
- Sleep countdown + manual recheck UI is I4-owned (P4): the sleep card
  still states that no wake source is recorded and waking needs an
  explicit recheck; no timestamp is invented here.
- `Wakeups.lifecycle_state/2` keeps its own grouped derivation mirror
  (I4-owned file, untouched): it folds decisions + command kinds only,
  so run-terminal outcomes are invisible to it by design. If I4 wants
  outcome-aware wake derivation, it can adopt `derive_goal_state/1`.
- No live provider runs were made; no run budget was authorized.
