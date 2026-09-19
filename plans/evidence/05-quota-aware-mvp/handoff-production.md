# Milestone 05: Production Cross-Provider Handoff

- **Status**: Iteration-5 production slice, stacked on `01f2a54`
  (origin/main, PR #71 merged).
- **Scope**: `Shoestring.Cobbler.Handoffs` (new), the `run.handoff` durable
  Cobbler command type, and the twin session-lookup fix in
  `Shoestring.Elves`. UI, `Shoestring.Elves.Elf`, `TerminalCheckpoint` and
  the checkpoint/resume suites are untouched.
- **Evidence labels**: `VERIFIED` (command output from this run),
  `REPO-INSPECTION` (committed code), `UNVERIFIED` (explicitly marked).

---

## 1. What was actually wrong (`REPO-INSPECTION`, verified before changing anything)

The prior slice built the handoff **projection** and stopped there.
`Shoestring.Elves.resume_run/2` validated the continuation, appended
`handoff.created`, created a receiver run and called `adapter.start/2`
directly. Compared against the production pattern the wake path already
established (`Shoestring.Cobbler.Wakeups.perform_wakeup/2`), four things
were missing and one was wrong:

| Gap | Base behaviour (`01f2a54`) | Consequence |
| :--- | :--- | :--- |
| No explicit production command | `resume_run/2` is a direct API call; no durable intent row | A crashed handoff had no intent to replay against |
| No receiver admission | Zero `capacity.snapshot_observed`, zero `admission.decided` for the receiver | The receiver was transferred to without anyone asking whether it had capacity, was compatible, or was supported |
| No receiver lease | `handoff.created` carried `latest_lease_id` of the **sender** | The receiver executed unbudgeted, on an allowance granted to a different run |
| No durable supervised dispatch | `adapter.start/2` called inline | No `harness_dispatches` row, no Oban delivery, no supervised Elf — the receiver ran outside the pipeline that owns process groups and cancellation |
| Session lookup keyed wrong | `live_receiver_session?/2` looked the receiver up by `stored_run.id` only | See §4 — duplicate receiver sessions |

`RunRequest`, `Continuation`, the `handoff.created` registry entry and both
projector arms were already correct and are unchanged.

---

## 2. What this slice adds (`REPO-INSPECTION`)

| Module | Role |
| :--- | :--- |
| `Shoestring.Cobbler.Command` | `run.handoff` joins the closed type set; payload normalization for `run_id`, `checkpoint_id`, `to_provider_id`, `to_adapter_id`, `scope`, `reason`, and the attributable `requested_by`. |
| `Shoestring.Cobbler.Commands` | `evaluate/4` clause recording the handoff intent, plus `validate_handoff_reference/3` (run goal-owned, checkpoint goal-owned, checkpoint belongs to that run, receiver differs from sender). Execution stays disabled: the store records intent and stops. |
| `Shoestring.Cobbler.Handoffs` (new) | `request/3` (durable intent) and `perform/3` (observe → admit → create → grant → point → dispatch), with the idempotency guard, the boundary check, the one-active-Elf guard and the convergence path. |
| `Shoestring.Elves` | `live_receiver_session?/2` and `resolve_session/2` now probe dispatch id before run row id. |
| `priv/repo/migrations/20260919034454_widen_cobbler_command_types.exs` | SQLite table rebuild widening `cobbler_commands_type_valid`. |

### Ordering, and why

`request/3` writes the intent and nothing else. `handoff_id` **is** the
command row id, so every effect in `perform/3` is keyed off durable
identity — not wall-clock time, not randomness — matching the `Wakeups`
idempotency rule. The receiver's `dispatch_id` is the same id, so
`Runs.request/3` recovers a row a crashed attempt already inserted instead
of creating a second one.

`perform/3` runs:

1. boundary — the named checkpoint must still be the run's latest projected
   checkpoint (`:stale_continuation` otherwise), then
   `Continuation.validate_resume/3` in `:handoff` mode;
2. one active Elf — a live `Elves.whereis/1` pid or a `starting`/`running`
   run row refuses; nothing is cancelled, interrupted or signalled from
   here;
3. idempotency guard — an existing `handoff.created` under
   `handoff:<handoff_id>` converges instead of re-admitting;
4. fresh receiver observation → `capacity.snapshot_observed`;
5. `AdmissionEvaluation.evaluate/5` → `admission.decided`; non-admit
   refuses with the decision persisted;
6. receiver run (bounded transcript-free prompt) → receiver lease grant →
   `handoff.created` → `Dispatches.enqueue_for_run/2` behind
   `DispatchGate.authorize/2` → `Projector.project/2`.

### Honest-admission detail worth naming

`AdmissionEvaluation.normalize_candidate/1` defaults an undeclared
candidate to `support_tier: :proactive, compatibility_state: :compatible`.
That default is fail-open. `Handoffs.admit/8` therefore sources both fields
from the fresh observation, so the receiver's **measured** state decides.
A test guards exactly this (`"the receiver candidate takes its tier and
compatibility from the observation"`): if the sourcing regresses to the
defaults, a degraded observation would admit instead of asking for
confirmation, and that test fails.

`:incompatible` / `:unsupported` stay hard stops no override can lift;
degraded, unknown-capacity, stale or future-dated observations ask for an
attributable `:override`. All of that is `AdmissionEvaluation`'s existing
policy — this slice routes the receiver through it rather than
reimplementing it.

---

## 3. Deviations and limits (stated, not softened)

- **The brief named `plans/milestones/05-quota-aware-mvp.md`. That file does
  not exist** (`plans/milestones/` holds only `00a-capacity-feasibility.md`
  and `02-harness-contracts-fake.md`). The production pattern was taken from
  the committed code instead — `Shoestring.Cobbler.Wakeups`'s admit branch —
  and from this directory's existing evidence. `REPO-INSPECTION`.
- **`Elves.resume_run/2` is not removed or rerouted.** It remains the
  projection path with its existing semantics and tests. Production callers
  should use `Handoffs`; nothing yet forces them to. `UNVERIFIED` whether any
  caller still needs the direct path — no caller inventory was taken in this
  slice.
- **`decision_refs` are re-projected at perform time, not carried in the
  command.** A ref list frozen at request time would itself go stale. The
  consequence is that `validate_resume/3`'s `match_decisions/2` arm is
  trivially satisfied on this path; the load-bearing checks are checkpoint
  identity, run binding, confirmation and the lease allowlist. Stated in the
  code comment as well.
- **The `|| :unknown` fallbacks in `admit/8` are unreachable today**:
  `CapacitySnapshot` requires `support_tier` and `compatibility_state`. They
  exist so a future nil can never become a fail-open default.
- **No live provider run.** Cross-provider handoff against a real CLI is
  `UNVERIFIED`: no live run was made, no provider quota was spent, and no run
  budget was authorized. All coverage is Fake-to-Fake.
- **The Oban dispatch job is never executed in these tests.** The suite
  asserts the persisted delivery attempt (`harness_dispatches` row + `dispatch`
  queue job). That the `DispatchWorker` then starts a supervised Elf is
  existing, separately covered behaviour (`worker-effect.md`) and is
  `UNVERIFIED` end-to-end for the handoff path specifically.
- **UI is untouched**, per the brief. No surface renders `run.handoff`
  commands yet.

---

## 4. The session-lookup twin (R4.2's unfixed other side)

`round-4-fixes.md` R4.2 fixed this defect in `Shoestring.Elves.Elf`:
sessions register under `RunIdentity.run_id`, which
`CodexAppServer.start_session/2` and `ClaudeHeadless` set from
`request.dispatch_id` — not the run row id — so lookup must try dispatch id
first. `Elf.lookup_session_ids/2` carries that fix and the comment
explaining it.

The twin in `Shoestring.Elves` was not fixed. `live_receiver_session?/2`
probed `stored_run.id` only. Against a real adapter that lookup **always**
missed, so the handoff replay decision tree fell through to its "no evidence
the effect ran" arm and called `adapter.start/2` again — a second live
provider session for one receiver run. `resolve_session/2` (the safe-stop
path) had the same single-id lookup and now takes the run record so it can
try both.

The existing `HandoffCorrectionTest.LiveSessionStubAdapter` registers its
session under the **run row id**, which is why that suite passed green while
production duplicated. The new
`test/shoestring/harness/handoff_session_lookup_test.exs` registers under the
**dispatch id**, the way the real adapters do, and asserts
`refute receiver.dispatch_id == receiver.id` so the test cannot pass
vacuously.

---

## 5. Verification

### Gate (`VERIFIED`)

Command, run in the worktree with a dropped-and-remigrated test database:

```
MIX_ENV=test mix ecto.drop --quiet && mix precommit
```

Exit status **0**.

- `format --check-formatted`: clean.
- `compile --warnings-as-errors`: clean.
- Elixir: **1230 tests, 0 failures, 1 skipped (6 excluded)**, 89.5s.
- Node (`gate_0a.node_test`): **tests 52, pass 52, fail 0, skipped 0**.

### Baseline (`VERIFIED`, measured — not carried forward)

The brief quoted 1207 tests as the previous gate and noted it was not rerun
on merge. It was rerun here. With this slice's tracked and untracked changes
stashed (`git stash push -u`), at `01f2a54`, after a database drop:

```
MIX_ENV=test mix test
→ 1207 tests, 0 failures, 1 skipped (6 excluded)
```

1207 → 1230 is **+23**, exactly the 19 + 4 tests this slice adds. No
existing test was deleted; one was edited (see below).

### Fail-on-base (`VERIFIED`)

**Session-lookup lock.** `lib/shoestring/elves.ex` reverted to `01f2a54`
(`git checkout 01f2a54 -- lib/shoestring/elves.ex`), new test file kept:

```
MIX_ENV=test mix test test/shoestring/harness/handoff_session_lookup_test.exs
→ 4 tests, 1 failure

1) "a receiver session registered under the dispatch id is recognized on replay"
   assert RequestLog.count(log) == 1
   left:  2
   right: 1
```

Left 2 IS the defect: base started a **second** adapter session for the same
receiver run. This is a TRUE behavioural lock — the failure is the duplicate
session, not a missing module. `lib/shoestring/elves.ex` was then restored
and confirmed byte-identical (`diff` clean), and the suite re-ran 4/4 green.

The other three arms (run-row-id registration, dead session, no session)
pass on base: DOCUMENTATION, pinning behaviour the fix must preserve.

**Production handoff suite.** All `lib/` changes stashed
(`git stash push -- lib/`):

```
MIX_ENV=test mix test test/shoestring/cobbler/handoff_production_test.exs
→ 19 tests, 19 failures
```

Representative failure, the right behavioural reason — base has no
`run.handoff` command type, so no production handoff intent can be recorded
at all:

```
1) "the command row exists; no handoff, run, lease or dispatch does"
   right: {:error, #Ecto.Changeset<
             errors: [type: {"must be one of task.claim, task.release", []}] >}
```

Honest strength ledger: because `Shoestring.Cobbler.Handoffs` is new
surface, these 19 are DOCUMENTATION in the sense the standing contract uses
— they fail on base because the surface does not exist, not because base
does the wrong thing at the same surface. Their value as locks is forward:
they assert against the durable pipeline (dispatch rows, lease rows keyed to
the receiver run, handoff-scoped `admission.decided`, refusal-with-no-effect)
that base's `resume_run/2` path never produced.

### Edited existing test (`VERIFIED`)

`test/shoestring/cobbler/command_test.exs:40` asserted the literal enum
message `"must be one of task.claim, task.release"`, which the new type
changes. It now derives the expected message from `Command.types/0` **and**
asserts the exact type list, so it remains a lock on the closed set rather
than on a frozen string. It is the only pre-existing test this slice edits.

### New tests (`VERIFIED`, hermetic — Fake adapter and local state only)

`test/shoestring/cobbler/handoff_production_test.exs` (19 tests)

- intent before effects: command row written, zero handoff/run/lease/
  dispatch/job; identical re-request replays with no new events; same-provider
  target rejected; foreign checkpoint rejected as a boundary;
- production transfer: observation + decision + receiver run + receiver-owned
  granted lease + pointer (`from`/`to`/`contract_version`/`prior_run_id`/
  `lease_grant_id`/`decision_refs`/`requested_by`) + exactly one dispatch row
  and one `dispatch`-queue job; the receiver row rests at `requested` (no
  adapter was started);
- idempotence: two performs → one handoff, one receiver, one dispatch, one
  lease, one decision, one snapshot, second outcome `:converged`;
- claim gate: a released claim refuses with zero effects;
- admission: degraded refuses with the decision persisted and no effect;
  attributable override admits and persists `override.confirmed_by`/`valid`,
  unattributed does not; incompatible is a hard stop an override cannot lift;
  unobservable and unconfigured-observer both fail closed with no decision;
  the candidate's tier/compatibility come from the observation;
- boundary/Elf: superseded checkpoint → `:stale_continuation`; `running`
  sender → `{:sender_run_active, "running"}`; live Elf →
  `{:sender_elf_active, run_id}`; revoked sender lease →
  `:lease_not_resumable` **before** any observation;
- privacy both directions: required present (checkpoint id, `next_action`
  marker, decision refs, exactly the three continuation keys) AND sensitive
  gone (sender transcript marker absent, sender session id absent from prompt,
  `provider_session_id` and extensions; `wakeup:resume_prior_session_id`
  stripped so the Elf cannot prefer `adapter.resume`; pointer payload passes
  `Contract.safe_term?/1` and carries no forbidden key).

`test/shoestring/harness/handoff_session_lookup_test.exs` (4 tests) — see §4.

Fixtures use `Ecto.UUID.generate/0` and format-valid synthetic identifiers.
No credentials, tokens, absolute paths or machine identifiers are committed.

---

## 6. Twin checks performed

- **Session lookup**: both call sites in `Shoestring.Elves`
  (`live_receiver_session?/2`, `resolve_session/2`) were fixed, not just the
  one the audit named. `Elf.lookup_session_ids/2` already held the correct
  form and is untouched (Elf-owned).
- **Capability mapping**: `Handoffs.receiver_capabilities/1` is the third
  copy of the same string→atom mapping (`Elves.resume_capabilities/1`,
  `Wakeups.wake_capabilities/1`). Kept local for the same file-ownership
  reason `Wakeups` records, and noted in the code so the triplet is visible.
- **Migration up/down**: `down/0` narrows the check back. Rows of the new
  type would then violate it; none exist pre-MVP. Stated in the migration.
